import Foundation

// MARK: - C Type Imports (from ff_ffi.h)

/// C-compatible task info structure
public struct FFTaskInfo {
    public var id: UnsafeMutablePointer<CChar>?
    public var name: UnsafeMutablePointer<CChar>?
    public var description: UnsafeMutablePointer<CChar>?
    public var priority: Int32
    public var status: Int32
    public var progress: Double
    public var created_at: Int64
    public var started_at: Int64
    public var completed_at: Int64
}

/// C-compatible volume info structure
public struct FFVolumeInfo {
    public var name: UnsafeMutablePointer<CChar>?
    public var path: UnsafeMutablePointer<CChar>?
    public var fs_type: UnsafeMutablePointer<CChar>?
    public var total_size: UInt64
    public var free_size: UInt64
    public var used_size: UInt64
    public var is_removable: Bool
    public var is_ejectable: Bool
    public var is_writable: Bool
}

/// FFI entry reference structure, corresponding to Rust's ff_entry_t
public struct FFEntryRef {
    public let path: UnsafePointer<CChar>
    public let name: UnsafePointer<CChar>
    public let isDir: Bool
    public let size: UInt64
    public let modified: UInt64
}

// MARK: - Duplicate Scan Types

/// C-compatible duplicate file info
public struct FFDuplicateFile {
    public let id: String
    public let path: String
    public let name: String
    public let size: UInt64
    public let modified: Int64
}

/// C-compatible duplicate group info
public struct FFDuplicateGroup {
    public let id: String
    public let hash: String
    public let size: UInt64
    public let files: [FFDuplicateFile]
}

// MARK: - Search Types

/// C-compatible search result
public struct FFSearchResult {
    public let path: String
    public let name: String
    public let size: UInt64
    public let modified: Int64
    public let isDir: Bool
}

/// Search filter criteria
public struct FFSearchFilters {
    public var fileTypes: String?
    public var minSize: UInt64?
    public var maxSize: UInt64?
    public var modifiedAfter: Int64?
    public var modifiedBefore: Int64?

    public init(
        fileTypes: String? = nil,
        minSize: UInt64? = nil,
        maxSize: UInt64? = nil,
        modifiedAfter: Int64? = nil,
        modifiedBefore: Int64? = nil
    ) {
        self.fileTypes = fileTypes
        self.minSize = minSize
        self.maxSize = maxSize
        self.modifiedAfter = modifiedAfter
        self.modifiedBefore = modifiedBefore
    }
}

// MARK: - FFI Function Declarations

/// List contents of a directory
/// - Parameters:
///   - path: Target directory path (C string)
///   - callback: Callback function called for each discovered entry
///   - userData: User data pointer passed to the callback
/// - Returns: 0 on success, non-zero error code on failure
@_silgen_name("ff_list_dir")
public func ff_list_dir(
    _ path: UnsafePointer<CChar>,
    _ callback: @convention(c) (UnsafeRawPointer?, UnsafeMutableRawPointer?) -> Void,
    _ userData: UnsafeMutableRawPointer?
) -> Int32

/// Get the last error message
/// - Returns: Pointer to error description C string (caller must free with ff_free_string)
@_silgen_name("ff_last_error")
public func ff_last_error() -> UnsafePointer<CChar>?

/// Free a string allocated by the Rust side
/// - Parameter string: C string pointer to free
@_silgen_name("ff_free_string")
public func ff_free_string(_ string: UnsafeMutablePointer<CChar>?)

// MARK: - File Operations FFI Declarations

/// Copy a file from src to dst
/// - Parameters:
///   - src: Source file path (C string)
///   - dst: Destination file path (C string)
/// - Returns: 0 on success, non-zero error code on failure
@_silgen_name("ff_copy_file")
public func ff_copy_file(
    _ src: UnsafePointer<CChar>,
    _ dst: UnsafePointer<CChar>
) -> Int32

/// Move a file or directory from src to dst
/// - Parameters:
///   - src: Source path (C string)
///   - dst: Destination path (C string)
/// - Returns: 0 on success, non-zero error code on failure
@_silgen_name("ff_move_file")
public func ff_move_file(
    _ src: UnsafePointer<CChar>,
    _ dst: UnsafePointer<CChar>
) -> Int32

/// Delete a file at path
/// - Parameter path: File path to delete (C string)
/// - Returns: 0 on success, non-zero error code on failure
@_silgen_name("ff_delete_file")
public func ff_delete_file(_ path: UnsafePointer<CChar>) -> Int32

/// Delete a directory and all its contents at path
/// - Parameter path: Directory path to delete (C string)
/// - Returns: 0 on success, non-zero error code on failure
@_silgen_name("ff_delete_dir")
public func ff_delete_dir(_ path: UnsafePointer<CChar>) -> Int32

/// Create a directory and all parent directories at path
/// - Parameter path: Directory path to create (C string)
/// - Returns: 0 on success, non-zero error code on failure
@_silgen_name("ff_create_dir")
public func ff_create_dir(_ path: UnsafePointer<CChar>) -> Int32

/// Rename a file or directory from src to dst
/// - Parameters:
///   - src: Source path (C string)
///   - dst: Destination path (C string)
/// - Returns: 0 on success, non-zero error code on failure
@_silgen_name("ff_rename")
public func ff_rename(
    _ src: UnsafePointer<CChar>,
    _ dst: UnsafePointer<CChar>
) -> Int32

// MARK: - Duplicate File Detection FFI Declarations

/// Scan for duplicate files under a path
/// - Parameters:
///   - path: Root directory path (C string)
///   - progressCallback: Called with (scanned, total) progress updates
///   - groupCallback: Called for each duplicate group found
///   - userData: User data pointer passed to callbacks
/// - Returns: 0 on success, non-zero error code on failure
@_silgen_name("ff_scan_duplicates")
public func ff_scan_duplicates(
    _ path: UnsafePointer<CChar>,
    _ progressCallback: @convention(c) (Int, Int, UnsafeMutableRawPointer?) -> Void,
    _ groupCallback: @convention(c) (UnsafeRawPointer?, UnsafeMutableRawPointer?) -> Void,
    _ userData: UnsafeMutableRawPointer?
) -> Int32

/// Cancel an ongoing duplicate scan
@_silgen_name("ff_cancel_scan")
public func ff_cancel_scan()

// MARK: - File Search FFI Declarations

/// Search for files matching query under path
/// - Parameters:
///   - path: Root directory path (C string)
///   - query: Search query (C string)
///   - callback: Called for each matching result
///   - userData: User data pointer passed to callback
/// - Returns: 0 on success, non-zero error code on failure
@_silgen_name("ff_search")
public func ff_search(
    _ path: UnsafePointer<CChar>,
    _ query: UnsafePointer<CChar>,
    _ callback: @convention(c) (UnsafeRawPointer?, UnsafeMutableRawPointer?) -> Void,
    _ userData: UnsafeMutableRawPointer?
) -> Int32

/// Search for files with advanced filters
/// - Parameters:
///   - path: Root directory path (C string)
///   - query: Search query (C string)
///   - filters: Pointer to filter criteria struct
///   - callback: Called for each matching result
///   - userData: User data pointer passed to callback
/// - Returns: 0 on success, non-zero error code on failure
@_silgen_name("ff_search_with_filters")
public func ff_search_with_filters(
    _ path: UnsafePointer<CChar>,
    _ query: UnsafePointer<CChar>,
    _ filters: UnsafeRawPointer?,
    _ callback: @convention(c) (UnsafeRawPointer?, UnsafeMutableRawPointer?) -> Void,
    _ userData: UnsafeMutableRawPointer?
) -> Int32

// MARK: - QuickLook Preview FFI Declarations

/// Get a preview-friendly path for a file
/// - Parameters:
///   - path: File path (C string)
///   - callback: Called with the preview path
///   - userData: User data pointer passed to callback
/// - Returns: 0 on success, non-zero error code on failure
@_silgen_name("ff_get_preview_path")
public func ff_get_preview_path(
    _ path: UnsafePointer<CChar>,
    _ callback: @convention(c) (UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Void,
    _ userData: UnsafeMutableRawPointer?
) -> Int32

/// Get the file type/extension as a C string
/// - Parameter path: File path (C string)
/// - Returns: Pointer to file extension string (caller must free with ff_free_string)
@_silgen_name("ff_get_file_type")
public func ff_get_file_type(_ path: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>?

// MARK: - Directory Cache FFI Declarations

/// Invalidate the directory cache for a specific path
/// - Parameter path: Directory path (C string)
/// - Returns: 0 on success, non-zero error code on failure
@_silgen_name("ff_cache_invalidate")
public func ff_cache_invalidate(_ path: UnsafePointer<CChar>) -> Int32

/// Get cached directory entries for a path
/// - Parameters:
///   - path: Directory path (C string)
///   - callback: Called for each cached entry
///   - userData: User data pointer passed to callback
/// - Returns: 0 on success, non-zero error code on failure
@_silgen_name("ff_cache_get")
public func ff_cache_get(
    _ path: UnsafePointer<CChar>,
    _ callback: @convention(c) (UnsafeRawPointer?, UnsafeMutableRawPointer?) -> Void,
    _ userData: UnsafeMutableRawPointer?
) -> Int32

/// Store directory entries in the cache
/// - Parameters:
///   - path: Directory path (C string)
///   - entries: Array of FFEntryRef to cache
///   - entryCount: Number of entries in the array
/// - Returns: 0 on success, non-zero error code on failure
@_silgen_name("ff_cache_put")
public func ff_cache_put(
    _ path: UnsafePointer<CChar>,
    _ entries: UnsafePointer<FFEntryRef>,
    _ entryCount: Int
) -> Int32

// MARK: - Directory Cache (Sub-project 5) FFI Declarations

/// Get cached directory entries for a path (alias)
/// - Parameters:
///   - path: Directory path (C string)
///   - callback: Called for each cached entry
///   - userData: User data pointer passed to callback
/// - Returns: 0 on success, non-zero error code on failure
@_silgen_name("ff_dir_cache_get")
public func ff_dir_cache_get(
    _ path: UnsafePointer<CChar>,
    _ callback: @convention(c) (UnsafeRawPointer?, UnsafeMutableRawPointer?) -> Void,
    _ userData: UnsafeMutableRawPointer?
) -> Int32

/// Invalidate the directory cache for a specific path (alias)
/// - Parameter path: Directory path (C string)
/// - Returns: 0 on success, non-zero error code on failure
@_silgen_name("ff_dir_cache_invalidate")
public func ff_dir_cache_invalidate(_ path: UnsafePointer<CChar>) -> Int32

/// Clear all directory cache entries
/// - Returns: 0 on success, non-zero error code on failure
@_silgen_name("ff_dir_cache_clear")
public func ff_dir_cache_clear() -> Int32

// MARK: - FSEvents Watcher (Sub-project 5) FFI Declarations

/// Callback type for FSEvents notifications
public typealias FSEventCallback = @convention(c) (UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Void

/// Start watching a path for filesystem changes
/// - Parameters:
///   - path: Directory path to watch (C string)
///   - callback: Called when a change is detected
///   - userData: User data pointer passed to callback
/// - Returns: 0 on success, non-zero error code on failure
@_silgen_name("ff_fsevents_start")
public func ff_fsevents_start(
    _ path: UnsafePointer<CChar>,
    _ callback: FSEventCallback,
    _ userData: UnsafeMutableRawPointer?
) -> Int32

/// Stop the FSEvents watcher
/// - Parameter handle: Handle returned by ff_fsevents_start
/// - Returns: 0 on success, non-zero error code on failure
@_silgen_name("ff_fsevents_stop")
public func ff_fsevents_stop(_ handle: Int32) -> Int32

// MARK: - Batch Rename & Organize (Sub-project 6) FFI Declarations

/// C-compatible batch rename item
public struct FFRenameItem {
    public var originalPath: UnsafeMutablePointer<CChar>
    public var newName: UnsafeMutablePointer<CChar>
}

/// Batch rename files
/// - Parameters:
///   - items: Array of FFRenameItem
///   - itemCount: Number of items
/// - Returns: Number of successful renames on success (>= 0), negative error code on failure
@_silgen_name("ff_batch_rename")
public func ff_batch_rename(
    _ items: UnsafePointer<FFRenameItem>,
    _ itemCount: Int
) -> Int32

/// Organize files by date into folders
/// - Parameters:
///   - path: Directory path (C string)
///   - format: Date format string (C string, e.g., "YYYY/MM/DD")
/// - Returns: Number of files moved on success (>= 0), negative error code on failure
@_silgen_name("ff_organize_by_date")
public func ff_organize_by_date(
    _ path: UnsafePointer<CChar>,
    _ format: UnsafePointer<CChar>
) -> Int32

/// Organize files by file type into category folders
/// - Parameter path: Directory path (C string)
/// - Returns: Number of files moved on success (>= 0), negative error code on failure
@_silgen_name("ff_organize_by_type")
public func ff_organize_by_type(_ path: UnsafePointer<CChar>) -> Int32

// MARK: - Settings & Configuration (Sub-project 8) FFI Declarations

/// Load settings as a JSON string
/// - Returns: Settings JSON string (caller must free with ff_free_string)
@_silgen_name("ff_settings_load")
public func ff_settings_load() -> UnsafeMutablePointer<CChar>?

/// Save settings from a JSON string
/// - Parameter json: Settings JSON string (C string)
/// - Returns: 0 on success, non-zero error code on failure
@_silgen_name("ff_settings_save")
public func ff_settings_save(_ json: UnsafePointer<CChar>) -> Int32

/// Get a setting value by key
/// - Parameter key: Setting key (C string)
/// - Returns: Setting value string (caller must free with ff_free_string)
@_silgen_name("ff_settings_get")
public func ff_settings_get(_ key: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>?

/// Set a setting value
/// - Parameters:
///   - key: Setting key (C string)
///   - value: Setting value (C string)
/// - Returns: 0 on success, non-zero error code on failure
@_silgen_name("ff_settings_set")
public func ff_settings_set(_ key: UnsafePointer<CChar>, _ value: UnsafePointer<CChar>) -> Int32

// MARK: - Task Scheduler (Sub-project 9) FFI Declarations

/// Submit a new task
/// - Parameters:
///   - taskType: Task type (C string, e.g., "scan", "copy", "delete")
///   - paramsJson: Task parameters as JSON string
/// - Returns: 0 on success, non-zero error code on failure
@_silgen_name("ff_task_submit")
public func ff_task_submit(
    _ taskType: UnsafePointer<CChar>,
    _ paramsJson: UnsafePointer<CChar>
) -> Int32

/// Cancel a task by ID
/// - Parameter taskId: Task ID (integer)
/// - Returns: 0 on success, non-zero error code on failure
@_silgen_name("ff_task_cancel")
public func ff_task_cancel(_ taskId: Int32) -> Int32

/// List all tasks
/// - Parameters:
///   - callback: Called for each task with individual fields
///   - userData: User data pointer passed to callback
/// - Returns: 0 on success, non-zero error code on failure
@_silgen_name("ff_task_list")
public func ff_task_list(
    _ callback: @convention(c) (
        _ id: UInt64,
        _ name: UnsafePointer<CChar>?,
        _ description: UnsafePointer<CChar>?,
        _ priority: Int32,
        _ status: UnsafePointer<CChar>?,
        _ progress: Double,
        _ createdAt: Int64,
        _ startedAt: Int64,
        _ completedAt: Int64,
        _ userData: UnsafeMutableRawPointer?
    ) -> Void,
    _ userData: UnsafeMutableRawPointer?
) -> Int32

/// Get progress for a specific task
/// - Parameters:
///   - taskId: Task ID (integer)
///   - callback: Called with task progress
///   - userData: User data pointer passed to callback
/// - Returns: 0 on success, non-zero error code on failure
@_silgen_name("ff_task_progress")
public func ff_task_progress(
    _ taskId: Int32,
    _ callback: @convention(c) (Int32, Double, UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Void,
    _ userData: UnsafeMutableRawPointer?
) -> Int32

// MARK: - Thumbnail Generation (Sub-project 7) FFI Declarations

/// Generate a thumbnail for an image file
/// - Parameters:
///   - path: Image file path (C string)
///   - maxSize: Maximum width/height of the thumbnail
///   - callback: Called with the thumbnail path
///   - userData: User data pointer passed to callback
/// - Returns: 0 on success, non-zero error code on failure
@_silgen_name("ff_generate_thumbnail")
public func ff_generate_thumbnail(
    _ path: UnsafePointer<CChar>,
    _ maxSize: UInt32,
    _ callback: @convention(c) (UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Void,
    _ userData: UnsafeMutableRawPointer?
) -> Int32

/// Generate thumbnails for multiple image files
/// - Parameters:
///   - paths: Array of image file paths (C strings)
///   - pathCount: Number of paths
///   - maxSize: Maximum width/height of each thumbnail
///   - callback: Called for each thumbnail path
///   - userData: User data pointer passed to callback
/// - Returns: 0 on success, non-zero error code on failure
@_silgen_name("ff_generate_thumbnails")
public func ff_generate_thumbnails(
    _ paths: UnsafePointer<UnsafePointer<CChar>?>,
    _ pathCount: Int,
    _ maxSize: UInt32,
    _ callback: @convention(c) (UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Void,
    _ userData: UnsafeMutableRawPointer?
) -> Int32

// MARK: - Volume Management (Sub-project 10) FFI Declarations

/// List all mounted volumes
/// - Parameters:
///   - callback: Called for each volume with raw volume info pointer
///   - userData: User data pointer passed to callback
/// - Returns: 0 on success, non-zero error code on failure
@_silgen_name("ff_volume_list")
public func ff_volume_list(
    _ callback: @convention(c) (UnsafeRawPointer?, UnsafeMutableRawPointer?) -> Void,
    _ userData: UnsafeMutableRawPointer?
) -> Int32

/// Get detailed information for a specific volume
/// - Parameters:
///   - path: Volume path (C string)
///   - callback: Called with raw volume info pointer
///   - userData: User data pointer passed to callback
/// - Returns: 0 on success, non-zero error code on failure
@_silgen_name("ff_volume_info")
public func ff_volume_info(
    _ path: UnsafePointer<CChar>,
    _ callback: @convention(c) (UnsafeRawPointer?, UnsafeMutableRawPointer?) -> Void,
    _ userData: UnsafeMutableRawPointer?
) -> Int32

/// Perform a health check on a volume
/// - Parameters:
///   - path: Volume path (C string)
///   - callback: Called with health check results
///   - userData: User data pointer passed to callback
/// - Returns: 0 on success, non-zero error code on failure
@_silgen_name("ff_volume_health_check")
public func ff_volume_health_check(
    _ path: UnsafePointer<CChar>,
    _ callback: @convention(c) (UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Void,
    _ userData: UnsafeMutableRawPointer?
) -> Int32

/// Eject a removable volume
/// - Parameter path: Volume path (C string)
/// - Returns: 0 on success, non-zero error code on failure
@_silgen_name("ff_volume_eject")
public func ff_volume_eject(_ path: UnsafePointer<CChar>) -> Int32

/// Mount a network volume
/// - Parameters:
///   - path: Volume path (C string)
///   - options: Mount options (C string, currently unused)
/// - Returns: 0 on success, non-zero error code on failure
@_silgen_name("ff_volume_mount")
public func ff_volume_mount(_ path: UnsafePointer<CChar>, _ options: UnsafePointer<CChar>?) -> Int32
