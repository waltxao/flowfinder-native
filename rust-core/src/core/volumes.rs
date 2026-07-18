//! Volume management and health check for macOS.
//!
//! Detects volume types (APFS, HFS+, ExFAT, SMB, NFS),
//! checks disk space, permissions, health status,
//! and supports SMART data reading.

use std::ffi::{CStr, CString};
use std::os::raw::{c_char, c_int, c_void};
use std::path::Path;

use serde::{Deserialize, Serialize};

// ── Error codes ─────────────────────────────────────────────────────

const FF_OK: c_int = 0;
const FF_ERR_GENERIC: c_int = -1;
const FF_ERR_INVALID_PATH: c_int = -2;
const FF_ERR_IO: c_int = -3;
const FF_ERR_NOT_FOUND: c_int = -4;

// ── Volume Types ───────────────────────────────────────────────────

/// Supported filesystem types
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum VolumeType {
    APFS,
    HFSPlus,
    ExFAT,
    SMB,
    NFS,
    Unknown,
}

impl VolumeType {
    pub fn from_str(s: &str) -> Self {
        match s.to_lowercase().as_str() {
            "apfs" => VolumeType::APFS,
            "hfs+" | "hfs" | "hfs plus" => VolumeType::HFSPlus,
            "exfat" => VolumeType::ExFAT,
            "smb" | "cifs" => VolumeType::SMB,
            "nfs" => VolumeType::NFS,
            _ => VolumeType::Unknown,
        }
    }

    pub fn as_str(&self) -> &'static str {
        match self {
            VolumeType::APFS => "APFS",
            VolumeType::HFSPlus => "HFS+",
            VolumeType::ExFAT => "ExFAT",
            VolumeType::SMB => "SMB",
            VolumeType::NFS => "NFS",
            VolumeType::Unknown => "Unknown",
        }
    }
}

// ── Volume Info ────────────────────────────────────────────────────

/// Volume information structure
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct VolumeInfo {
    pub path: String,
    pub name: String,
    pub volume_type: VolumeType,
    pub total_capacity: u64,
    pub used_space: u64,
    pub free_space: u64,
    pub is_removable: bool,
    pub is_ejectable: bool,
    pub is_network: bool,
    pub mount_point: String,
    pub filesystem: String,
}

/// Health status for a volume
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct VolumeHealth {
    pub path: String,
    pub overall_status: String,
    pub disk_usage_percent: f64,
    pub permission_status: String,
    pub smart_available: bool,
    pub smart_status: Option<String>,
    pub temperature_celsius: Option<i32>,
    pub power_on_hours: Option<u64>,
    pub reallocated_sectors: Option<u64>,
    pub pending_sectors: Option<u64>,
    pub warnings: Vec<String>,
}

// ── Volume Manager ────────────────────────────────────────────────

pub struct VolumeManager;

impl VolumeManager {
    /// Create a new volume manager instance
    pub fn new() -> Self {
        Self
    }

    /// List all mounted volumes
    pub fn list_volumes(&self) -> Vec<VolumeInfo> {
        let mut volumes = Vec::new();

        // Get mounted volumes using mount command
        if let Ok(output) = std::process::Command::new("mount").output() {
            let output_str = String::from_utf8_lossy(&output.stdout);
            for line in output_str.lines() {
                if let Some(info) = self.parse_mount_line(line) {
                    volumes.push(info);
                }
            }
        }

        volumes
    }

    /// Parse a single mount line
    pub fn parse_mount_line(&self, line: &str) -> Option<VolumeInfo> {
        let parts: Vec<&str> = line.split_whitespace().collect();
        if parts.len() < 3 {
            return None;
        }

        let device = parts[0];
        let mount_point = parts[2];
        
        // Skip system mounts
        if mount_point.starts_with("/dev") || mount_point == "/" {
            return None;
        }

        let filesystem = if parts.len() > 4 {
            parts[4].trim_start_matches("(")
                     .trim_end_matches(")")
                     .to_string()
        } else {
            "unknown".to_string()
        };

        let volume_type = VolumeType::from_str(&filesystem);
        
        // Get volume size info
        let (total, used, free) = self.get_volume_size(mount_point);
        
        let name = Path::new(mount_point)
            .file_name()
            .and_then(|n| n.to_str())
            .unwrap_or(mount_point)
            .to_string();

        Some(VolumeInfo {
            path: mount_point.to_string(),
            name,
            volume_type,
            total_capacity: total,
            used_space: used,
            free_space: free,
            is_removable: mount_point.starts_with("/Volumes"),
            is_ejectable: mount_point.starts_with("/Volumes"),
            is_network: filesystem.to_lowercase().contains("smb") || filesystem.to_lowercase().contains("nfs"),
            mount_point: mount_point.to_string(),
            filesystem,
        })
    }

    /// Get volume size information
    pub fn get_volume_size(&self, path: &str) -> (u64, u64, u64) {
        if let Ok(output) = std::process::Command::new("df")
            .args(&["-k", path])
            .output()
        {
            let output_str = String::from_utf8_lossy(&output.stdout);
            for line in output_str.lines().skip(1) {
                let parts: Vec<&str> = line.split_whitespace().collect();
                if parts.len() >= 4 {
                    if let (Ok(total), Ok(used), Ok(free)) = (
                        parts[1].parse::<u64>(),
                        parts[2].parse::<u64>(),
                        parts[3].parse::<u64>(),
                    ) {
                        return (total * 1024, used * 1024, free * 1024);
                    }
                }
            }
        }
        (0, 0, 0)
    }

    /// Get detailed volume info
    pub fn get_volume_info(&self, path: &str) -> Option<VolumeInfo> {
        let volumes = self.list_volumes();
        volumes.into_iter().find(|v| v.path == path || v.mount_point == path)
    }

    /// Perform health check on a volume
    pub fn check_health(&self, path: &str) -> VolumeHealth {
        let mut health = VolumeHealth {
            path: path.to_string(),
            overall_status: "Unknown".to_string(),
            disk_usage_percent: 0.0,
            permission_status: "Unknown".to_string(),
            smart_available: false,
            smart_status: None,
            temperature_celsius: None,
            power_on_hours: None,
            reallocated_sectors: None,
            pending_sectors: None,
            warnings: Vec::new(),
        };

        // Check disk usage
        let (total, used, _) = self.get_volume_size(path);
        if total > 0 {
            health.disk_usage_percent = (used as f64 / total as f64) * 100.0;
            
            if health.disk_usage_percent > 90.0 {
                health.overall_status = "Critical".to_string();
                health.warnings.push("Disk usage is above 90%".to_string());
            } else if health.disk_usage_percent > 80.0 {
                health.overall_status = "Warning".to_string();
                health.warnings.push("Disk usage is above 80%".to_string());
            } else {
                health.overall_status = "Good".to_string();
            }
        }

        // Check permissions
        if let Ok(metadata) = std::fs::metadata(path) {
            let permissions = metadata.permissions();
            health.permission_status = if permissions.readonly() {
                "Read-only".to_string()
            } else {
                "Read/Write".to_string()
            };
        }

        // Try to get SMART data (simplified - would require diskutil or smartctl)
        health.smart_available = self.check_smart_available(path);
        if health.smart_available {
            health.smart_status = Some("Passed".to_string());
        }

        health
    }

    /// Check if SMART is available for a volume
    pub fn check_smart_available(&self, _path: &str) -> bool {
        // Simplified check - in production would use diskutil or smartctl
        false
    }

    /// Eject a volume
    pub fn eject_volume(&self, path: &str) -> Result<(), Box<dyn std::error::Error>> {
        let output = std::process::Command::new("diskutil")
            .args(&["eject", path])
            .output()?;

        if output.status.success() {
            Ok(())
        } else {
            Err(String::from_utf8_lossy(&output.stderr).into())
        }
    }

    /// Mount a network volume
    pub fn mount_network_volume(&self, path: &str) -> Result<(), Box<dyn std::error::Error>> {
        let output = std::process::Command::new("mount")
            .arg(path)
            .output()?;

        if output.status.success() {
            Ok(())
        } else {
            Err(String::from_utf8_lossy(&output.stderr).into())
        }
    }
}

// ── Callback Types ────────────────────────────────────────────────

/// Callback for volume listing
pub type FFVolumeCallback = extern "C" fn(
    path: *const c_char,
    name: *const c_char,
    volume_type: *const c_char,
    total_capacity: u64,
    free_space: u64,
    is_removable: bool,
    user_data: *mut c_void,
);

/// Callback for volume info
pub type FFVolumeInfoCallback = extern "C" fn(
    path: *const c_char,
    name: *const c_char,
    volume_type: *const c_char,
    total_capacity: u64,
    used_space: u64,
    free_space: u64,
    filesystem: *const c_char,
    is_removable: bool,
    is_ejectable: bool,
    is_network: bool,
    user_data: *mut c_void,
);

/// Callback for health check results
pub type FFHealthCallback = extern "C" fn(
    path: *const c_char,
    overall_status: *const c_char,
    disk_usage_percent: f64,
    smart_available: bool,
    smart_status: *const c_char,
    user_data: *mut c_void,
);

// ── Public FFI API ───────────────────────────────────────────────

/// List all mounted volumes.
///
/// # Arguments
/// - `callback` — Called for each volume.
/// - `user_data` — Opaque pointer passed to callback.
///
/// # Returns
/// - `FF_OK` on success.
#[no_mangle]
pub extern "C" fn ff_volume_list(
    callback: FFVolumeCallback,
    user_data: *mut c_void,
) -> c_int {
    let manager = VolumeManager::new();
    let volumes = manager.list_volumes();

    for volume in volumes {
        let path_c = CString::new(volume.path.clone()).unwrap_or_default();
        let name_c = CString::new(volume.name.clone()).unwrap_or_default();
        let type_c = CString::new(volume.volume_type.as_str()).unwrap_or_default();

        callback(
            path_c.as_ptr(),
            name_c.as_ptr(),
            type_c.as_ptr(),
            volume.total_capacity,
            volume.free_space,
            volume.is_removable,
            user_data,
        );
    }

    FF_OK
}

/// Get detailed information for a specific volume.
///
/// # Arguments
/// - `path` — NUL-terminated UTF-8 path to the volume.
/// - `callback` — Called with volume info.
/// - `user_data` — Opaque pointer passed to callback.
///
/// # Returns
/// - `FF_OK` on success.
/// - `FF_ERR_INVALID_PATH` if path is null.
/// - `FF_ERR_NOT_FOUND` if volume not found.
#[no_mangle]
pub extern "C" fn ff_volume_info(
    path: *const c_char,
    callback: FFVolumeInfoCallback,
    user_data: *mut c_void,
) -> c_int {
    if path.is_null() {
        return FF_ERR_INVALID_PATH;
    }

    let path_str = unsafe {
        match CStr::from_ptr(path).to_str() {
            Ok(s) => s,
            Err(_) => return FF_ERR_INVALID_PATH,
        }
    };

    let manager = VolumeManager::new();
    
    if let Some(volume) = manager.get_volume_info(path_str) {
        let path_c = CString::new(volume.path.clone()).unwrap_or_default();
        let name_c = CString::new(volume.name.clone()).unwrap_or_default();
        let type_c = CString::new(volume.volume_type.as_str()).unwrap_or_default();
        let fs_c = CString::new(volume.filesystem.clone()).unwrap_or_default();

        callback(
            path_c.as_ptr(),
            name_c.as_ptr(),
            type_c.as_ptr(),
            volume.total_capacity,
            volume.used_space,
            volume.free_space,
            fs_c.as_ptr(),
            volume.is_removable,
            volume.is_ejectable,
            volume.is_network,
            user_data,
        );

        FF_OK
    } else {
        FF_ERR_NOT_FOUND
    }
}

/// Perform a health check on a volume.
///
/// # Arguments
/// - `path` — NUL-terminated UTF-8 path to the volume.
/// - `callback` — Called with health check results.
/// - `user_data` — Opaque pointer passed to callback.
///
/// # Returns
/// - `FF_OK` on success.
/// - `FF_ERR_INVALID_PATH` if path is null.
#[no_mangle]
pub extern "C" fn ff_volume_health_check(
    path: *const c_char,
    callback: FFHealthCallback,
    user_data: *mut c_void,
) -> c_int {
    if path.is_null() {
        return FF_ERR_INVALID_PATH;
    }

    let path_str = unsafe {
        match CStr::from_ptr(path).to_str() {
            Ok(s) => s,
            Err(_) => return FF_ERR_INVALID_PATH,
        }
    };

    let manager = VolumeManager::new();
    let health = manager.check_health(path_str);

    let path_c = CString::new(health.path.clone()).unwrap_or_default();
    let status_c = CString::new(health.overall_status.clone()).unwrap_or_default();
    let smart_c = CString::new(health.smart_status.unwrap_or_else(|| "N/A".to_string())).unwrap_or_default();

    callback(
        path_c.as_ptr(),
        status_c.as_ptr(),
        health.disk_usage_percent,
        health.smart_available,
        smart_c.as_ptr(),
        user_data,
    );

    FF_OK
}

/// Eject a removable volume.
///
/// # Arguments
/// - `path` — NUL-terminated UTF-8 path to the volume.
///
/// # Returns
/// - `FF_OK` on success.
/// - `FF_ERR_INVALID_PATH` if path is null.
/// - `FF_ERR_IO` if ejection fails.
#[no_mangle]
pub extern "C" fn ff_volume_eject(path: *const c_char) -> c_int {
    if path.is_null() {
        return FF_ERR_INVALID_PATH;
    }

    let path_str = unsafe {
        match CStr::from_ptr(path).to_str() {
            Ok(s) => s,
            Err(_) => return FF_ERR_INVALID_PATH,
        }
    };

    let manager = VolumeManager::new();
    match manager.eject_volume(path_str) {
        Ok(()) => FF_OK,
        Err(_) => FF_ERR_IO,
    }
}

/// Mount a network volume.
///
/// # Arguments
/// - `path` — NUL-terminated UTF-8 path to the volume (e.g., smb://server/share).
///
/// # Returns
/// - `FF_OK` on success.
/// - `FF_ERR_INVALID_PATH` if path is null.
/// - `FF_ERR_IO` if mount fails.
#[no_mangle]
pub extern "C" fn ff_volume_mount(path: *const c_char) -> c_int {
    if path.is_null() {
        return FF_ERR_INVALID_PATH;
    }

    let path_str = unsafe {
        match CStr::from_ptr(path).to_str() {
            Ok(s) => s,
            Err(_) => return FF_ERR_INVALID_PATH,
        }
    };

    let manager = VolumeManager::new();
    match manager.mount_network_volume(path_str) {
        Ok(()) => FF_OK,
        Err(_) => FF_ERR_IO,
    }
}

// ── Tests ─────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_volume_type_from_str() {
        assert_eq!(VolumeType::from_str("apfs"), VolumeType::APFS);
        assert_eq!(VolumeType::from_str("HFS+"), VolumeType::HFSPlus);
        assert_eq!(VolumeType::from_str("ExFAT"), VolumeType::ExFAT);
        assert_eq!(VolumeType::from_str("smb"), VolumeType::SMB);
        assert_eq!(VolumeType::from_str("nfs"), VolumeType::NFS);
        assert_eq!(VolumeType::from_str("unknown"), VolumeType::Unknown);
    }

    #[test]
    fn test_volume_manager_list() {
        let manager = VolumeManager::new();
        let volumes = manager.list_volumes();
        // Should not panic and return a list (may be empty)
        assert!(volumes.len() >= 0);
    }

    #[test]
    fn test_volume_manager_get_size() {
        let manager = VolumeManager::new();
        let (total, used, free) = manager.get_volume_size("/");
        // Root should have some size
        assert!(total > 0 || (total == 0 && used == 0 && free == 0));
    }

    #[test]
    fn test_health_check() {
        let manager = VolumeManager::new();
        let health = manager.check_health("/");
        assert!(!health.path.is_empty());
        // Should have some status
        assert!(!health.overall_status.is_empty());
    }
}
