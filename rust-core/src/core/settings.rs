//! Settings management with macOS native plist storage.
//!
//! Settings are stored in ~/Library/Preferences/com.flowfinder.native.plist
//! and organized into categories: General, Appearance, Shortcuts, Advanced.

use std::ffi::{CStr, CString};
use std::os::raw::{c_char, c_int};
use std::path::PathBuf;
use std::sync::Mutex;

use serde::{Deserialize, Serialize};

// ── Constants ────────────────────────────────────────────────────────

const PLIST_NAME: &str = "com.flowfinder.native.plist";

// ── Error codes ─────────────────────────────────────────────────────

const FF_OK: c_int = 0;
const FF_ERR_GENERIC: c_int = -1;
const FF_ERR_INVALID_PATH: c_int = -2;
const FF_ERR_IO: c_int = -3;

// ── Settings Data ───────────────────────────────────────────────────

/// Complete settings structure
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Settings {
    pub general: GeneralSettings,
    pub appearance: AppearanceSettings,
    pub shortcuts: ShortcutsSettings,
    pub advanced: AdvancedSettings,
}

impl Default for Settings {
    fn default() -> Self {
        Settings {
            general: GeneralSettings::default(),
            appearance: AppearanceSettings::default(),
            shortcuts: ShortcutsSettings::default(),
            advanced: AdvancedSettings::default(),
        }
    }
}

/// General settings
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct GeneralSettings {
    pub default_directory: String,
    pub show_hidden_files: bool,
    pub confirm_delete: bool,
}

impl Default for GeneralSettings {
    fn default() -> Self {
        GeneralSettings {
            default_directory: std::env::var("HOME").unwrap_or_else(|_| "/".to_string()),
            show_hidden_files: false,
            confirm_delete: true,
        }
    }
}

/// Appearance settings
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AppearanceSettings {
    pub theme: String,
    pub icon_size: u32,
    pub font_size: u32,
}

impl Default for AppearanceSettings {
    fn default() -> Self {
        AppearanceSettings {
            theme: "auto".to_string(),
            icon_size: 64,
            font_size: 13,
        }
    }
}

/// Keyboard shortcuts settings
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ShortcutsSettings {
    pub new_window: String,
    pub close_window: String,
    pub search: String,
    pub refresh: String,
    pub delete: String,
    pub copy: String,
    pub paste: String,
    pub select_all: String,
}

impl Default for ShortcutsSettings {
    fn default() -> Self {
        ShortcutsSettings {
            new_window: "Cmd+N".to_string(),
            close_window: "Cmd+W".to_string(),
            search: "Cmd+F".to_string(),
            refresh: "Cmd+R".to_string(),
            delete: "Cmd+Backspace".to_string(),
            copy: "Cmd+C".to_string(),
            paste: "Cmd+V".to_string(),
            select_all: "Cmd+A".to_string(),
        }
    }
}

/// Advanced settings
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AdvancedSettings {
    pub cache_size_mb: u32,
    pub thumbnail_quality: u32,
    pub fsevents_enabled: bool,
}

impl Default for AdvancedSettings {
    fn default() -> Self {
        AdvancedSettings {
            cache_size_mb: 100,
            thumbnail_quality: 80,
            fsevents_enabled: true,
        }
    }
}

// ── Storage ─────────────────────────────────────────────────────────

use std::sync::OnceLock;

static SETTINGS: OnceLock<Mutex<Settings>> = OnceLock::new();

fn get_settings() -> &'static Mutex<Settings> {
    SETTINGS.get_or_init(|| {
        // Try to load existing settings from plist
        if let Ok(settings) = load_settings_from_plist() {
            Mutex::new(settings)
        } else {
            Mutex::new(Settings::default())
        }
    })
}

fn plist_path() -> PathBuf {
    let home = std::env::var("HOME").unwrap_or_else(|_| "/".to_string());
    PathBuf::from(home)
        .join("Library")
        .join("Preferences")
        .join(PLIST_NAME)
}

fn load_settings_from_plist() -> Result<Settings, Box<dyn std::error::Error>> {
    let path = plist_path();
    if !path.exists() {
        return Err("Settings file does not exist".into());
    }

    let plist_data = std::fs::read_to_string(&path)?;
    let settings: Settings = plist::from_bytes(plist_data.as_bytes())
        .map_err(|e| format!("Failed to parse plist: {}", e))?;
    
    Ok(settings)
}

fn save_settings_to_plist(settings: &Settings) -> Result<(), Box<dyn std::error::Error>> {
    let path = plist_path();
    
    // Ensure parent directory exists
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }

    // Serialize to XML plist format
    let json_str = serde_json::to_string(settings)
        .map_err(|e| format!("Failed to serialize settings: {}", e))?;
    
    std::fs::write(&path, json_str)?;
    
    Ok(())
}

// ── Internal API (called by ffi/mod.rs) ───────────────────────────

/// Load all settings as a JSON string.
/// Returns a heap-allocated C string. Must be freed with `ff_free_string()`.
pub fn settings_load() -> *mut c_char {
    let guard = match get_settings().lock() {
        Ok(g) => g,
        Err(_) => return std::ptr::null_mut(),
    };

    match serde_json::to_string(&*guard) {
        Ok(json) => match CString::new(json) {
            Ok(cstr) => cstr.into_raw(),
            Err(_) => std::ptr::null_mut(),
        },
        Err(_) => std::ptr::null_mut(),
    }
}

/// Save all settings from a JSON string.
/// Returns 0 on success, negative error code on failure.
pub fn settings_save(json: *const c_char) -> c_int {
    if json.is_null() {
        return FF_ERR_INVALID_PATH;
    }

    let json_str = unsafe {
        match CStr::from_ptr(json).to_str() {
            Ok(s) => s,
            Err(_) => return FF_ERR_INVALID_PATH,
        }
    };

    let new_settings: Settings = match serde_json::from_str(json_str) {
        Ok(s) => s,
        Err(_) => return FF_ERR_GENERIC,
    };

    if let Err(_) = save_settings_to_plist(&new_settings) {
        return FF_ERR_IO;
    }

    let mut guard = match get_settings().lock() {
        Ok(g) => g,
        Err(_) => return FF_ERR_GENERIC,
    };

    *guard = new_settings;
    FF_OK
}

/// Get a specific setting value by key.
/// Keys are dot-separated, e.g., "general.default_directory", "appearance.theme".
/// Returns a heap-allocated C string. Must be freed with `ff_free_string()`.
pub fn settings_get(key: *const c_char) -> *mut c_char {
    if key.is_null() {
        return std::ptr::null_mut();
    }

    let key_str = unsafe {
        match CStr::from_ptr(key).to_str() {
            Ok(s) => s,
            Err(_) => return std::ptr::null_mut(),
        }
    };

    let guard = match get_settings().lock() {
        Ok(g) => g,
        Err(_) => return std::ptr::null_mut(),
    };

    let value = match key_str {
        "general.default_directory" => &guard.general.default_directory,
        "general.show_hidden_files" => return bool_to_cstring(guard.general.show_hidden_files),
        "general.confirm_delete" => return bool_to_cstring(guard.general.confirm_delete),
        "appearance.theme" => &guard.appearance.theme,
        "appearance.icon_size" => return u32_to_cstring(guard.appearance.icon_size),
        "appearance.font_size" => return u32_to_cstring(guard.appearance.font_size),
        "shortcuts.new_window" => &guard.shortcuts.new_window,
        "shortcuts.close_window" => &guard.shortcuts.close_window,
        "shortcuts.search" => &guard.shortcuts.search,
        "shortcuts.refresh" => &guard.shortcuts.refresh,
        "shortcuts.delete" => &guard.shortcuts.delete,
        "shortcuts.copy" => &guard.shortcuts.copy,
        "shortcuts.paste" => &guard.shortcuts.paste,
        "shortcuts.select_all" => &guard.shortcuts.select_all,
        "advanced.cache_size_mb" => return u32_to_cstring(guard.advanced.cache_size_mb),
        "advanced.thumbnail_quality" => return u32_to_cstring(guard.advanced.thumbnail_quality),
        "advanced.fsevents_enabled" => return bool_to_cstring(guard.advanced.fsevents_enabled),
        _ => return std::ptr::null_mut(),
    };

    match CString::new(value.clone()) {
        Ok(cstr) => cstr.into_raw(),
        Err(_) => std::ptr::null_mut(),
    }
}

/// Set a specific setting value by key.
/// Keys are dot-separated, e.g., "general.default_directory", "appearance.theme".
/// Returns 0 on success, negative error code on failure.
pub fn settings_set(key: *const c_char, value: *const c_char) -> c_int {
    if key.is_null() || value.is_null() {
        return FF_ERR_INVALID_PATH;
    }

    let key_str = unsafe {
        match CStr::from_ptr(key).to_str() {
            Ok(s) => s,
            Err(_) => return FF_ERR_INVALID_PATH,
        }
    };

    let value_str = unsafe {
        match CStr::from_ptr(value).to_str() {
            Ok(s) => s,
            Err(_) => return FF_ERR_INVALID_PATH,
        }
    };

    let mut guard = match get_settings().lock() {
        Ok(g) => g,
        Err(_) => return FF_ERR_GENERIC,
    };

    match key_str {
        "general.default_directory" => guard.general.default_directory = value_str.to_string(),
        "general.show_hidden_files" => guard.general.show_hidden_files = parse_bool(value_str),
        "general.confirm_delete" => guard.general.confirm_delete = parse_bool(value_str),
        "appearance.theme" => guard.appearance.theme = value_str.to_string(),
        "appearance.icon_size" => {
            if let Ok(v) = value_str.parse() {
                guard.appearance.icon_size = v;
            }
        }
        "appearance.font_size" => {
            if let Ok(v) = value_str.parse() {
                guard.appearance.font_size = v;
            }
        }
        "shortcuts.new_window" => guard.shortcuts.new_window = value_str.to_string(),
        "shortcuts.close_window" => guard.shortcuts.close_window = value_str.to_string(),
        "shortcuts.search" => guard.shortcuts.search = value_str.to_string(),
        "shortcuts.refresh" => guard.shortcuts.refresh = value_str.to_string(),
        "shortcuts.delete" => guard.shortcuts.delete = value_str.to_string(),
        "shortcuts.copy" => guard.shortcuts.copy = value_str.to_string(),
        "shortcuts.paste" => guard.shortcuts.paste = value_str.to_string(),
        "shortcuts.select_all" => guard.shortcuts.select_all = value_str.to_string(),
        "advanced.cache_size_mb" => {
            if let Ok(v) = value_str.parse() {
                guard.advanced.cache_size_mb = v;
            }
        }
        "advanced.thumbnail_quality" => {
            if let Ok(v) = value_str.parse() {
                guard.advanced.thumbnail_quality = v;
            }
        }
        "advanced.fsevents_enabled" => guard.advanced.fsevents_enabled = parse_bool(value_str),
        _ => return FF_ERR_GENERIC,
    }

    // Save to plist after modification
    drop(guard);
    if let Ok(s) = get_settings().lock() {
        if let Err(_) = save_settings_to_plist(&*s) {
            return FF_ERR_IO;
        }
    }

    FF_OK
}

// ── Helpers ─────────────────────────────────────────────────────────

fn bool_to_cstring(value: bool) -> *mut c_char {
    let s = if value { "true" } else { "false" };
    match CString::new(s) {
        Ok(cstr) => cstr.into_raw(),
        Err(_) => std::ptr::null_mut(),
    }
}

fn u32_to_cstring(value: u32) -> *mut c_char {
    match CString::new(value.to_string()) {
        Ok(cstr) => cstr.into_raw(),
        Err(_) => std::ptr::null_mut(),
    }
}

fn parse_bool(s: &str) -> bool {
    matches!(s.to_lowercase().as_str(), "true" | "1" | "yes" | "on")
}

// ── Tests ─────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_settings_default() {
        let settings = Settings::default();
        assert!(!settings.general.default_directory.is_empty());
        assert_eq!(settings.appearance.theme, "auto");
        assert_eq!(settings.appearance.icon_size, 64);
        assert_eq!(settings.advanced.thumbnail_quality, 80);
    }

    #[test]
    fn test_parse_bool() {
        assert!(parse_bool("true"));
        assert!(parse_bool("True"));
        assert!(parse_bool("1"));
        assert!(parse_bool("yes"));
        assert!(!parse_bool("false"));
        assert!(!parse_bool("0"));
        assert!(!parse_bool("no"));
    }
}
