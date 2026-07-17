import Foundation

/// FFI entry reference structure, corresponding to Rust's ff_entry_t
public struct FFEntryRef {
    public let path: UnsafePointer<CChar>
    public let name: UnsafePointer<CChar>
    public let isDir: Bool
    public let size: UInt64
    public let modified: UInt64
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
