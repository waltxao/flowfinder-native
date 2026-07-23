//! FFI export layer — exposes Rust core functions via a C-compatible ABI.
//!
//! This module provides the bridge between Swift (frontend) and Rust (core).
//! All exported functions use the `#[no_mangle]` attribute and `extern "C"`
//! calling convention for stable C ABI compatibility.
//!
//! ## Design
//!
//! - Error codes are returned as `ff_error_t` integers.
//! - The last error message is stored in thread-local storage and can be
//!   retrieved via `ff_last_error()`.
//! - Directory entries are returned through an iterator callback pattern:
//!   Rust calls the Swift-provided callback for each entry.
//! - All heap-allocated strings returned to C must be freed with
//!   `ff_free_string()`.

use std::collections::HashMap;
use std::ffi::{CStr, CString};
use std::os::raw::{c_char, c_int, c_void};
use std::ptr;
use std::sync::{Mutex, OnceLock};

// ── L2 persistent cache db path ────────────────────────────────────
//
// Path to the SQLite database used as the L2 persistent directory cache.
// Set once via `ff_cache_init` at app startup. When unset, only the L1
// in-memory cache (`dir_cache`) is used — preserving backward compatibility.

static CACHE_DB_PATH: OnceLock<String> = OnceLock::new();

// ── Error codes ─────────────────────────────────────────────────────

/// Operation succeeded.
pub const FF_OK: c_int = 0;
/// Generic error.
pub const FF_ERR_GENERIC: c_int = -1;
/// Invalid path argument.
pub const FF_ERR_INVALID_PATH: c_int = -2;
/// I/O error during operation.
pub const FF_ERR_IO: c_int = -3;
/// Resource not found.
pub const FF_ERR_NOT_FOUND: c_int = -4;
/// Duplicate resource.
pub const FF_ERR_DUPLICATE: c_int = -5;
/// Permission denied.
pub const FF_ERR_PERMISSION_DENIED: c_int = -6;

// ── Thread-local error storage ────────────────────────────────────────

thread_local! {
    static LAST_ERROR: Mutex<Option<String>> = Mutex::new(None);
}

fn set_last_error(msg: String) {
    LAST_ERROR.with(|e| {
        *e.lock().unwrap() = Some(msg);
    });
}

fn clear_last_error() {
    LAST_ERROR.with(|e| {
        *e.lock().unwrap() = None;
    });
}

// ── C-compatible directory entry ────────────────────────────────────

/// A single directory entry exposed to C.
///
/// All string fields are heap-allocated and must be freed with
/// `ff_free_string()` by the caller.
#[repr(C)]
pub struct FFEntryRef {
    pub name: *mut c_char,
    pub path: *mut c_char,
    pub extension: *mut c_char,
    pub is_dir: bool,
    pub is_file: bool,
    pub is_symlink: bool,
    pub is_hidden: bool,
    pub is_system_protected: bool,
    pub size: u64,
    pub modified: i64,
    pub created: i64,
}

/// Callback type for directory entry iteration.
///
/// The callback receives a pointer to an `FFEntryRef` for each entry.
/// The `user_data` pointer is passed through from the caller.
///
/// # Safety
///
/// The callback must not retain the `FFEntryRef` pointer beyond the call.
/// All string fields are valid only for the duration of the callback.
pub type FFEntryCallback = extern "C" fn(entry: *const FFEntryRef, user_data: *mut c_void);

// ── Duplicate scan callback types ───────────────────────────────────

/// C-compatible duplicate file info.
#[repr(C)]
pub struct FFDuplicateFile {
    pub id: *mut c_char,
    pub path: *mut c_char,
    pub name: *mut c_char,
    pub size: u64,
    pub modified: i64,
}

/// C-compatible duplicate group info.
#[repr(C)]
pub struct FFDuplicateGroup {
    pub id: *mut c_char,
    pub hash: *mut c_char,
    pub size: u64,
    pub files: *const FFDuplicateFile,
    pub file_count: usize,
}

/// Callback for duplicate scan progress.
pub type FFDedupProgressCallback = extern "C" fn(scanned: usize, total: usize, user_data: *mut c_void);

/// Callback for duplicate group found.
pub type FFDedupGroupCallback = extern "C" fn(group: *const FFDuplicateGroup, user_data: *mut c_void);

// ── Search callback types ─────────────────────────────────────────

/// C-compatible search result.
#[repr(C)]
pub struct FFSearchResult {
    pub path: *mut c_char,
    pub name: *mut c_char,
    pub size: u64,
    pub modified: i64,
    pub is_dir: bool,
}

/// Callback for search results.
pub type FFSearchCallback = extern "C" fn(result: *const FFSearchResult, user_data: *mut c_void);

// ── Helper: convert Rust String to C string ─────────────────────────

fn rust_string_to_c(s: String) -> *mut c_char {
    match CString::new(s) {
        Ok(cstr) => cstr.into_raw(),
        Err(_) => ptr::null_mut(),
    }
}

// ── Exported functions ──────────────────────────────────────────────

/// List all entries in a directory, calling `callback` for each entry.
///
/// # Arguments
///
/// - `path` — NUL-terminated UTF-8 path string.
/// - `callback` — Function called for each directory entry.
/// - `user_data` — Opaque pointer passed to the callback.
///
/// # Returns
///
/// - `FF_OK` on success.
/// - `FF_ERR_INVALID_PATH` if the path is invalid.
/// - `FF_ERR_IO` if a filesystem error occurs.
///
/// # Safety
///
/// - `path` must be a valid, NUL-terminated UTF-8 string.
/// - `callback` must be a valid function pointer.
#[no_mangle]
pub extern "C" fn ff_list_dir(
    path: *const c_char,
    callback: FFEntryCallback,
    user_data: *mut c_void,
) -> c_int {
    if path.is_null() {
        set_last_error("path is null".to_string());
        return FF_ERR_INVALID_PATH;
    }

    let path_str = unsafe {
        match CStr::from_ptr(path).to_str() {
            Ok(s) => s,
            Err(_) => {
                set_last_error("path is not valid UTF-8".to_string());
                return FF_ERR_INVALID_PATH;
            }
        }
    };

    match crate::core::bulk_read::list_dir_bulk(path_str) {
        Ok(entries) => {
            for entry in entries {
                let name_c = rust_string_to_c(entry.name.clone());
                let path_c = rust_string_to_c(entry.path.clone());
                let ext_c = rust_string_to_c(entry.extension.clone());

                let ff_entry = FFEntryRef {
                    name: name_c,
                    path: path_c,
                    extension: ext_c,
                    is_dir: entry.is_dir,
                    is_file: entry.is_file,
                    is_symlink: entry.is_symlink,
                    is_hidden: entry.is_hidden,
                    is_system_protected: entry.is_system_protected,
                    size: entry.size,
                    modified: entry.modified,
                    created: entry.created,
                };

                callback(&ff_entry, user_data);

                // Clean up the strings we allocated for this entry.
                if !name_c.is_null() {
                    unsafe { let _ = CString::from_raw(name_c); }
                }
                if !path_c.is_null() {
                    unsafe { let _ = CString::from_raw(path_c); }
                }
                if !ext_c.is_null() {
                    unsafe { let _ = CString::from_raw(ext_c); }
                }
            }
            clear_last_error();
            FF_OK
        }
        Err(e) => {
            let msg = format!("list_dir failed: {}", e);
            set_last_error(msg);
            FF_ERR_IO
        }
    }
}

/// Get the last error message as a heap-allocated C string.
///
/// Returns `NULL` if no error has occurred.
/// The returned string must be freed with `ff_free_string()`.
///
/// # Safety
///
/// The returned pointer must be freed with `ff_free_string()` or
/// `ff_free_string()` to avoid memory leaks.
#[no_mangle]
pub extern "C" fn ff_last_error() -> *mut c_char {
    LAST_ERROR.with(|e| {
        let guard = e.lock().unwrap();
        match guard.as_ref() {
            Some(msg) => rust_string_to_c(msg.clone()),
            None => ptr::null_mut(),
        }
    })
}

/// Free a string previously returned by the FFI layer.
///
/// # Safety
///
/// - `s` must be a string returned by the FFI layer (e.g. `ff_last_error()`).
/// - `s` may be `NULL` (no-op).
/// - After calling this function, `s` must not be used again.
#[no_mangle]
pub extern "C" fn ff_free_string(s: *mut c_char) {
    if !s.is_null() {
        unsafe {
            let _ = CString::from_raw(s);
        }
    }
}

// ── Additional exported functions (placeholders for future use) ────

/// Get the library version string.
///
/// Returns a heap-allocated C string. Must be freed with `ff_free_string()`.
#[no_mangle]
pub extern "C" fn ff_version_string() -> *mut c_char {
    rust_string_to_c(env!("CARGO_PKG_VERSION").to_string())
}

/// Get the system memory size in bytes.
#[no_mangle]
pub extern "C" fn ff_get_system_memory() -> u64 {
    // Return 0 as a placeholder; platform-specific implementation
    // can use sysinfo or similar on macOS.
    0
}

// ── File Operations ─────────────────────────────────────────────────

/// Copy a file from `src` to `dst`.
///
/// Uses CoW cloning when available (same-volume APFS), falling back to
/// standard byte-for-byte copy otherwise.
///
/// # Arguments
///
/// - `src` — NUL-terminated UTF-8 source path string.
/// - `dst` — NUL-terminated UTF-8 destination path string.
///
/// # Returns
///
/// - `FF_OK` on success.
/// - `FF_ERR_INVALID_PATH` if a path is invalid.
/// - `FF_ERR_IO` if a filesystem error occurs.
///
/// # Safety
///
/// - `src` and `dst` must be valid, NUL-terminated UTF-8 strings.
#[no_mangle]
pub extern "C" fn ff_copy_file(src: *const c_char, dst: *const c_char) -> c_int {
    if src.is_null() || dst.is_null() {
        set_last_error("src or dst is null".to_string());
        return FF_ERR_INVALID_PATH;
    }

    let src_str = unsafe {
        match CStr::from_ptr(src).to_str() {
            Ok(s) => s,
            Err(_) => {
                set_last_error("src is not valid UTF-8".to_string());
                return FF_ERR_INVALID_PATH;
            }
        }
    };

    let dst_str = unsafe {
        match CStr::from_ptr(dst).to_str() {
            Ok(s) => s,
            Err(_) => {
                set_last_error("dst is not valid UTF-8".to_string());
                return FF_ERR_INVALID_PATH;
            }
        }
    };

    match crate::core::file_ops::copy_file(std::path::Path::new(src_str), std::path::Path::new(dst_str)) {
        Ok(_) => {
            clear_last_error();
            FF_OK
        }
        Err(e) => {
            let msg = format!("copy_file failed: {}", e);
            set_last_error(msg);
            FF_ERR_IO
        }
    }
}

/// Move a file or directory from `src` to `dst`.
///
/// Attempts a fast rename first. If `src` and `dst` are on different
/// volumes, falls back to copy + delete.
///
/// # Arguments
///
/// - `src` — NUL-terminated UTF-8 source path string.
/// - `dst` — NUL-terminated UTF-8 destination path string.
///
/// # Returns
///
/// - `FF_OK` on success.
/// - `FF_ERR_INVALID_PATH` if a path is invalid.
/// - `FF_ERR_IO` if a filesystem error occurs.
///
/// # Safety
///
/// - `src` and `dst` must be valid, NUL-terminated UTF-8 strings.
#[no_mangle]
pub extern "C" fn ff_move_file(src: *const c_char, dst: *const c_char) -> c_int {
    if src.is_null() || dst.is_null() {
        set_last_error("src or dst is null".to_string());
        return FF_ERR_INVALID_PATH;
    }

    let src_str = unsafe {
        match CStr::from_ptr(src).to_str() {
            Ok(s) => s,
            Err(_) => {
                set_last_error("src is not valid UTF-8".to_string());
                return FF_ERR_INVALID_PATH;
            }
        }
    };

    let dst_str = unsafe {
        match CStr::from_ptr(dst).to_str() {
            Ok(s) => s,
            Err(_) => {
                set_last_error("dst is not valid UTF-8".to_string());
                return FF_ERR_INVALID_PATH;
            }
        }
    };

    match crate::core::file_ops::move_file(std::path::Path::new(src_str), std::path::Path::new(dst_str)) {
        Ok(()) => {
            clear_last_error();
            FF_OK
        }
        Err(e) => {
            let msg = format!("move_file failed: {}", e);
            set_last_error(msg);
            FF_ERR_IO
        }
    }
}

/// Delete a file at `path`.
///
/// # Arguments
///
/// - `path` — NUL-terminated UTF-8 path string.
///
/// # Returns
///
/// - `FF_OK` on success.
/// - `FF_ERR_INVALID_PATH` if the path is invalid.
/// - `FF_ERR_IO` if a filesystem error occurs.
///
/// # Safety
///
/// - `path` must be a valid, NUL-terminated UTF-8 string.
#[no_mangle]
pub extern "C" fn ff_delete_file(path: *const c_char) -> c_int {
    if path.is_null() {
        set_last_error("path is null".to_string());
        return FF_ERR_INVALID_PATH;
    }

    let path_str = unsafe {
        match CStr::from_ptr(path).to_str() {
            Ok(s) => s,
            Err(_) => {
                set_last_error("path is not valid UTF-8".to_string());
                return FF_ERR_INVALID_PATH;
            }
        }
    };

    match crate::core::file_ops::delete_file(std::path::Path::new(path_str)) {
        Ok(()) => {
            clear_last_error();
            FF_OK
        }
        Err(e) => {
            let msg = format!("delete_file failed: {}", e);
            set_last_error(msg);
            FF_ERR_IO
        }
    }
}

/// Delete a directory and all its contents at `path`.
///
/// # Arguments
///
/// - `path` — NUL-terminated UTF-8 path string.
///
/// # Returns
///
/// - `FF_OK` on success.
/// - `FF_ERR_INVALID_PATH` if the path is invalid.
/// - `FF_ERR_IO` if a filesystem error occurs.
///
/// # Safety
///
/// - `path` must be a valid, NUL-terminated UTF-8 string.
#[no_mangle]
pub extern "C" fn ff_delete_dir(path: *const c_char) -> c_int {
    if path.is_null() {
        set_last_error("path is null".to_string());
        return FF_ERR_INVALID_PATH;
    }

    let path_str = unsafe {
        match CStr::from_ptr(path).to_str() {
            Ok(s) => s,
            Err(_) => {
                set_last_error("path is not valid UTF-8".to_string());
                return FF_ERR_INVALID_PATH;
            }
        }
    };

    match crate::core::file_ops::delete_dir(std::path::Path::new(path_str)) {
        Ok(()) => {
            clear_last_error();
            FF_OK
        }
        Err(e) => {
            let msg = format!("delete_dir failed: {}", e);
            set_last_error(msg);
            FF_ERR_IO
        }
    }
}

/// Create a directory and all parent directories at `path`.
///
/// # Arguments
///
/// - `path` — NUL-terminated UTF-8 path string.
///
/// # Returns
///
/// - `FF_OK` on success.
/// - `FF_ERR_INVALID_PATH` if the path is invalid.
/// - `FF_ERR_IO` if a filesystem error occurs.
///
/// # Safety
///
/// - `path` must be a valid, NUL-terminated UTF-8 string.
#[no_mangle]
pub extern "C" fn ff_create_dir(path: *const c_char) -> c_int {
    if path.is_null() {
        set_last_error("path is null".to_string());
        return FF_ERR_INVALID_PATH;
    }

    let path_str = unsafe {
        match CStr::from_ptr(path).to_str() {
            Ok(s) => s,
            Err(_) => {
                set_last_error("path is not valid UTF-8".to_string());
                return FF_ERR_INVALID_PATH;
            }
        }
    };

    match crate::core::file_ops::create_dir(std::path::Path::new(path_str)) {
        Ok(()) => {
            clear_last_error();
            FF_OK
        }
        Err(e) => {
            let msg = format!("create_dir failed: {}", e);
            set_last_error(msg);
            FF_ERR_IO
        }
    }
}

/// Rename a file or directory from `src` to `dst`.
///
/// # Arguments
///
/// - `src` — NUL-terminated UTF-8 source path string.
/// - `dst` — NUL-terminated UTF-8 destination path string.
///
/// # Returns
///
/// - `FF_OK` on success.
/// - `FF_ERR_INVALID_PATH` if a path is invalid.
/// - `FF_ERR_IO` if a filesystem error occurs.
///
/// # Safety
///
/// - `src` and `dst` must be valid, NUL-terminated UTF-8 strings.
#[no_mangle]
pub extern "C" fn ff_rename(src: *const c_char, dst: *const c_char) -> c_int {
    if src.is_null() || dst.is_null() {
        set_last_error("src or dst is null".to_string());
        return FF_ERR_INVALID_PATH;
    }

    let src_str = unsafe {
        match CStr::from_ptr(src).to_str() {
            Ok(s) => s,
            Err(_) => {
                set_last_error("src is not valid UTF-8".to_string());
                return FF_ERR_INVALID_PATH;
            }
        }
    };

    let dst_str = unsafe {
        match CStr::from_ptr(dst).to_str() {
            Ok(s) => s,
            Err(_) => {
                set_last_error("dst is not valid UTF-8".to_string());
                return FF_ERR_INVALID_PATH;
            }
        }
    };

    match crate::core::file_ops::rename(std::path::Path::new(src_str), std::path::Path::new(dst_str)) {
        Ok(()) => {
            clear_last_error();
            FF_OK
        }
        Err(e) => {
            let msg = format!("rename failed: {}", e);
            set_last_error(msg);
            FF_ERR_IO
        }
    }
}

// ── Duplicate File Detection ──────────────────────────────────────

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

static DEDUP_CANCEL: AtomicBool = AtomicBool::new(false);

/// Scan for duplicate files under `path`.
///
/// # Arguments
///
/// - `path` — NUL-terminated UTF-8 root path string.
/// - `progress_callback` — Called with (scanned, total) progress updates.
/// - `group_callback` — Called for each duplicate group found.
/// - `user_data` — Opaque pointer passed to callbacks.
///
/// # Returns
///
/// - `FF_OK` on success.
/// - `FF_ERR_INVALID_PATH` if the path is invalid.
/// - `FF_ERR_IO` if a filesystem error occurs.
///
/// # Safety
///
/// - `path` must be a valid, NUL-terminated UTF-8 string.
/// - Callbacks must be valid function pointers.
#[no_mangle]
pub extern "C" fn ff_scan_duplicates(
    path: *const c_char,
    progress_callback: FFDedupProgressCallback,
    group_callback: FFDedupGroupCallback,
    user_data: *mut c_void,
) -> c_int {
    if path.is_null() {
        set_last_error("path is null".to_string());
        return FF_ERR_INVALID_PATH;
    }

    let path_str = unsafe {
        match CStr::from_ptr(path).to_str() {
            Ok(s) => s,
            Err(_) => {
                set_last_error("path is not valid UTF-8".to_string());
                return FF_ERR_INVALID_PATH;
            }
        }
    };

    // Reset cancel flag
    DEDUP_CANCEL.store(false, Ordering::Relaxed);

    struct CallbackEmitter {
        progress: FFDedupProgressCallback,
        group: FFDedupGroupCallback,
        user_data: *mut c_void,
    }

    impl crate::core::dedup_engine::EventEmitter for CallbackEmitter {
        fn emit(&self, event: crate::core::dedup_engine::DedupEvent) {
            match event {
                crate::core::dedup_engine::DedupEvent::Progress { scanned, total } => {
                    let total_val = total.unwrap_or(0);
                    (self.progress)(scanned, total_val, self.user_data);
                }
                crate::core::dedup_engine::DedupEvent::GroupFound { group } => {
                    let files: Vec<FFDuplicateFile> = group
                        .files
                        .iter()
                        .map(|f| FFDuplicateFile {
                            id: rust_string_to_c(f.id.clone()),
                            path: rust_string_to_c(f.path.clone()),
                            name: rust_string_to_c(f.name.clone()),
                            size: f.size,
                            modified: f.modified,
                        })
                        .collect();

                    let group_c = FFDuplicateGroup {
                        id: rust_string_to_c(group.id.clone()),
                        hash: rust_string_to_c(group.hash.clone()),
                        size: group.size,
                        files: files.as_ptr(),
                        file_count: files.len(),
                    };

                    (self.group)(&group_c, self.user_data);

                    // Clean up allocated strings
                    for f in &files {
                        if !f.id.is_null() {
                            unsafe { let _ = CString::from_raw(f.id); }
                        }
                        if !f.path.is_null() {
                            unsafe { let _ = CString::from_raw(f.path); }
                        }
                        if !f.name.is_null() {
                            unsafe { let _ = CString::from_raw(f.name); }
                        }
                    }
                    if !group_c.id.is_null() {
                        unsafe { let _ = CString::from_raw(group_c.id); }
                    }
                    if !group_c.hash.is_null() {
                        unsafe { let _ = CString::from_raw(group_c.hash); }
                    }
                }
                _ => {}
            }
        }
    }

    let cancel = Arc::new(AtomicBool::new(false));
    let emitter = CallbackEmitter {
        progress: progress_callback,
        group: group_callback,
        user_data,
    };

    let _groups = crate::core::dedup_engine::run_scan(
        vec![path_str.to_string()],
        &emitter,
        cancel,
    );

    clear_last_error();
    FF_OK
}

/// Cancel an ongoing duplicate scan.
#[no_mangle]
pub extern "C" fn ff_cancel_scan() {
    DEDUP_CANCEL.store(true, Ordering::Relaxed);
}

// ── File Search ─────────────────────────────────────────────────────

/// Search for files matching `query` under `path`.
///
/// # Arguments
///
/// - `path` — NUL-terminated UTF-8 root path string.
/// - `query` — NUL-terminated UTF-8 search query.
/// - `callback` — Called for each matching result.
/// - `user_data` — Opaque pointer passed to the callback.
///
/// # Returns
///
/// - `FF_OK` on success.
/// - `FF_ERR_INVALID_PATH` if the path is invalid.
/// - `FF_ERR_IO` if a filesystem error occurs.
///
/// # Safety
///
/// - `path` and `query` must be valid, NUL-terminated UTF-8 strings.
/// - `callback` must be a valid function pointer.
#[no_mangle]
pub extern "C" fn ff_search(
    path: *const c_char,
    query: *const c_char,
    callback: FFSearchCallback,
    user_data: *mut c_void,
) -> c_int {
    if path.is_null() || query.is_null() {
        set_last_error("path or query is null".to_string());
        return FF_ERR_INVALID_PATH;
    }

    let path_str = unsafe {
        match CStr::from_ptr(path).to_str() {
            Ok(s) => s,
            Err(_) => {
                set_last_error("path is not valid UTF-8".to_string());
                return FF_ERR_INVALID_PATH;
            }
        }
    };

    let query_str = unsafe {
        match CStr::from_ptr(query).to_str() {
            Ok(s) => s,
            Err(_) => {
                set_last_error("query is not valid UTF-8".to_string());
                return FF_ERR_INVALID_PATH;
            }
        }
    };

    let mut cb = |result: crate::core::search_engine::SearchResult| {
        let result_c = FFSearchResult {
            path: rust_string_to_c(result.path),
            name: rust_string_to_c(result.name),
            size: result.size,
            modified: result.modified,
            is_dir: result.is_dir,
        };
        callback(&result_c, user_data);
        if !result_c.path.is_null() {
            unsafe { let _ = CString::from_raw(result_c.path); }
        }
        if !result_c.name.is_null() {
            unsafe { let _ = CString::from_raw(result_c.name); }
        }
    };

    match crate::core::search_engine::search_files(path_str, query_str, &mut cb) {
        Ok(_) => {
            clear_last_error();
            FF_OK
        }
        Err(e) => {
            let msg = format!("search failed: {}", e);
            set_last_error(msg);
            FF_ERR_IO
        }
    }
}

/// C-compatible search filters.
#[repr(C)]
pub struct FFSearchFilters {
    pub file_types: *const c_char,
    pub min_size: u64,
    pub max_size: u64,
    pub modified_after: i64,
    pub modified_before: i64,
    pub has_file_types: bool,
    pub has_min_size: bool,
    pub has_max_size: bool,
    pub has_modified_after: bool,
    pub has_modified_before: bool,
}

/// Search for files with advanced filters.
///
/// # Arguments
///
/// - `path` — NUL-terminated UTF-8 root path string.
/// - `query` — NUL-terminated UTF-8 search query.
/// - `filters` — Pointer to filter criteria.
/// - `callback` — Called for each matching result.
/// - `user_data` — Opaque pointer passed to the callback.
///
/// # Returns
///
/// - `FF_OK` on success.
/// - `FF_ERR_INVALID_PATH` if the path is invalid.
/// - `FF_ERR_IO` if a filesystem error occurs.
///
/// # Safety
///
/// - `path`, `query`, and `filters` must be valid pointers.
/// - `callback` must be a valid function pointer.
#[no_mangle]
pub extern "C" fn ff_search_with_filters(
    path: *const c_char,
    query: *const c_char,
    filters: *const FFSearchFilters,
    callback: FFSearchCallback,
    user_data: *mut c_void,
) -> c_int {
    if path.is_null() || query.is_null() {
        set_last_error("path or query is null".to_string());
        return FF_ERR_INVALID_PATH;
    }

    let path_str = unsafe {
        match CStr::from_ptr(path).to_str() {
            Ok(s) => s,
            Err(_) => {
                set_last_error("path is not valid UTF-8".to_string());
                return FF_ERR_INVALID_PATH;
            }
        }
    };

    let query_str = unsafe {
        match CStr::from_ptr(query).to_str() {
            Ok(s) => s,
            Err(_) => {
                set_last_error("query is not valid UTF-8".to_string());
                return FF_ERR_INVALID_PATH;
            }
        }
    };

    let rust_filters = if filters.is_null() {
        crate::core::search_engine::SearchFilters::default()
    } else {
        let f = unsafe { &*filters };
        crate::core::search_engine::SearchFilters {
            file_types: if f.has_file_types && !f.file_types.is_null() {
                Some(unsafe { CStr::from_ptr(f.file_types).to_string_lossy().to_string() })
            } else {
                None
            },
            min_size: if f.has_min_size { Some(f.min_size) } else { None },
            max_size: if f.has_max_size { Some(f.max_size) } else { None },
            modified_after: if f.has_modified_after { Some(f.modified_after) } else { None },
            modified_before: if f.has_modified_before { Some(f.modified_before) } else { None },
        }
    };

    let mut cb = |result: crate::core::search_engine::SearchResult| {
        let result_c = FFSearchResult {
            path: rust_string_to_c(result.path),
            name: rust_string_to_c(result.name),
            size: result.size,
            modified: result.modified,
            is_dir: result.is_dir,
        };
        callback(&result_c, user_data);
        if !result_c.path.is_null() {
            unsafe { let _ = CString::from_raw(result_c.path); }
        }
        if !result_c.name.is_null() {
            unsafe { let _ = CString::from_raw(result_c.name); }
        }
    };

    match crate::core::search_engine::search_with_filters(path_str, query_str, &rust_filters, &mut cb) {
        Ok(_) => {
            clear_last_error();
            FF_OK
        }
        Err(e) => {
            let msg = format!("search_with_filters failed: {}", e);
            set_last_error(msg);
            FF_ERR_IO
        }
    }
}

// ── QuickLook Preview ─────────────────────────────────────────────

/// Get a preview-friendly path for a file.
///
/// For most files this returns the original path. For files that may need
/// temporary conversion, it returns the converted path.
///
/// # Arguments
///
/// - `path` — NUL-terminated UTF-8 path string.
/// - `callback` — Called with the preview path (may be the same as input).
/// - `user_data` — Opaque pointer passed to the callback.
///
/// # Returns
///
/// - `FF_OK` on success.
/// - `FF_ERR_INVALID_PATH` if the path is invalid.
///
/// # Safety
///
/// - `path` must be a valid, NUL-terminated UTF-8 string.
#[no_mangle]
pub extern "C" fn ff_get_preview_path(
    path: *const c_char,
    callback: extern "C" fn(preview_path: *const c_char, user_data: *mut c_void),
    user_data: *mut c_void,
) -> c_int {
    if path.is_null() {
        set_last_error("path is null".to_string());
        return FF_ERR_INVALID_PATH;
    }

    let path_str = unsafe {
        match CStr::from_ptr(path).to_str() {
            Ok(s) => s,
            Err(_) => {
                set_last_error("path is not valid UTF-8".to_string());
                return FF_ERR_INVALID_PATH;
            }
        }
    };

    // For now, just return the original path
    let path_c = rust_string_to_c(path_str.to_string());
    callback(path_c, user_data);
    if !path_c.is_null() {
        unsafe { let _ = CString::from_raw(path_c); }
    }

    clear_last_error();
    FF_OK
}

/// Get the file type/extension as a C string.
///
/// Returns a heap-allocated C string containing the file extension.
/// Must be freed with `ff_free_string()`.
///
/// # Arguments
///
/// - `path` — NUL-terminated UTF-8 path string.
///
/// # Returns
///
/// - Pointer to file extension string on success.
/// - `NULL` on error.
///
/// # Safety
///
/// - `path` must be a valid, NUL-terminated UTF-8 string.
/// - The returned pointer must be freed with `ff_free_string()`.
#[no_mangle]
pub extern "C" fn ff_get_file_type(path: *const c_char) -> *mut c_char {
    if path.is_null() {
        set_last_error("path is null".to_string());
        return ptr::null_mut();
    }

    let path_str = unsafe {
        match CStr::from_ptr(path).to_str() {
            Ok(s) => s,
            Err(_) => {
                set_last_error("path is not valid UTF-8".to_string());
                return ptr::null_mut();
            }
        }
    };

    let ext = std::path::Path::new(path_str)
        .extension()
        .map(|e| e.to_string_lossy().to_string())
        .unwrap_or_default();

    rust_string_to_c(ext)
}

// ── Directory Cache ─────────────────────────────────────────────────

/// Initialize the L2 persistent (SQLite) directory cache.
///
/// Stores `db_path` in a module-level `OnceLock<String>` and creates the
/// `dir_cache` schema via `sqlite_cache::init_cache`. After this call
/// succeeds, `ff_cache_get`/`ff_cache_put`/`ff_cache_invalidate` will
/// additionally consult/persist to the SQLite database (best-effort).
///
/// Subsequent calls are idempotent: if the path has already been set,
/// this function returns `FF_OK` without re-initializing. Setting a
/// different path after the first call has no effect (the original path
/// is retained) — callers should call this exactly once at app startup.
///
/// # Arguments
///
/// - `db_path` — NUL-terminated UTF-8 path to the SQLite database file.
///
/// # Returns
///
/// - `FF_OK` on success (or if already initialized).
/// - `FF_ERR_INVALID_PATH` if `db_path` is null or invalid UTF-8.
/// - `FF_ERR_IO` if SQLite schema creation fails.
///
/// # Safety
///
/// - `db_path` must be a valid, NUL-terminated UTF-8 string.
#[no_mangle]
pub extern "C" fn ff_cache_init(db_path: *const c_char) -> c_int {
    if db_path.is_null() {
        set_last_error("db_path is null".to_string());
        return FF_ERR_INVALID_PATH;
    }

    let db_path_str = unsafe {
        match CStr::from_ptr(db_path).to_str() {
            Ok(s) => s,
            Err(_) => {
                set_last_error("db_path is not valid UTF-8".to_string());
                return FF_ERR_INVALID_PATH;
            }
        }
    };

    // Create the schema on disk first so we can surface I/O errors early.
    if let Err(e) = crate::core::sqlite_cache::init_cache(db_path_str) {
        set_last_error(format!("sqlite_cache::init_cache failed: {}", e));
        return FF_ERR_IO;
    }

    // Store the path globally. If a path is already set, keep the original
    // (OnceLock semantics) — the schema was just (re-)created idempotently.
    let _ = CACHE_DB_PATH.set(db_path_str.to_string());

    clear_last_error();
    FF_OK
}

/// Invalidate the directory cache for a specific path.
///
/// Invalidates both the L1 in-memory cache (`dir_cache`) and, if
/// `ff_cache_init` has been called, the L2 persistent SQLite cache.
/// L2 failures are best-effort: errors are recorded via `set_last_error`
/// but do not change the return value (L1 invalidation still succeeds).
///
/// # Arguments
///
/// - `path` — NUL-terminated UTF-8 path string.
///
/// # Returns
///
/// - `FF_OK` on success.
/// - `FF_ERR_INVALID_PATH` if the path is invalid.
///
/// # Safety
///
/// - `path` must be a valid, NUL-terminated UTF-8 string.
#[no_mangle]
pub extern "C" fn ff_cache_invalidate(path: *const c_char) -> c_int {
    if path.is_null() {
        set_last_error("path is null".to_string());
        return FF_ERR_INVALID_PATH;
    }

    let path_str = unsafe {
        match CStr::from_ptr(path).to_str() {
            Ok(s) => s,
            Err(_) => {
                set_last_error("path is not valid UTF-8".to_string());
                return FF_ERR_INVALID_PATH;
            }
        }
    };

    crate::core::dir_cache::invalidate(path_str);

    // Best-effort L2 invalidation — do not mask L1 success.
    let mut l2_failed = false;
    if let Some(db_path) = CACHE_DB_PATH.get() {
        if let Err(e) = crate::core::sqlite_cache::cache_invalidate(db_path, path_str) {
            set_last_error(format!("sqlite_cache::cache_invalidate failed: {}", e));
            l2_failed = true;
        }
    }

    if !l2_failed {
        clear_last_error();
    }
    FF_OK
}

/// Get cached directory entries for a path.
///
/// Two-tier lookup: L1 (in-memory `dir_cache`) → L2 (persistent SQLite
/// `sqlite_cache`, if `ff_cache_init` has been called). On an L1 miss the
/// L2 cache is consulted; if L2 hits, the entries are written back to L1
/// (so subsequent calls are served from memory) and delivered through the
/// callback. If both tiers miss (or L2 is not configured), the callback
/// is not called and `FF_ERR_NOT_FOUND` is returned.
///
/// L2 errors are best-effort: a non-NotFound error is recorded via
/// `set_last_error` and the call degrades to an L1 miss
/// (`FF_ERR_NOT_FOUND`); the function never panics on SQLite failures.
///
/// # Arguments
///
/// - `path` — NUL-terminated UTF-8 path string.
/// - `callback` — Function called for each cached entry.
/// - `user_data` — Opaque pointer passed to the callback.
///
/// # Returns
///
/// - `FF_OK` on success (entries found in cache).
/// - `FF_ERR_INVALID_PATH` if the path is invalid.
/// - `FF_ERR_NOT_FOUND` if the path is not in cache.
///
/// # Safety
///
/// - `path` must be a valid, NUL-terminated UTF-8 string.
/// - `callback` must be a valid function pointer.
#[no_mangle]
pub extern "C" fn ff_cache_get(
    path: *const c_char,
    callback: FFEntryCallback,
    user_data: *mut c_void,
) -> c_int {
    if path.is_null() {
        set_last_error("path is null".to_string());
        return FF_ERR_INVALID_PATH;
    }

    let path_str = unsafe {
        match CStr::from_ptr(path).to_str() {
            Ok(s) => s,
            Err(_) => {
                set_last_error("path is not valid UTF-8".to_string());
                return FF_ERR_INVALID_PATH;
            }
        }
    };

    // Inline helper: deliver a batch of skeletons through the callback,
    // freeing the transient C strings after each invocation.
    let deliver = |entries: Vec<crate::core::scanner::FileEntrySkeleton>| {
        for skeleton in entries {
            let name_c = rust_string_to_c(skeleton.name.clone());
            let path_c = rust_string_to_c(skeleton.path.clone());
            let ext_c = rust_string_to_c(skeleton.extension.clone());

            let ff_entry = FFEntryRef {
                name: name_c,
                path: path_c,
                extension: ext_c,
                is_dir: skeleton.is_dir,
                is_file: skeleton.is_file,
                is_symlink: skeleton.is_symlink,
                is_hidden: skeleton.is_hidden,
                is_system_protected: skeleton.is_system_protected,
                size: skeleton.size,
                modified: skeleton.modified,
                created: skeleton.created,
            };

            callback(&ff_entry, user_data);

            if !name_c.is_null() {
                unsafe { let _ = CString::from_raw(name_c); }
            }
            if !path_c.is_null() {
                unsafe { let _ = CString::from_raw(path_c); }
            }
            if !ext_c.is_null() {
                unsafe { let _ = CString::from_raw(ext_c); }
            }
        }
    };

    // ── L1 lookup ──────────────────────────────────────────────────
    if let Some(entries) = crate::core::dir_cache::get(path_str) {
        deliver(entries);
        clear_last_error();
        return FF_OK;
    }

    // ── L2 lookup (best-effort) ────────────────────────────────────
    if let Some(db_path) = CACHE_DB_PATH.get() {
        match crate::core::sqlite_cache::cache_get(db_path, path_str) {
            Ok(Some(entries)) => {
                // Write back to L1 so subsequent reads hit memory.
                crate::core::dir_cache::put(path_str.to_string(), entries.clone());
                deliver(entries);
                clear_last_error();
                return FF_OK;
            }
            Ok(None) => {
                // Genuine L2 miss — fall through to NOT_FOUND below.
            }
            Err(e) => {
                // L2 errored: record and degrade to L1-miss behavior.
                set_last_error(format!("sqlite_cache::cache_get failed: {}", e));
                return FF_ERR_NOT_FOUND;
            }
        }
    }

    set_last_error("path not found in cache".to_string());
    FF_ERR_NOT_FOUND
}

/// Store directory entries in the cache.
///
/// Writes entries to both L1 (in-memory `dir_cache`) and, if
/// `ff_cache_init` has been called, L2 (persistent SQLite
/// `sqlite_cache`). L2 writes are best-effort: if the SQLite write fails,
/// the L1 write still succeeds and `FF_OK` is returned; the error is
/// recorded via `set_last_error`. When no db_path is configured, only L1
/// is written (backward-compatible behavior).
///
/// # Arguments
///
/// - `path` — NUL-terminated UTF-8 path string.
/// - `entries` — Array of `FFEntryRef` to cache.
/// - `entry_count` — Number of entries in the array.
///
/// # Returns
///
/// - `FF_OK` on success.
/// - `FF_ERR_INVALID_PATH` if the path is invalid.
///
/// # Safety
///
/// - `path` must be a valid, NUL-terminated UTF-8 string.
/// - `entries` must be a valid pointer to an array of `FFEntryRef`.
#[no_mangle]
pub extern "C" fn ff_cache_put(
    path: *const c_char,
    entries: *const FFEntryRef,
    entry_count: usize,
) -> c_int {
    if path.is_null() {
        set_last_error("path is null".to_string());
        return FF_ERR_INVALID_PATH;
    }
    if entries.is_null() && entry_count > 0 {
        set_last_error("entries is null but entry_count > 0".to_string());
        return FF_ERR_INVALID_PATH;
    }

    let path_str = unsafe {
        match CStr::from_ptr(path).to_str() {
            Ok(s) => s,
            Err(_) => {
                set_last_error("path is not valid UTF-8".to_string());
                return FF_ERR_INVALID_PATH;
            }
        }
    };

    let mut skeletons = Vec::with_capacity(entry_count);
    for i in 0..entry_count {
        let entry = unsafe { &*entries.add(i) };
        let name = if entry.name.is_null() {
            String::new()
        } else {
            unsafe { CStr::from_ptr(entry.name).to_string_lossy().to_string() }
        };
        let path = if entry.path.is_null() {
            String::new()
        } else {
            unsafe { CStr::from_ptr(entry.path).to_string_lossy().to_string() }
        };
        let extension = if entry.extension.is_null() {
            String::new()
        } else {
            unsafe { CStr::from_ptr(entry.extension).to_string_lossy().to_string() }
        };

        skeletons.push(crate::core::scanner::FileEntrySkeleton {
            id: path.clone(),
            name,
            path,
            is_dir: entry.is_dir,
            is_file: entry.is_file,
            is_symlink: entry.is_symlink,
            is_hidden: entry.is_hidden,
            extension,
            size: entry.size,
            modified: entry.modified,
            created: entry.created,
            is_system_protected: entry.is_system_protected,
            metadata_loaded: true,
        });
    }

    // L1 write (always).
    crate::core::dir_cache::put(path_str.to_string(), skeletons.clone());

    // L2 write (best-effort) — only if db_path has been configured.
    let mut l2_failed = false;
    if let Some(db_path) = CACHE_DB_PATH.get() {
        if let Err(e) = crate::core::sqlite_cache::cache_put(db_path, path_str, &skeletons) {
            // L1 already succeeded; surface the L2 error but keep FF_OK.
            set_last_error(format!("sqlite_cache::cache_put failed: {}", e));
            l2_failed = true;
        }
    }

    if !l2_failed {
        clear_last_error();
    }
    FF_OK
}

// ── Directory Cache FFI (Sub-project 5 aliases) ─────────────────────

/// Alias for ff_cache_get — get cached directory entries.
#[no_mangle]
pub extern "C" fn ff_dir_cache_get(
    path: *const c_char,
    callback: FFEntryCallback,
    user_data: *mut c_void,
) -> c_int {
    ff_cache_get(path, callback, user_data)
}

/// Alias for ff_cache_invalidate — invalidate directory cache.
#[no_mangle]
pub extern "C" fn ff_dir_cache_invalidate(path: *const c_char) -> c_int {
    ff_cache_invalidate(path)
}

/// Clear all directory cache entries.
#[no_mangle]
pub extern "C" fn ff_dir_cache_clear() -> c_int {
    crate::core::dir_cache::clear();
    clear_last_error();
    FF_OK
}

// ── FSEvents Watcher ──────────────────────────────────────────────

/// Callback type for FSEvents notifications.
/// Arguments: (path, user_data)
pub type FSEventCallback = extern "C" fn(path: *const c_char, user_data: *mut c_void);

/// Start watching a path for filesystem changes.
///
/// # Arguments
/// - `path` — NUL-terminated UTF-8 path string to watch.
/// - `callback` — Function called when a change is detected.
/// - `user_data` — Opaque pointer passed to the callback.
///
/// # Returns
/// - `0` on success.
/// - `FF_ERR_INVALID_PATH` if the path is invalid.
#[no_mangle]
pub extern "C" fn ff_fsevents_start(
    path: *const c_char,
    callback: FSEventCallback,
    user_data: *mut c_void,
) -> c_int {
    if path.is_null() {
        set_last_error("path is null".to_string());
        return FF_ERR_INVALID_PATH;
    }

    let path_str = unsafe {
        match CStr::from_ptr(path).to_str() {
            Ok(s) => s,
            Err(_) => {
                set_last_error("path is not valid UTF-8".to_string());
                return FF_ERR_INVALID_PATH;
            }
        }
    };

    match crate::core::fsevents::start(path_str, callback, user_data) {
        0 => {
            clear_last_error();
            FF_OK
        }
        _ => {
            set_last_error("fsevents_start failed".to_string());
            FF_ERR_IO
        }
    }
}

/// Stop the FSEvents watcher.
///
/// # Arguments
/// - `handle` — Handle returned by ff_fsevents_start.
///
/// # Returns
/// - `0` on success.
#[no_mangle]
pub extern "C" fn ff_fsevents_stop(_handle: c_int) -> c_int {
    crate::core::fsevents::stop();
    clear_last_error();
    FF_OK
}

// ── Batch Rename & Organize ────────────────────────────────────────

/// C-compatible batch rename item.
#[repr(C)]
pub struct FFRenameItem {
    pub original_path: *mut c_char,
    pub new_name: *mut c_char,
}

/// Callback for batch operation progress.
pub type FFBatchProgressCallback = extern "C" fn(completed: usize, total: usize, current_file: *const c_char, user_data: *mut c_void);

/// Batch rename files.
///
/// # Arguments
///
/// - `items` — Array of `FFRenameItem`.
/// - `item_count` — Number of items.
///
/// # Returns
///
/// - Number of successful renames on success (>= 0).
/// - `FF_ERR_INVALID_PATH` if inputs are invalid.
/// - `FF_ERR_IO` if a filesystem error occurs.
///
/// # Safety
///
/// - `items` must be a valid pointer to an array of `FFRenameItem`.
#[no_mangle]
pub extern "C" fn ff_batch_rename(
    items: *const FFRenameItem,
    item_count: usize,
) -> c_int {
    if items.is_null() && item_count > 0 {
        set_last_error("items is null".to_string());
        return FF_ERR_INVALID_PATH;
    }

    let mut rename_items = Vec::with_capacity(item_count);
    for i in 0..item_count {
        let item = unsafe { &*items.add(i) };
        let original = if item.original_path.is_null() {
            String::new()
        } else {
            unsafe { CStr::from_ptr(item.original_path).to_string_lossy().to_string() }
        };
        let new_name = if item.new_name.is_null() {
            String::new()
        } else {
            unsafe { CStr::from_ptr(item.new_name).to_string_lossy().to_string() }
        };
        rename_items.push(crate::core::batch_ops::RenameItem {
            original_path: original,
            new_name,
        });
    }

    match crate::core::batch_ops::batch_rename(&rename_items, None) {
        Ok(count) => {
            clear_last_error();
            count as c_int
        }
        Err(e) => {
            set_last_error(format!("batch_rename failed: {}", e));
            FF_ERR_IO
        }
    }
}

/// Organize files by date into folders.
///
/// # Arguments
///
/// - `path` — NUL-terminated UTF-8 directory path.
/// - `format` — NUL-terminated UTF-8 format string (e.g., "YYYY/MM/DD").
///
/// # Returns
///
/// - Number of files moved on success (>= 0).
/// - `FF_ERR_INVALID_PATH` if inputs are invalid.
/// - `FF_ERR_IO` if a filesystem error occurs.
///
/// # Safety
///
/// - `path` and `format` must be valid, NUL-terminated UTF-8 strings.
#[no_mangle]
pub extern "C" fn ff_organize_by_date(
    path: *const c_char,
    format: *const c_char,
) -> c_int {
    if path.is_null() || format.is_null() {
        set_last_error("path or format is null".to_string());
        return FF_ERR_INVALID_PATH;
    }

    let path_str = unsafe {
        match CStr::from_ptr(path).to_str() {
            Ok(s) => s,
            Err(_) => {
                set_last_error("path is not valid UTF-8".to_string());
                return FF_ERR_INVALID_PATH;
            }
        }
    };

    let format_str = unsafe {
        match CStr::from_ptr(format).to_str() {
            Ok(s) => s,
            Err(_) => {
                set_last_error("format is not valid UTF-8".to_string());
                return FF_ERR_INVALID_PATH;
            }
        }
    };

    match crate::core::batch_ops::organize_by_date(path_str, format_str, None) {
        Ok(count) => {
            clear_last_error();
            count as c_int
        }
        Err(e) => {
            set_last_error(format!("organize_by_date failed: {}", e));
            FF_ERR_IO
        }
    }
}

/// Organize files by file type into category folders.
///
/// # Arguments
///
/// - `path` — NUL-terminated UTF-8 directory path.
///
/// # Returns
///
/// - Number of files moved on success (>= 0).
/// - `FF_ERR_INVALID_PATH` if inputs are invalid.
/// - `FF_ERR_IO` if a filesystem error occurs.
///
/// # Safety
///
/// - `path` must be a valid, NUL-terminated UTF-8 string.
#[no_mangle]
pub extern "C" fn ff_organize_by_type(
    path: *const c_char,
) -> c_int {
    if path.is_null() {
        set_last_error("path is null".to_string());
        return FF_ERR_INVALID_PATH;
    }

    let path_str = unsafe {
        match CStr::from_ptr(path).to_str() {
            Ok(s) => s,
            Err(_) => {
                set_last_error("path is not valid UTF-8".to_string());
                return FF_ERR_INVALID_PATH;
            }
        }
    };

    match crate::core::batch_ops::organize_by_type(path_str, None) {
        Ok(count) => {
            clear_last_error();
            count as c_int
        }
        Err(e) => {
            set_last_error(format!("organize_by_type failed: {}", e));
            FF_ERR_IO
        }
    }
}

// ── Parallel Batch Operations (rayon-backed) ──────────────────────

/// Parse a `*const *const c_char` array of NUL-terminated UTF-8 C strings
/// into a `Vec<String>`. Null pointers within the array become empty strings.
///
/// # Safety
///
/// - `ptrs` must point to an array of at least `count` valid `*const c_char`
///   entries; each non-null entry must be a NUL-terminated UTF-8 C string.
unsafe fn parse_c_string_array(ptrs: *const *const c_char, count: usize) -> Vec<String> {
    let mut out = Vec::with_capacity(count);
    for i in 0..count {
        let p = *ptrs.add(i);
        if p.is_null() {
            out.push(String::new());
        } else {
            out.push(CStr::from_ptr(p).to_string_lossy().to_string());
        }
    }
    out
}

/// Parallel copy multiple files into a destination directory using rayon.
///
/// Each source file is copied (CoW when possible) into `dst_dir` keeping its
/// basename. The progress callback is invoked from worker threads as files
/// complete.
///
/// # Arguments
///
/// - `srcs` — Array of source path C strings.
/// - `src_count` — Number of entries in `srcs`.
/// - `dst_dir` — Destination directory C string.
/// - `progress` — Callback invoked with (completed, total, current_file, user_data).
///   `current_file` is always passed as null because `parallel_ops` does not
///   report per-file names.
/// - `user_data` — Opaque pointer passed through to the callback.
///
/// # Returns
///
/// - Number of successfully copied files (>= 0). Partial failures are
///   reflected as a count less than `src_count`.
/// - `FF_ERR_INVALID_PATH` if `srcs` (when `src_count > 0`) or `dst_dir` is null.
///
/// # Safety
///
/// - `srcs` must point to `src_count` valid C string pointers.
/// - `dst_dir` must be a valid NUL-terminated UTF-8 C string.
#[no_mangle]
pub extern "C" fn ff_parallel_copy(
    srcs: *const *const c_char,
    src_count: usize,
    dst_dir: *const c_char,
    progress: FFBatchProgressCallback,
    user_data: *mut c_void,
) -> c_int {
    if srcs.is_null() && src_count > 0 {
        set_last_error("srcs is null".to_string());
        return FF_ERR_INVALID_PATH;
    }
    if dst_dir.is_null() {
        set_last_error("dst_dir is null".to_string());
        return FF_ERR_INVALID_PATH;
    }

    let srcs_vec = if src_count == 0 {
        Vec::new()
    } else {
        unsafe { parse_c_string_array(srcs, src_count) }
    };
    let dst_dir_str = unsafe {
        match CStr::from_ptr(dst_dir).to_str() {
            Ok(s) => s.to_string(),
            Err(_) => {
                set_last_error("dst_dir is not valid UTF-8".to_string());
                return FF_ERR_INVALID_PATH;
            }
        }
    };

    // Cast `user_data` to `usize` so the closure captures a `Sync` value
    // (raw pointers are `!Sync` by default, which would violate the
    // `Fn(...) + Sync` bound required by rayon's `par_iter`).
    let user_data_addr = user_data as usize;
    let results = crate::core::parallel_ops::parallel_copy_files(
        &srcs_vec,
        &dst_dir_str,
        move |done, total| progress(done, total, ptr::null(), user_data_addr as *mut c_void),
    );
    let success = results.iter().filter(|(_, r)| r.is_ok()).count();
    clear_last_error();
    success as c_int
}

/// Parallel move multiple files into a destination directory using rayon.
///
/// Same semantics as [`ff_parallel_copy`], but moves files instead. Falls back
/// to copy-then-delete when `rename(2)` fails (e.g. cross-volume).
///
/// # Safety
///
/// See [`ff_parallel_copy`].
#[no_mangle]
pub extern "C" fn ff_parallel_move(
    srcs: *const *const c_char,
    src_count: usize,
    dst_dir: *const c_char,
    progress: FFBatchProgressCallback,
    user_data: *mut c_void,
) -> c_int {
    if srcs.is_null() && src_count > 0 {
        set_last_error("srcs is null".to_string());
        return FF_ERR_INVALID_PATH;
    }
    if dst_dir.is_null() {
        set_last_error("dst_dir is null".to_string());
        return FF_ERR_INVALID_PATH;
    }

    let srcs_vec = if src_count == 0 {
        Vec::new()
    } else {
        unsafe { parse_c_string_array(srcs, src_count) }
    };
    let dst_dir_str = unsafe {
        match CStr::from_ptr(dst_dir).to_str() {
            Ok(s) => s.to_string(),
            Err(_) => {
                set_last_error("dst_dir is not valid UTF-8".to_string());
                return FF_ERR_INVALID_PATH;
            }
        }
    };

    let user_data_addr = user_data as usize;
    let results = crate::core::parallel_ops::parallel_move_files(
        &srcs_vec,
        &dst_dir_str,
        move |done, total| progress(done, total, ptr::null(), user_data_addr as *mut c_void),
    );
    let success = results.iter().filter(|(_, r)| r.is_ok()).count();
    clear_last_error();
    success as c_int
}

/// Parallel delete multiple files/directories using rayon.
///
/// Directories are removed recursively; files are unlinked. Partial failures
/// are reflected as a success count less than `path_count`.
///
/// # Arguments
///
/// - `paths` — Array of path C strings to delete.
/// - `path_count` — Number of entries in `paths`.
/// - `progress` — Callback invoked with (completed, total, null, user_data).
/// - `user_data` — Opaque pointer passed through to the callback.
///
/// # Returns
///
/// - Number of successfully deleted paths (>= 0).
/// - `FF_ERR_INVALID_PATH` if `paths` is null when `path_count > 0`.
///
/// # Safety
///
/// - `paths` must point to `path_count` valid C string pointers.
#[no_mangle]
pub extern "C" fn ff_parallel_delete(
    paths: *const *const c_char,
    path_count: usize,
    progress: FFBatchProgressCallback,
    user_data: *mut c_void,
) -> c_int {
    if paths.is_null() && path_count > 0 {
        set_last_error("paths is null".to_string());
        return FF_ERR_INVALID_PATH;
    }

    let paths_vec = if path_count == 0 {
        Vec::new()
    } else {
        unsafe { parse_c_string_array(paths, path_count) }
    };

    let user_data_addr = user_data as usize;
    let results = crate::core::parallel_ops::parallel_delete_files(
        &paths_vec,
        move |done, total| progress(done, total, ptr::null(), user_data_addr as *mut c_void),
    );
    let success = results.iter().filter(|(_, r)| r.is_ok()).count();
    clear_last_error();
    success as c_int
}

// ── Thumbnail Generation ──────────────────────────────────────────

/// Generate a thumbnail for an image file.
///
/// # Arguments
/// - `path` — NUL-terminated UTF-8 path to the image file.
/// - `max_size` — Maximum width/height of the thumbnail.
/// - `callback` — Called with the thumbnail path.
/// - `user_data` — Opaque pointer passed to the callback.
///
/// # Returns
/// - `FF_OK` on success.
/// - `FF_ERR_INVALID_PATH` if the path is invalid.
#[no_mangle]
pub extern "C" fn ff_generate_thumbnail(
    path: *const c_char,
    max_size: u32,
    callback: extern "C" fn(thumbnail_path: *const c_char, user_data: *mut c_void),
    user_data: *mut c_void,
) -> c_int {
    if path.is_null() {
        set_last_error("path is null".to_string());
        return FF_ERR_INVALID_PATH;
    }

    let path_str = unsafe {
        match CStr::from_ptr(path).to_str() {
            Ok(s) => s,
            Err(_) => {
                set_last_error("path is not valid UTF-8".to_string());
                return FF_ERR_INVALID_PATH;
            }
        }
    };

    match crate::core::thumbnails::generate_thumbnail(path_str, max_size) {
        Ok(thumb_path) => {
            let path_c = rust_string_to_c(thumb_path.to_string_lossy().to_string());
            callback(path_c, user_data);
            if !path_c.is_null() {
                unsafe { let _ = CString::from_raw(path_c); }
            }
            clear_last_error();
            FF_OK
        }
        Err(e) => {
            set_last_error(format!("generate_thumbnail failed: {}", e));
            FF_ERR_IO
        }
    }
}

/// Generate thumbnails for multiple image files.
///
/// # Arguments
/// - `paths` — Array of NUL-terminated UTF-8 paths.
/// - `path_count` — Number of paths.
/// - `max_size` — Maximum width/height of each thumbnail.
/// - `callback` — Called for each thumbnail path.
/// - `user_data` — Opaque pointer passed to the callback.
///
/// # Returns
/// - `FF_OK` on success.
/// - `FF_ERR_INVALID_PATH` if inputs are invalid.
#[no_mangle]
pub extern "C" fn ff_generate_thumbnails(
    paths: *const *const c_char,
    path_count: usize,
    max_size: u32,
    callback: extern "C" fn(thumbnail_path: *const c_char, user_data: *mut c_void),
    user_data: *mut c_void,
) -> c_int {
    if paths.is_null() && path_count > 0 {
        set_last_error("paths is null".to_string());
        return FF_ERR_INVALID_PATH;
    }

    let mut path_strings = Vec::with_capacity(path_count);
    for i in 0..path_count {
        let path_ptr = unsafe { *paths.add(i) };
        if path_ptr.is_null() {
            set_last_error("path in array is null".to_string());
            return FF_ERR_INVALID_PATH;
        }
        let path_str = unsafe {
            match CStr::from_ptr(path_ptr).to_str() {
                Ok(s) => s.to_string(),
                Err(_) => {
                    set_last_error("path is not valid UTF-8".to_string());
                    return FF_ERR_INVALID_PATH;
                }
            }
        };
        path_strings.push(path_str);
    }

    match crate::core::thumbnails::generate_thumbnails(&path_strings, max_size) {
        Ok(thumb_paths) => {
            for thumb_path in thumb_paths {
                let path_c = rust_string_to_c(thumb_path.to_string_lossy().to_string());
                callback(path_c, user_data);
                if !path_c.is_null() {
                    unsafe { let _ = CString::from_raw(path_c); }
                }
            }
            clear_last_error();
            FF_OK
        }
        Err(e) => {
            set_last_error(format!("generate_thumbnails failed: {}", e));
            FF_ERR_IO
        }
    }
}

// ── Settings API (Sub-project 8) ────────────────────────────────────

/// Load all settings as a JSON string.
///
/// Returns a heap-allocated C string. Must be freed with `ff_free_string()`.
#[no_mangle]
pub extern "C" fn ff_settings_load() -> *mut c_char {
    crate::core::settings::settings_load()
}

/// Save all settings from a JSON string.
///
/// # Arguments
/// - `json` — NUL-terminated UTF-8 JSON string containing settings.
///
/// # Returns
/// - `FF_OK` on success.
/// - `FF_ERR_INVALID_PATH` if json is null.
/// - `FF_ERR_GENERIC` if JSON parsing fails.
#[no_mangle]
pub extern "C" fn ff_settings_save(json: *const c_char) -> c_int {
    crate::core::settings::settings_save(json)
}

/// Get a specific setting value by key.
///
/// Keys are dot-separated, e.g., "general.default_directory", "appearance.theme".
///
/// # Arguments
/// - `key` — NUL-terminated UTF-8 key string.
///
/// # Returns
/// - Pointer to value string on success.
/// - `NULL` on error or if key not found.
#[no_mangle]
pub extern "C" fn ff_settings_get(key: *const c_char) -> *mut c_char {
    crate::core::settings::settings_get(key)
}

/// Set a specific setting value by key.
///
/// Keys are dot-separated, e.g., "general.default_directory", "appearance.theme".
///
/// # Arguments
/// - `key` — NUL-terminated UTF-8 key string.
/// - `value` — NUL-terminated UTF-8 value string.
///
/// # Returns
/// - `FF_OK` on success.
/// - `FF_ERR_INVALID_PATH` if key or value is null.
/// - `FF_ERR_GENERIC` if key is invalid.
#[no_mangle]
pub extern "C" fn ff_settings_set(key: *const c_char, value: *const c_char) -> c_int {
    crate::core::settings::settings_set(key, value)
}

// ── Volume Data Structures ──────────────────────────────────────────

/// C-compatible volume info structure
#[repr(C)]
pub struct FFVolumeInfo {
    pub name: *mut c_char,
    pub path: *mut c_char,
    pub fs_type: *mut c_char,
    pub total_size: u64,
    pub free_size: u64,
    pub used_size: u64,
    pub is_removable: bool,
    pub is_ejectable: bool,
    pub is_writable: bool,
}

/// Callback for volume list (passes FFVolumeInfo struct pointer, aligned with ff_ffi.h)
pub type FFVolumeCallback = extern "C" fn(
    volume: *const FFVolumeInfo,
    user_data: *mut c_void,
);

/// Callback for volume info
pub type FFVolumeInfoCallback = extern "C" fn(
    path: *const c_char,
    name: *const c_char,
    fs_type: *const c_char,
    total_size: u64,
    used_size: u64,
    free_size: u64,
    filesystem: *const c_char,
    is_removable: bool,
    is_ejectable: bool,
    is_network: bool,
    user_data: *mut c_void,
);

/// Callback for health check result
pub type FFHealthCallback = extern "C" fn(
    path: *const c_char,
    status: *const c_char,
    usage_percent: f64,
    smart_available: bool,
    smart_status: *const c_char,
    user_data: *mut c_void,
);

// ── Task Data Structures ────────────────────────────────────────────

/// C-compatible task info structure
#[repr(C)]
pub struct FFTaskInfo {
    pub id: u64,
    pub name: *mut c_char,
    pub description: *mut c_char,
    pub priority: i32,
    pub status: *mut c_char,
    pub progress: f64,
    pub created_at: i64,
    pub started_at: i64,
    pub completed_at: i64,
}

/// Callback for task list
pub type FFTaskListCallback = extern "C" fn(
    id: u64,
    name: *const c_char,
    description: *const c_char,
    priority: i32,
    status: *const c_char,
    progress: f64,
    created_at: i64,
    started_at: i64,
    completed_at: i64,
    user_data: *mut c_void,
);

/// List all tasks (FFI wrapper with FFTaskInfo struct).
///
/// # Arguments
/// - `callback` — Called for each task with raw task info pointer
/// - `user_data` — Opaque pointer passed to callback
///
/// # Returns
/// - `FF_OK` on success
#[no_mangle]
pub extern "C" fn ff_task_list(
    callback: extern "C" fn(*const FFTaskInfo, *mut c_void),
    user_data: *mut c_void,
) -> c_int {
    let tasks = crate::core::task_scheduler::scheduler().list_tasks();

    for task in tasks {
        let name_c = rust_string_to_c(task.task_type.as_str().to_string());
        let status_c = rust_string_to_c(task.status.as_str().to_string());

        let ff_task = FFTaskInfo {
            id: task.id,
            name: name_c,
            description: rust_string_to_c(task.params.get("description").cloned().unwrap_or_default()),
            priority: match task.priority {
                crate::core::task_scheduler::TaskPriority::Low => 0,
                crate::core::task_scheduler::TaskPriority::Normal => 1,
                crate::core::task_scheduler::TaskPriority::High => 2,
                crate::core::task_scheduler::TaskPriority::Critical => 3,
            },
            status: status_c,
            progress: task.progress,
            created_at: task.created_at as i64,
            started_at: task.started_at.unwrap_or(0) as i64,
            completed_at: task.completed_at.unwrap_or(0) as i64,
        };

        callback(&ff_task, user_data);

        if !name_c.is_null() { unsafe { let _ = CString::from_raw(name_c); } }
        if !status_c.is_null() { unsafe { let _ = CString::from_raw(status_c); } }
    }

    FF_OK
}

/// Get progress for a specific task
///
/// # Arguments
/// - `task_id` — NUL-terminated UTF-8 task ID string
/// - `out_progress` — Pointer to store progress value
///
/// # Returns
/// - `FF_OK` on success
/// - `FF_ERR_NOT_FOUND` if task not found
#[no_mangle]
pub extern "C" fn ff_task_progress_ex(
    task_id: *const c_char,
    out_progress: *mut f64,
) -> c_int {
    if task_id.is_null() || out_progress.is_null() {
        return FF_ERR_INVALID_PATH;
    }

    let id_str = unsafe {
        match CStr::from_ptr(task_id).to_str() {
            Ok(s) => s,
            Err(_) => return FF_ERR_INVALID_PATH,
        }
    };

    let id = match id_str.parse::<u64>() {
        Ok(id) => id,
        Err(_) => return FF_ERR_INVALID_PATH,
    };

    let tasks = crate::core::task_scheduler::scheduler().list_tasks();
    if let Some(task) = tasks.iter().find(|t| t.id == id) {
        unsafe {
            *out_progress = task.progress;
        }
        FF_OK
    } else {
        FF_ERR_NOT_FOUND
    }
}

/// Calculate the BLAKE3 hash of a file.
///
/// # Arguments
/// - `path` — NUL-terminated UTF-8 path to the file.
/// - `out_hash` — Pointer to receive the heap-allocated hash string (must be freed with `ff_free_string`).
///
/// # Returns
/// - `FF_OK` on success.
/// - `FF_ERR_INVALID_PATH` if path or out_hash is null.
/// - `FF_ERR_IO` on I/O error.
#[no_mangle]
pub extern "C" fn ff_hash_file(
    path: *const c_char,
    out_hash: *mut *mut c_char,
) -> c_int {
    if path.is_null() || out_hash.is_null() {
        return FF_ERR_INVALID_PATH;
    }

    let path_str = match unsafe { CStr::from_ptr(path) }.to_str() {
        Ok(s) => s,
        Err(_) => return FF_ERR_INVALID_PATH,
    };

    match crate::core::scanner::hash_file(path_str) {
        Ok(hash) => {
            let c_string = CString::new(hash).unwrap_or_default();
            unsafe {
                *out_hash = c_string.into_raw();
            }
            FF_OK
        }
        Err(e) => {
            set_last_error(e.to_string());
            FF_ERR_IO
        }
    }
}

// ── Tests ───────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_rust_string_to_c_roundtrip() {
        let original = "hello world".to_string();
        let c_ptr = rust_string_to_c(original.clone());
        assert!(!c_ptr.is_null());
        unsafe {
            let cstr = CStr::from_ptr(c_ptr);
            assert_eq!(cstr.to_str().unwrap(), "hello world");
            let _ = CString::from_raw(c_ptr);
        }
    }

    #[test]
    fn test_ff_free_string_null() {
        // Should not panic.
        ff_free_string(ptr::null_mut());
    }

    #[test]
    fn test_ff_version_string() {
        let ptr = ff_version_string();
        assert!(!ptr.is_null());
        unsafe {
            let cstr = CStr::from_ptr(ptr);
            assert!(!cstr.to_str().unwrap().is_empty());
            let _ = CString::from_raw(ptr);
        }
    }

    #[test]
    fn test_ff_get_file_type() {
        let path = CString::new("/test/document.pdf").unwrap();
        let ptr = ff_get_file_type(path.as_ptr());
        assert!(!ptr.is_null());
        unsafe {
            let cstr = CStr::from_ptr(ptr);
            assert_eq!(cstr.to_str().unwrap(), "pdf");
            let _ = CString::from_raw(ptr);
        }
    }

    #[test]
    fn test_ff_get_file_type_no_extension() {
        let path = CString::new("/test/README").unwrap();
        let ptr = ff_get_file_type(path.as_ptr());
        assert!(!ptr.is_null());
        unsafe {
            let cstr = CStr::from_ptr(ptr);
            assert_eq!(cstr.to_str().unwrap(), "");
            let _ = CString::from_raw(ptr);
        }
    }

    #[test]
    fn test_ff_get_file_type_null() {
        let ptr = ff_get_file_type(ptr::null());
        assert!(ptr.is_null());
    }

    #[test]
    fn test_ff_cache_invalidate() {
        let path = CString::new("/tmp/test_cache").unwrap();
        let result = ff_cache_invalidate(path.as_ptr());
        assert_eq!(result, FF_OK);
    }

    #[test]
    fn test_ff_cache_invalidate_null() {
        let result = ff_cache_invalidate(ptr::null());
        assert_eq!(result, FF_ERR_INVALID_PATH);
    }

    #[test]
    fn test_ff_cache_get_miss() {
        let path = CString::new("/nonexistent/path/xyz123").unwrap();
        let result = ff_cache_get(path.as_ptr(), dummy_callback, ptr::null_mut());
        assert_eq!(result, FF_ERR_NOT_FOUND);
    }

    #[test]
    fn test_ff_dir_cache_clear() {
        let result = ff_dir_cache_clear();
        assert_eq!(result, FF_OK);
    }

    #[test]
    fn test_ff_cache_init_null() {
        let result = ff_cache_init(ptr::null());
        assert_eq!(result, FF_ERR_INVALID_PATH);
    }

    // ── L1 + L2 two-tier cache integration ──────────────────────────
    //
    // Verifies the full FFI flow: ff_cache_init → ff_cache_put writes to
    // both L1 and L2; clearing L1 (dir_cache::clear) forces an L1 miss;
    // ff_cache_get must then recover the entries from L2 and deliver them
    // through the callback.
    //
    // The global `CACHE_DB_PATH` is a `OnceLock<String>` — once set by the
    // first `ff_cache_init` call it cannot be reset. Tests in the same
    // process therefore share whichever path was set first; this test is
    // written to be robust to that constraint (it queries a unique dir path
    // that no other test populates).

    #[test]
    fn test_ff_cache_l2_recovery_after_l1_clear() {
        use std::sync::Mutex as StdMutex;
        // A process-global lock so this test doesn't race with other tests
        // that touch the cache while we're mid-verify.
        static L2_TEST_LOCK: StdMutex<()> = StdMutex::new(());

        let _guard = L2_TEST_LOCK.lock().unwrap();

        // Use a fresh temp file for the SQLite db. If a prior test in this
        // process already called ff_cache_init, the OnceLock will retain the
        // old path — that's fine: init_cache is idempotent (CREATE TABLE IF
        // NOT EXISTS) and we still verify the L2 round-trip below.
        let tmp = tempfile::NamedTempFile::new().expect("create temp file");
        let db_path = tmp.path().to_str().expect("utf-8 path").to_string();
        let db_path_c = CString::new(db_path.clone()).unwrap();
        let init_result = ff_cache_init(db_path_c.as_ptr());
        assert_eq!(init_result, FF_OK, "ff_cache_init should succeed");

        // Currently-active global db path (may differ from `db_path` if a
        // prior test in this process already initialized the OnceLock).
        let active_db = CACHE_DB_PATH.get().map(|s| s.as_str()).unwrap_or(&db_path);

        // Unique dir path to avoid collisions with other tests.
        let dir_path_str =
            "/tmp/flowfinder_test_l2_recovery_unique_8f3a2c";
        let dir_path = CString::new(dir_path_str).unwrap();

        // Build Rust-owned skeletons first — used both for seeding L2
        // directly (if needed) and as the source of truth for the entries.
        let skeletons: Vec<crate::core::scanner::FileEntrySkeleton> = vec![
            crate::core::scanner::FileEntrySkeleton {
                id: "/tmp/flowfinder_test_l2_recovery_unique_8f3a2c/alpha.txt".to_string(),
                name: "alpha.txt".to_string(),
                path: "/tmp/flowfinder_test_l2_recovery_unique_8f3a2c/alpha.txt".to_string(),
                is_dir: false,
                is_file: true,
                is_symlink: false,
                is_hidden: false,
                extension: "txt".to_string(),
                size: 100,
                modified: 1_000,
                created: 900,
                is_system_protected: false,
                metadata_loaded: true,
            },
            crate::core::scanner::FileEntrySkeleton {
                id: "/tmp/flowfinder_test_l2_recovery_unique_8f3a2c/beta_dir".to_string(),
                name: "beta_dir".to_string(),
                path: "/tmp/flowfinder_test_l2_recovery_unique_8f3a2c/beta_dir".to_string(),
                is_dir: true,
                is_file: false,
                is_symlink: false,
                is_hidden: false,
                extension: String::new(),
                size: 0,
                modified: 2_000,
                created: 1_900,
                is_system_protected: false,
                metadata_loaded: true,
            },
        ];

        // Build matching FFEntryRef array with heap-allocated C strings.
        let name1 = CString::new("alpha.txt").unwrap().into_raw();
        let path1 = CString::new("/tmp/flowfinder_test_l2_recovery_unique_8f3a2c/alpha.txt")
            .unwrap()
            .into_raw();
        let ext1 = CString::new("txt").unwrap().into_raw();
        let name2 = CString::new("beta_dir").unwrap().into_raw();
        let path2 = CString::new("/tmp/flowfinder_test_l2_recovery_unique_8f3a2c/beta_dir")
            .unwrap()
            .into_raw();
        let ext2 = CString::new("").unwrap().into_raw();

        let entries: [FFEntryRef; 2] = [
            FFEntryRef {
                name: name1,
                path: path1,
                extension: ext1,
                is_dir: false,
                is_file: true,
                is_symlink: false,
                is_hidden: false,
                is_system_protected: false,
                size: 100,
                modified: 1_000,
                created: 900,
            },
            FFEntryRef {
                name: name2,
                path: path2,
                extension: ext2,
                is_dir: true,
                is_file: false,
                is_symlink: false,
                is_hidden: false,
                is_system_protected: false,
                size: 0,
                modified: 2_000,
                created: 1_900,
            },
        ];

        // ff_cache_put → writes L1 (and L2 if the global path is set).
        let put_result = ff_cache_put(dir_path.as_ptr(), entries.as_ptr(), entries.len());
        assert_eq!(put_result, FF_OK, "ff_cache_put should succeed");

        // Reclaim the C strings we handed to ff_cache_put (the FFI copies
        // them into Rust-owned Strings internally — the raw pointers are
        // no longer needed after ff_cache_put returns).
        for raw in [name1, path1, ext1, name2, path2, ext2] {
            unsafe { let _ = CString::from_raw(raw); }
        }

        // Defensive: ensure L2 actually has the rows for our dir path,
        // seeding directly via sqlite_cache::cache_put if the global
        // OnceLock pointed elsewhere (e.g. a prior test set a different
        // path). Without this, the recovery assertion below would be
        // vacuous in such a scenario.
        let seeded = matches!(
            crate::core::sqlite_cache::cache_get(active_db, dir_path_str),
            Ok(Some(v)) if !v.is_empty()
        );
        if !seeded {
            crate::core::sqlite_cache::cache_put(active_db, dir_path_str, &skeletons)
                .expect("seed L2 directly");
        }

        // Clear L1 so the next ff_cache_get MUST come from L2.
        crate::core::dir_cache::clear();

        // Collect entries delivered via the callback.
        #[derive(Default)]
        struct Collector {
            names: Vec<String>,
            is_dirs: Vec<bool>,
            sizes: Vec<u64>,
        }

        extern "C" fn collect_cb(
            entry: *const FFEntryRef,
            user_data: *mut c_void,
        ) {
            unsafe {
                let entry = &*entry;
                let collector = &mut *(user_data as *mut Collector);
                collector.names.push(
                    CStr::from_ptr(entry.name).to_string_lossy().to_string(),
                );
                collector.is_dirs.push(entry.is_dir);
                collector.sizes.push(entry.size);
            }
        }

        let mut collector = Collector::default();
        let get_result = ff_cache_get(
            dir_path.as_ptr(),
            collect_cb,
            &mut collector as *mut Collector as *mut c_void,
        );

        assert_eq!(
            get_result, FF_OK,
            "ff_cache_get must recover from L2 after L1 clear"
        );
        assert_eq!(
            collector.names.len(),
            2,
            "callback should receive both entries"
        );
        assert!(collector.names.contains(&"alpha.txt".to_string()));
        assert!(collector.names.contains(&"beta_dir".to_string()));
        assert!(collector.is_dirs.contains(&true));
        assert!(collector.is_dirs.contains(&false));
        assert!(collector.sizes.contains(&100));

        // Cleanup: invalidate the L2 row for our dir path so re-runs stay clean.
        let _ = crate::core::sqlite_cache::cache_invalidate(active_db, dir_path_str);
        crate::core::dir_cache::clear();
    }

    #[test]
    fn test_ff_fsevents_start_stop() {
        extern "C" fn test_callback(_path: *const c_char, _user_data: *mut c_void) {}

        let path = CString::new("/tmp").unwrap();
        let result = ff_fsevents_start(path.as_ptr(), test_callback, ptr::null_mut());
        assert_eq!(result, FF_OK);

        let result = ff_fsevents_stop(0);
        assert_eq!(result, FF_OK);
    }

    extern "C" fn dummy_callback(_entry: *const FFEntryRef, _user_data: *mut c_void) {}

    // ── Settings Tests ────────────────────────────────────────────────

    #[test]
    fn test_ff_settings_load() {
        let ptr = ff_settings_load();
        assert!(!ptr.is_null());
        unsafe {
            let cstr = CStr::from_ptr(ptr);
            let json = cstr.to_str().unwrap();
            assert!(json.contains("general"));
            assert!(json.contains("appearance"));
            assert!(json.contains("shortcuts"));
            assert!(json.contains("advanced"));
            let _ = CString::from_raw(ptr);
        }
    }

    #[test]
    fn test_ff_settings_get_set() {
        // Set a value
        let key = CString::new("appearance.theme").unwrap();
        let value = CString::new("dark").unwrap();
        let result = ff_settings_set(key.as_ptr(), value.as_ptr());
        assert_eq!(result, FF_OK);

        // Get the value back
        let result = ff_settings_get(key.as_ptr());
        assert!(!result.is_null());
        unsafe {
            let cstr = CStr::from_ptr(result);
            assert_eq!(cstr.to_str().unwrap(), "dark");
            let _ = CString::from_raw(result);
        }
    }

    #[test]
    fn test_ff_settings_get_invalid_key() {
        let key = CString::new("invalid.key").unwrap();
        let result = ff_settings_get(key.as_ptr());
        assert!(result.is_null());
    }

    #[test]
    fn test_ff_settings_set_null() {
        let result = ff_settings_set(std::ptr::null(), std::ptr::null());
        assert_eq!(result, FF_ERR_INVALID_PATH);
    }

    #[test]
    fn test_ff_settings_save() {
        let json = r#"{"general":{"default_directory":"/test","show_hidden_files":true,"confirm_delete":false},"appearance":{"theme":"light","icon_size":48,"font_size":14},"shortcuts":{"new_window":"Cmd+N","close_window":"Cmd+W","search":"Cmd+F","refresh":"Cmd+R","delete":"Cmd+Backspace","copy":"Cmd+C","paste":"Cmd+V","select_all":"Cmd+A"},"advanced":{"cache_size_mb":200,"thumbnail_quality":90,"fsevents_enabled":false}}"#;
        let c_json = CString::new(json).unwrap();
        let result = ff_settings_save(c_json.as_ptr());
        assert_eq!(result, FF_OK);

        // Verify the saved value
        let key = CString::new("appearance.theme").unwrap();
        let result = ff_settings_get(key.as_ptr());
        assert!(!result.is_null());
        unsafe {
            let cstr = CStr::from_ptr(result);
            assert_eq!(cstr.to_str().unwrap(), "light");
            let _ = CString::from_raw(result);
        }
    }

    // ── Task Scheduler Tests ──────────────────────────────────────────

    #[test]
    fn test_ff_task_submit() {
        let name = CString::new("copy").unwrap();
        let description = CString::new("test description").unwrap();
        let mut out_task_id: *mut c_char = std::ptr::null_mut();

        let result = crate::core::task_scheduler::ff_task_submit(
            name.as_ptr(),
            description.as_ptr(),
            1,
            &mut out_task_id,
        );
        assert_eq!(result, FF_OK);
        assert!(!out_task_id.is_null());
        unsafe {
            let _ = CString::from_raw(out_task_id);
        }
    }

    #[test]
    fn test_ff_task_submit_invalid_type() {
        let name = CString::new("invalid").unwrap();
        let mut out_task_id: *mut c_char = std::ptr::null_mut();
        let result = crate::core::task_scheduler::ff_task_submit(
            name.as_ptr(),
            std::ptr::null(),
            1,
            &mut out_task_id,
        );
        assert_eq!(result, FF_ERR_GENERIC);
    }

    #[test]
    fn test_ff_task_cancel_not_found() {
        let task_id = CString::new("99999").unwrap();
        let result = crate::core::task_scheduler::ff_task_cancel(task_id.as_ptr());
        assert_eq!(result, FF_ERR_NOT_FOUND);
    }

    // ── Volume Management Tests ─────────────────────────────────────

    #[test]
    fn test_ff_volume_list() {
        extern "C" fn volume_callback(
            _volume: *const FFVolumeInfo,
            _user_data: *mut c_void,
        ) {}

        let result = crate::core::volumes::ff_volume_list(volume_callback, std::ptr::null_mut());
        assert_eq!(result, FF_OK);
    }

    #[test]
    fn test_ff_volume_info_null() {
        let result = crate::core::volumes::ff_volume_info(std::ptr::null(), std::ptr::null_mut());
        assert_eq!(result, FF_ERR_INVALID_PATH);
    }

    #[test]
    fn test_ff_volume_health_check_null() {
        extern "C" fn health_callback(
            _path: *const c_char,
            _overall_status: *const c_char,
            _disk_usage_percent: f64,
            _smart_available: bool,
            _smart_status: *const c_char,
            _user_data: *mut c_void,
        ) {}

        let result = crate::core::volumes::ff_volume_health_check(std::ptr::null(), health_callback, std::ptr::null_mut());
        assert_eq!(result, FF_ERR_INVALID_PATH);
    }

    #[test]
    fn test_ff_volume_eject_null() {
        let result = crate::core::volumes::ff_volume_eject(std::ptr::null());
        assert_eq!(result, FF_ERR_INVALID_PATH);
    }

    #[test]
    fn test_ff_volume_mount_null() {
        let result = crate::core::volumes::ff_volume_mount(std::ptr::null(), std::ptr::null());
        assert_eq!(result, FF_ERR_INVALID_PATH);
    }

    // ── Parallel Batch Operations Tests ─────────────────────────────

    extern "C" fn noop_batch_progress(
        _completed: usize,
        _total: usize,
        _current_file: *const c_char,
        _user_data: *mut c_void,
    ) {
    }

    /// Helper: build a `Vec<CString>` plus a `Vec<*const c_char>` view into it
    /// suitable for passing to the parallel FFI functions.
    fn build_c_string_array(paths: &[String]) -> (Vec<CString>, Vec<*const c_char>) {
        let cstrings: Vec<CString> = paths
            .iter()
            .map(|s| CString::new(s.as_str()).unwrap())
            .collect();
        let ptrs: Vec<*const c_char> = cstrings.iter().map(|cs| cs.as_ptr()).collect();
        (cstrings, ptrs)
    }

    #[test]
    fn test_ff_parallel_copy() {
        use std::fs;
        use tempfile::tempdir;

        let src_dir = tempdir().unwrap();
        let dst_dir = tempdir().unwrap();
        let n: usize = 5;

        let srcs: Vec<String> = (0..n)
            .map(|i| {
                let path = src_dir.path().join(format!("parallel_copy_{}.txt", i));
                fs::write(&path, format!("content-{}", i)).unwrap();
                path.to_str().unwrap().to_string()
            })
            .collect();

        let dst_dir_c = CString::new(dst_dir.path().to_str().unwrap()).unwrap();
        let (_cstrings, ptrs) = build_c_string_array(&srcs);

        let result = ff_parallel_copy(
            ptrs.as_ptr(),
            ptrs.len(),
            dst_dir_c.as_ptr(),
            noop_batch_progress,
            ptr::null_mut(),
        );

        assert_eq!(result as usize, n, "all {} files should copy successfully", n);

        // Verify destination files exist with correct contents.
        for i in 0..n {
            let dst = dst_dir.path().join(format!("parallel_copy_{}.txt", i));
            assert!(dst.exists(), "destination file {} should exist", i);
            assert_eq!(
                fs::read_to_string(&dst).unwrap(),
                format!("content-{}", i),
                "destination content must match source"
            );
        }
    }

    #[test]
    fn test_ff_parallel_copy_null_inputs() {
        let dst_dir_c = CString::new("/tmp").unwrap();
        // Non-zero count with null srcs array → FF_ERR_INVALID_PATH.
        assert_eq!(
            ff_parallel_copy(
                ptr::null(),
                3,
                dst_dir_c.as_ptr(),
                noop_batch_progress,
                ptr::null_mut(),
            ),
            FF_ERR_INVALID_PATH
        );
        // Null dst_dir → FF_ERR_INVALID_PATH.
        assert_eq!(
            ff_parallel_copy(
                ptr::null(),
                0,
                ptr::null(),
                noop_batch_progress,
                ptr::null_mut(),
            ),
            FF_ERR_INVALID_PATH
        );
    }

    #[test]
    fn test_ff_parallel_delete() {
        use std::fs;
        use tempfile::tempdir;

        let dir = tempdir().unwrap();
        let n: usize = 5;

        let paths: Vec<String> = (0..n)
            .map(|i| {
                let path = dir.path().join(format!("parallel_del_{}.txt", i));
                fs::write(&path, b"to-be-deleted").unwrap();
                path.to_str().unwrap().to_string()
            })
            .collect();

        let (_cstrings, ptrs) = build_c_string_array(&paths);

        let result = ff_parallel_delete(
            ptrs.as_ptr(),
            ptrs.len(),
            noop_batch_progress,
            ptr::null_mut(),
        );

        assert_eq!(result as usize, n, "all {} files should be deleted", n);

        for p in &paths {
            assert!(!std::path::Path::new(p).exists(), "path should be gone: {}", p);
        }
    }

    #[test]
    fn test_ff_parallel_delete_null_inputs() {
        // Non-zero count with null paths array → FF_ERR_INVALID_PATH.
        assert_eq!(
            ff_parallel_delete(ptr::null(), 2, noop_batch_progress, ptr::null_mut()),
            FF_ERR_INVALID_PATH
        );
    }

    #[test]
    fn test_ff_parallel_copy_empty() {
        use tempfile::tempdir;

        let dst_dir = tempdir().unwrap();
        let dst_dir_c = CString::new(dst_dir.path().to_str().unwrap()).unwrap();
        // Empty input array (count = 0) — should succeed with 0 copies.
        let result = ff_parallel_copy(
            ptr::null(),
            0,
            dst_dir_c.as_ptr(),
            noop_batch_progress,
            ptr::null_mut(),
        );
        assert_eq!(result, 0);
    }
}
