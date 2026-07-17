import Foundation

// MARK: - CoreBridge Error Types

/// Errors that can occur during CoreBridge operations
public enum CoreBridgeError: Error, LocalizedError {
    case ffiError(String)
    case invalidPath(String)
    case unknownError
    case rustCoreNotLoaded
    case stringConversionFailed

    public var errorDescription: String? {
        switch self {
        case .ffiError(let message):
            return "FFI Error: \(message)"
        case .invalidPath(let path):
            return "Invalid path: \(path)"
        case .unknownError:
            return "Unknown error occurred"
        case .rustCoreNotLoaded:
            return "Rust core library not loaded"
        case .stringConversionFailed:
            return "Failed to convert string to C string"
        }
    }
}

// MARK: - Thread-Safe Result Wrapper

/// Thread-safe wrapper for FFI results
private final class ThreadSafeFFIResult<T> {
    private var value: T?
    private let lock = NSLock()

    func set(_ newValue: T) {
        lock.lock()
        defer { lock.unlock() }
        value = newValue
    }

    func get() -> T? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

// MARK: - CoreBridge

/// Thread-safe bridge for communicating with the Rust core via FFI
public final class CoreBridge {

    // MARK: - Singleton

    /// Shared instance of CoreBridge
    public static let shared = CoreBridge()

    // MARK: - Properties

    /// Thread-safe access to the last error message
    private let lastErrorMessage = ThreadSafeFFIResult<String>()

    /// Serial queue for FFI operations to ensure thread safety
    private let ffiQueue = DispatchQueue(label: "com.flowfinder.ffi", qos: .userInitiated)

    // MARK: - Initialization

    private init() {}

    // MARK: - Directory Operations

    /// List directory contents via FFI
    /// - Parameter path: Directory path to list
    /// - Returns: Array of FileEntry objects
    /// - Throws: CoreBridgeError if operation fails
    public func listDirectory(path: String) throws -> [FileEntry] {
        guard !path.isEmpty else {
            throw CoreBridgeError.invalidPath(path)
        }

        // Verify path exists
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        guard exists else {
            throw CoreBridgeError.invalidPath("Path does not exist: \(path)")
        }

        var entries: [FileEntry] = []

        // Use a serial queue for thread-safe FFI access
        var ffiResult: Int32 = -1
        var ffiEntries: [FileEntry] = []

        // Execute FFI call on the serial queue
        let semaphore = DispatchSemaphore(value: 0)

        ffiQueue.async {
            defer { semaphore.signal() }

            var context = EntryCollectorContext()
            context.entries = []

            let result = path.withCString { cPath in
                withUnsafeMutablePointer(to: &context) { contextPtr in
                    ff_list_dir(cPath, entryCallback, contextPtr)
                }
            }

            ffiResult = result
            ffiEntries = context.entries
        }

        semaphore.wait()

        guard ffiResult == 0 else {
            let errorMessage = getLastError()
            throw CoreBridgeError.ffiError(errorMessage)
        }

        entries = ffiEntries

        // Sort entries: directories first, then alphabetically
        entries.sort { a, b in
            if a.isDirectory != b.isDirectory {
                return a.isDirectory && !b.isDirectory
            }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }

        return entries
    }

    // MARK: - Error Handling

    /// Get the last error message from the Rust core
    /// - Returns: Error message string
    private func getLastError() -> String {
        guard let cString = ff_last_error() else {
            return "Unknown error"
        }

        // Safely convert C string to Swift String
        let message = String(cString: cString)

        // Free the C string allocated by Rust
        ff_free_string(UnsafeMutablePointer(mutating: cString))

        return message
    }

    /// Get the last error message (thread-safe)
    /// - Returns: Last error message or "Unknown error"
    public func getLastErrorMessage() -> String {
        return lastErrorMessage.get() ?? "Unknown error"
    }
}

// MARK: - Entry Collector Context

/// Context structure for collecting entries from FFI callback
private struct EntryCollectorContext {
    var entries: [FileEntry] = []
}

// MARK: - FFI Callback

/// Callback function called by Rust for each directory entry
private func entryCallback(
    _ entryRefPtr: UnsafeRawPointer?,
    _ userData: UnsafeMutableRawPointer?
) {
    guard let entryRefPtr = entryRefPtr,
          let userData = userData else { return }

    let entryRef = entryRefPtr.assumingMemoryBound(to: FFEntryRef.self)
    let context = userData.withMemoryRebound(to: EntryCollectorContext.self, capacity: 1) { $0 }
    let entry = FileEntry(from: entryRef.pointee)
    context.pointee.entries.append(entry)
}
