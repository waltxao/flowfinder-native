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

// MARK: - FFI Callbacks (Global C Functions)

/// Callback function called by Rust for each directory entry
private func entryCallback(
    _ entryRefPtr: UnsafeRawPointer?,
    _ userData: UnsafeMutableRawPointer?
) {
    guard let entryRefPtr = entryRefPtr,
          let userData = userData else { return }

    let entryRef = entryRefPtr.assumingMemoryBound(to: FFEntryRef.self)
    let context = userData.assumingMemoryBound(to: EntryCollectorContext.self)
    let entry = FileEntry(from: entryRef.pointee)
    context.pointee.entries.append(entry)
}

/// Callback for FSEvents notifications
private func fseventsCallback(
    _ path: UnsafePointer<CChar>?,
    _ userData: UnsafeMutableRawPointer?
) {
    // Handle FSEvents notification
    // In production, this would notify the UI to refresh
}

/// Callback for thumbnail generation
private func thumbnailCallback(
    _ thumbnailPath: UnsafePointer<CChar>?,
    _ userData: UnsafeMutableRawPointer?
) {
    guard let thumbnailPath = thumbnailPath,
          let userData = userData else { return }

    let context = userData.assumingMemoryBound(to: ThumbnailContext.self)
    let path = String(cString: thumbnailPath)
    context.pointee.completion(path)
}

/// Callback for multiple thumbnails generation
private func thumbnailsCallback(
    _ thumbnailPath: UnsafePointer<CChar>?,
    _ userData: UnsafeMutableRawPointer?
) {
    guard let thumbnailPath = thumbnailPath,
          let userData = userData else { return }

    let path = String(cString: thumbnailPath)
    let context = userData.assumingMemoryBound(to: ThumbnailsContext.self)
    context.pointee.paths.pointee.append(path)
}

/// Callback for task list
private func taskListCallback(
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
) {
    guard let userData = userData else { return }

    let context = userData.assumingMemoryBound(to: TaskListContext.self)
    let statusString: String = if let status = status {
        String(cString: status)
    } else {
        "Pending"
    }
    
    let taskStatus: TaskInfo.TaskStatus
    switch statusString {
    case "Completed": taskStatus = .completed
    case "Running": taskStatus = .running
    case "Failed": taskStatus = .failed
    case "Cancelled": taskStatus = .cancelled
    default: taskStatus = .pending
    }
    
    let task = TaskInfo(
        id: String(id),
        name: name.map { String(cString: $0) } ?? "",
        description: description.map { String(cString: $0) } ?? "",
        priority: TaskInfo.TaskPriority(rawValue: priority) ?? .normal,
        status: taskStatus,
        progress: progress,
        createdAt: Date(timeIntervalSince1970: TimeInterval(createdAt)),
        startedAt: startedAt > 0 ? Date(timeIntervalSince1970: TimeInterval(startedAt)) : nil,
        completedAt: completedAt > 0 ? Date(timeIntervalSince1970: TimeInterval(completedAt)) : nil
    )
    context.pointee.tasks.pointee.append(task)
}

/// Callback for volume list
private func volumeListCallback(
    _ volumeInfoPtr: UnsafeRawPointer?,
    _ userData: UnsafeMutableRawPointer?
) {
    guard let volumeInfoPtr = volumeInfoPtr,
          let userData = userData else { return }

    let context = userData.assumingMemoryBound(to: VolumeListContext.self)
    let volumeInfo = volumeInfoPtr.assumingMemoryBound(to: FFVolumeInfo.self)
    let volume = VolumeInfo(from: volumeInfo.pointee)
    context.pointee.volumes.pointee.append(volume)
}

/// Callback for volume info
private func volumeInfoCallback(
    _ volumeInfoPtr: UnsafeRawPointer?,
    _ userData: UnsafeMutableRawPointer?
) {
    guard let volumeInfoPtr = volumeInfoPtr,
          let userData = userData else { return }

    let volumeInfo = volumeInfoPtr.assumingMemoryBound(to: FFVolumeInfo.self)
    let volume = VolumeInfo(from: volumeInfo.pointee)
    let volumes = userData.bindMemory(to: [VolumeInfo].self, capacity: 1)
    volumes.pointee.append(volume)
}

/// Callback for volume health check
private func healthCheckCallback(
    _ resultPtr: UnsafePointer<CChar>?,
    _ userData: UnsafeMutableRawPointer?
) {
    guard let resultPtr = resultPtr,
          let userData = userData else { return }

    let resultString = String(cString: resultPtr)
    let target = userData.bindMemory(to: String.self, capacity: 1)
    target.pointee = resultString
}

// MARK: - Callback Contexts

/// Context for collecting directory entries via callback
private struct EntryCollectorContext {
    var entries: [FileEntry] = []
}

/// Context for thumbnail generation callback
private struct ThumbnailContext {
    let completion: (String?) -> Void
}

/// Context for multiple thumbnails generation callback
private struct ThumbnailsContext {
    let paths: UnsafeMutablePointer<[String]>
    let completion: ([String]) -> Void
}

/// Context for task list callback
private struct TaskListContext {
    let tasks: UnsafeMutablePointer<[TaskInfo]>
}

/// Context for task progress callback
private struct TaskProgressContext {
    let progress: UnsafeMutablePointer<Double>
}

/// Callback for task progress
private func taskProgressCallback(
    _ id: Int32,
    _ progress: Double,
    _ status: UnsafePointer<CChar>?,
    _ userData: UnsafeMutableRawPointer?
) {
    guard let userData = userData else { return }
    let context = userData.assumingMemoryBound(to: TaskProgressContext.self)
    context.pointee.progress.pointee = progress
}

/// Context for volume list callback
private struct VolumeListContext {
    let volumes: UnsafeMutablePointer<[VolumeInfo]>
}

// MARK: - CoreBridge

/// Thread-safe bridge for communicating with the Rust core via FFI
public final class CoreBridge {

    // MARK: - Singleton

    /// Shared instance of CoreBridge
    static let shared = CoreBridge()

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
    func listDirectory(path: String) throws -> [FileEntry] {
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

    // MARK: - File Operations

    /// Copy a file from src to dst
    /// - Parameters:
    ///   - src: Source file path
    ///   - dst: Destination file path
    /// - Throws: CoreBridgeError if operation fails
    func copyFile(src: String, dst: String) throws {
        guard !src.isEmpty, !dst.isEmpty else {
            throw CoreBridgeError.invalidPath("Source or destination path is empty")
        }

        var ffiResult: Int32 = -1
        let semaphore = DispatchSemaphore(value: 0)

        ffiQueue.async {
            defer { semaphore.signal() }

            let result = src.withCString { cSrc in
                dst.withCString { cDst in
                    ff_copy_file(cSrc, cDst)
                }
            }
            ffiResult = result
        }

        semaphore.wait()

        guard ffiResult == 0 else {
            let errorMessage = getLastError()
            throw CoreBridgeError.ffiError(errorMessage)
        }
    }

    /// Move a file or directory from src to dst
    /// - Parameters:
    ///   - src: Source path
    ///   - dst: Destination path
    /// - Throws: CoreBridgeError if operation fails
    func moveFile(src: String, dst: String) throws {
        guard !src.isEmpty, !dst.isEmpty else {
            throw CoreBridgeError.invalidPath("Source or destination path is empty")
        }

        var ffiResult: Int32 = -1
        let semaphore = DispatchSemaphore(value: 0)

        ffiQueue.async {
            defer { semaphore.signal() }

            let result = src.withCString { cSrc in
                dst.withCString { cDst in
                    ff_move_file(cSrc, cDst)
                }
            }
            ffiResult = result
        }

        semaphore.wait()

        guard ffiResult == 0 else {
            let errorMessage = getLastError()
            throw CoreBridgeError.ffiError(errorMessage)
        }
    }

    /// Delete a file at path
    /// - Parameter path: File path to delete
    /// - Throws: CoreBridgeError if operation fails
    func deleteFile(path: String) throws {
        guard !path.isEmpty else {
            throw CoreBridgeError.invalidPath("Path is empty")
        }

        var ffiResult: Int32 = -1
        let semaphore = DispatchSemaphore(value: 0)

        ffiQueue.async {
            defer { semaphore.signal() }

            let result = path.withCString { cPath in
                ff_delete_file(cPath)
            }
            ffiResult = result
        }

        semaphore.wait()

        guard ffiResult == 0 else {
            let errorMessage = getLastError()
            throw CoreBridgeError.ffiError(errorMessage)
        }
    }

    /// Delete a directory and all its contents at path
    /// - Parameter path: Directory path to delete
    /// - Throws: CoreBridgeError if operation fails
    func deleteDirectory(path: String) throws {
        guard !path.isEmpty else {
            throw CoreBridgeError.invalidPath("Path is empty")
        }

        var ffiResult: Int32 = -1
        let semaphore = DispatchSemaphore(value: 0)

        ffiQueue.async {
            defer { semaphore.signal() }

            let result = path.withCString { cPath in
                ff_delete_dir(cPath)
            }
            ffiResult = result
        }

        semaphore.wait()

        guard ffiResult == 0 else {
            let errorMessage = getLastError()
            throw CoreBridgeError.ffiError(errorMessage)
        }
    }

    /// Create a directory and all parent directories at path
    /// - Parameter path: Directory path to create
    /// - Throws: CoreBridgeError if operation fails
    func createDirectory(path: String) throws {
        guard !path.isEmpty else {
            throw CoreBridgeError.invalidPath("Path is empty")
        }

        var ffiResult: Int32 = -1
        let semaphore = DispatchSemaphore(value: 0)

        ffiQueue.async {
            defer { semaphore.signal() }

            let result = path.withCString { cPath in
                ff_create_dir(cPath)
            }
            ffiResult = result
        }

        semaphore.wait()

        guard ffiResult == 0 else {
            let errorMessage = getLastError()
            throw CoreBridgeError.ffiError(errorMessage)
        }
    }

    /// Rename a file or directory from src to dst
    /// - Parameters:
    ///   - src: Source path
    ///   - dst: Destination path
    /// - Throws: CoreBridgeError if operation fails
    func renameFile(src: String, dst: String) throws {
        guard !src.isEmpty, !dst.isEmpty else {
            throw CoreBridgeError.invalidPath("Source or destination path is empty")
        }

        var ffiResult: Int32 = -1
        let semaphore = DispatchSemaphore(value: 0)

        ffiQueue.async {
            defer { semaphore.signal() }

            let result = src.withCString { cSrc in
                dst.withCString { cDst in
                    ff_rename(cSrc, cDst)
                }
            }
            ffiResult = result
        }

        semaphore.wait()

        guard ffiResult == 0 else {
            let errorMessage = getLastError()
            throw CoreBridgeError.ffiError(errorMessage)
        }
    }

    // MARK: - Async File Operations

    /// Copy a file asynchronously
    /// - Parameters:
    ///   - src: Source file path
    ///   - dst: Destination file path
    ///   - completion: Completion handler with optional error
    func copyFileAsync(src: String, dst: String, completion: @escaping (CoreBridgeError?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                try self?.copyFile(src: src, dst: dst)
                completion(nil)
            } catch let error as CoreBridgeError {
                completion(error)
            } catch {
                completion(CoreBridgeError.unknownError)
            }
        }
    }

    /// Move a file asynchronously
    /// - Parameters:
    ///   - src: Source path
    ///   - dst: Destination path
    ///   - completion: Completion handler with optional error
    func moveFileAsync(src: String, dst: String, completion: @escaping (CoreBridgeError?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                try self?.moveFile(src: src, dst: dst)
                completion(nil)
            } catch let error as CoreBridgeError {
                completion(error)
            } catch {
                completion(CoreBridgeError.unknownError)
            }
        }
    }

    /// Delete a file asynchronously
    /// - Parameters:
    ///   - path: File path to delete
    ///   - completion: Completion handler with optional error
    func deleteFileAsync(path: String, completion: @escaping (CoreBridgeError?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                try self?.deleteFile(path: path)
                completion(nil)
            } catch let error as CoreBridgeError {
                completion(error)
            } catch {
                completion(CoreBridgeError.unknownError)
            }
        }
    }

    /// Delete a directory asynchronously
    /// - Parameters:
    ///   - path: Directory path to delete
    ///   - completion: Completion handler with optional error
    func deleteDirectoryAsync(path: String, completion: @escaping (CoreBridgeError?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                try self?.deleteDirectory(path: path)
                completion(nil)
            } catch let error as CoreBridgeError {
                completion(error)
            } catch {
                completion(CoreBridgeError.unknownError)
            }
        }
    }

    /// Create a directory asynchronously
    /// - Parameters:
    ///   - path: Directory path to create
    ///   - completion: Completion handler with optional error
    func createDirectoryAsync(path: String, completion: @escaping (CoreBridgeError?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                try self?.createDirectory(path: path)
                completion(nil)
            } catch let error as CoreBridgeError {
                completion(error)
            } catch {
                completion(CoreBridgeError.unknownError)
            }
        }
    }

    /// Rename a file or directory asynchronously
    /// - Parameters:
    ///   - src: Source path
    ///   - dst: Destination path
    ///   - completion: Completion handler with optional error
    func renameFileAsync(src: String, dst: String, completion: @escaping (CoreBridgeError?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                try self?.renameFile(src: src, dst: dst)
                completion(nil)
            } catch let error as CoreBridgeError {
                completion(error)
            } catch {
                completion(CoreBridgeError.unknownError)
            }
        }
    }

    // MARK: - Cache Operations

    /// Invalidate the directory cache for a specific path
    /// - Parameter path: Directory path to invalidate
    /// - Throws: CoreBridgeError if operation fails
    func invalidateCache(path: String) throws {
        guard !path.isEmpty else {
            throw CoreBridgeError.invalidPath("Path is empty")
        }

        var ffiResult: Int32 = -1
        let semaphore = DispatchSemaphore(value: 0)

        ffiQueue.async {
            defer { semaphore.signal() }
            let result = path.withCString { cPath in
                ff_cache_invalidate(cPath)
            }
            ffiResult = result
        }

        semaphore.wait()

        guard ffiResult == 0 else {
            let errorMessage = getLastError()
            throw CoreBridgeError.ffiError(errorMessage)
        }
    }

    /// Clear all directory caches (invalidate all)
    /// - Throws: CoreBridgeError if operation fails
    func clearAllCache() throws {
        var ffiResult: Int32 = -1
        let semaphore = DispatchSemaphore(value: 0)

        ffiQueue.async {
            defer { semaphore.signal() }
            ffiResult = ff_dir_cache_clear()
        }

        semaphore.wait()

        guard ffiResult == 0 else {
            let errorMessage = getLastError()
            throw CoreBridgeError.ffiError(errorMessage)
        }
    }

    // MARK: - FSEvents Watcher (Sub-project 5)

    /// Start watching a path for filesystem changes
    /// - Parameters:
    ///   - path: Directory path to watch
    ///   - changeHandler: Called when a change is detected
    /// - Throws: CoreBridgeError if operation fails
    func startFSEventsWatcher(path: String, changeHandler: @escaping (String) -> Void) throws {
        guard !path.isEmpty else {
            throw CoreBridgeError.invalidPath("Path is empty")
        }

        var ffiResult: Int32 = -1
        let semaphore = DispatchSemaphore(value: 0)

        ffiQueue.async {
            defer { semaphore.signal() }

            let result = path.withCString { cPath in
                ff_fsevents_start(cPath, fseventsCallback, nil)
            }
            ffiResult = result
        }

        semaphore.wait()

        guard ffiResult == 0 else {
            let errorMessage = getLastError()
            throw CoreBridgeError.ffiError(errorMessage)
        }
    }

    /// Stop the FSEvents watcher
    /// - Throws: CoreBridgeError if operation fails
    func stopFSEventsWatcher() throws {
        var ffiResult: Int32 = -1
        let semaphore = DispatchSemaphore(value: 0)

        ffiQueue.async {
            defer { semaphore.signal() }
            ffiResult = ff_fsevents_stop(0)
        }

        semaphore.wait()

        guard ffiResult == 0 else {
            let errorMessage = getLastError()
            throw CoreBridgeError.ffiError(errorMessage)
        }
    }

    // MARK: - Batch Rename & Organize (Sub-project 6)

    /// Batch rename files
    /// - Parameters:
    ///   - items: Array of (originalPath, newName) tuples
    /// - Returns: Number of successful renames
    /// - Throws: CoreBridgeError if operation fails
    func batchRename(items: [(String, String)]) throws -> Int {
        guard !items.isEmpty else {
            throw CoreBridgeError.invalidPath("Items array is empty")
        }

        var ffiResult: Int32 = -1
        let semaphore = DispatchSemaphore(value: 0)

        // Convert items to C-compatible format
        var cItems: [FFRenameItem] = []
        for (original, newName) in items {
            let originalPtr = strdup(original)
            let newNamePtr = strdup(newName)
            cItems.append(FFRenameItem(originalPath: originalPtr!, newName: newNamePtr!))
        }

        ffiQueue.async {
            defer { semaphore.signal() }

            let result = cItems.withUnsafeBufferPointer { buffer in
                ff_batch_rename(buffer.baseAddress!, cItems.count)
            }
            ffiResult = result
        }

        semaphore.wait()

        // Free allocated strings
        for item in cItems {
            free(item.originalPath)
            free(item.newName)
        }

        guard ffiResult >= 0 else {
            let errorMessage = getLastError()
            throw CoreBridgeError.ffiError(errorMessage)
        }

        return Int(ffiResult)
    }

    /// Organize files by date into folders
    /// - Parameters:
    ///   - path: Directory path
    ///   - format: Date format string (e.g., "YYYY/MM/DD")
    /// - Returns: Number of files moved
    /// - Throws: CoreBridgeError if operation fails
    func organizeByDate(path: String, format: String = "YYYY/MM/DD") throws -> Int {
        guard !path.isEmpty else {
            throw CoreBridgeError.invalidPath("Path is empty")
        }

        var ffiResult: Int32 = -1
        let semaphore = DispatchSemaphore(value: 0)

        ffiQueue.async {
            defer { semaphore.signal() }

            let result = path.withCString { cPath in
                format.withCString { cFormat in
                    ff_organize_by_date(cPath, cFormat)
                }
            }
            ffiResult = result
        }

        semaphore.wait()

        guard ffiResult >= 0 else {
            let errorMessage = getLastError()
            throw CoreBridgeError.ffiError(errorMessage)
        }

        return Int(ffiResult)
    }

    /// Organize files by file type into category folders
    /// - Parameter path: Directory path
    /// - Returns: Number of files moved
    /// - Throws: CoreBridgeError if operation fails
    func organizeByType(path: String) throws -> Int {
        guard !path.isEmpty else {
            throw CoreBridgeError.invalidPath("Path is empty")
        }

        var ffiResult: Int32 = -1
        let semaphore = DispatchSemaphore(value: 0)

        ffiQueue.async {
            defer { semaphore.signal() }

            let result = path.withCString { cPath in
                ff_organize_by_type(cPath)
            }
            ffiResult = result
        }

        semaphore.wait()

        guard ffiResult >= 0 else {
            let errorMessage = getLastError()
            throw CoreBridgeError.ffiError(errorMessage)
        }

        return Int(ffiResult)
    }

    // MARK: - Thumbnail Generation (Sub-project 7)

    /// Generate a thumbnail for an image file
    /// - Parameters:
    ///   - path: Image file path
    ///   - maxSize: Maximum width/height of the thumbnail
    ///   - completion: Called with the thumbnail path on success
    /// - Throws: CoreBridgeError if operation fails
    func generateThumbnail(path: String, maxSize: UInt32, completion: @escaping (String?) -> Void) throws {
        guard !path.isEmpty else {
            throw CoreBridgeError.invalidPath("Path is empty")
        }

        ffiQueue.async {
            var context = ThumbnailContext(completion: completion)

            let result = path.withCString { cPath in
                ff_generate_thumbnail(cPath, maxSize, thumbnailCallback, &context)
            }

            if result != 0 {
                _ = self.getLastError()
                DispatchQueue.main.async {
                    completion(nil)
                }
            }
        }
    }

    /// Generate thumbnails for multiple image files
    /// - Parameters:
    ///   - paths: Array of image file paths
    ///   - maxSize: Maximum width/height of each thumbnail
    ///   - completion: Called with array of thumbnail paths on success
    /// - Throws: CoreBridgeError if operation fails
    func generateThumbnails(paths: [String], maxSize: UInt32, completion: @escaping ([String]) -> Void) throws {
        guard !paths.isEmpty else {
            throw CoreBridgeError.invalidPath("Paths array is empty")
        }

        ffiQueue.async {
            var thumbnailPaths: [String] = []
            withUnsafeMutablePointer(to: &thumbnailPaths) { pathsPtr in
                var context = ThumbnailsContext(paths: pathsPtr, completion: completion)

                let cPaths = paths.map { strdup($0) }
                let immutablePaths: [UnsafePointer<CChar>?] = cPaths.map { UnsafePointer($0!) }
                let result = withUnsafeMutablePointer(to: &context) { contextPtr in
                    immutablePaths.withUnsafeBufferPointer { buffer in
                        ff_generate_thumbnails(buffer.baseAddress!, paths.count, maxSize, thumbnailsCallback, contextPtr)
                    }
                }

            // Free allocated strings
            for ptr in cPaths {
                free(ptr)
            }

            if result != 0 {
                _ = self.getLastError()
                DispatchQueue.main.async {
                    completion([])
                }
            } else {
                DispatchQueue.main.async {
                    completion(thumbnailPaths)
                }
            }
        }
    }
    }

    // MARK: - Error Handling

    /// Get the last error message from the Rust core
    /// - Returns: Error message string
    func getLastError() -> String {
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
    func getLastErrorMessage() -> String {
        return lastErrorMessage.get() ?? "Unknown error"
    }

    // MARK: - Settings & Configuration (Sub-project 8)

    /// Load all settings as a JSON string
    /// - Returns: Settings JSON string
    /// - Throws: CoreBridgeError if operation fails
    func loadSettings() throws -> String {
        var resultString: String = ""
        let semaphore = DispatchSemaphore(value: 0)

        ffiQueue.async {
            defer { semaphore.signal() }

            guard let cString = ff_settings_load() else {
                return
            }
            resultString = String(cString: cString)
            ff_free_string(cString)
        }

        semaphore.wait()
        return resultString
    }

    /// Save settings from a JSON string
    /// - Parameter json: Settings JSON string
    /// - Throws: CoreBridgeError if operation fails
    func saveSettings(json: String) throws {
        var ffiResult: Int32 = -1
        let semaphore = DispatchSemaphore(value: 0)

        ffiQueue.async {
            defer { semaphore.signal() }

            let result = json.withCString { cJson in
                ff_settings_save(cJson)
            }
            ffiResult = result
        }

        semaphore.wait()

        guard ffiResult == 0 else {
            let errorMessage = getLastError()
            throw CoreBridgeError.ffiError(errorMessage)
        }
    }

    /// Get a specific setting value by key
    /// - Parameter key: Setting key
    /// - Returns: Setting value string, or empty if not found
    func getSetting(key: String) -> String {
        var resultString: String = ""
        let semaphore = DispatchSemaphore(value: 0)

        ffiQueue.async {
            defer { semaphore.signal() }

            guard let cString = ff_settings_get(key) else {
                return
            }
            resultString = String(cString: cString)
            ff_free_string(cString)
        }

        semaphore.wait()
        return resultString
    }

    /// Set a specific setting value
    /// - Parameters:
    ///   - key: Setting key
    ///   - value: Setting value
    /// - Throws: CoreBridgeError if operation fails
    func setSetting(key: String, value: String) throws {
        var ffiResult: Int32 = -1
        let semaphore = DispatchSemaphore(value: 0)

        ffiQueue.async {
            defer { semaphore.signal() }

            let result = key.withCString { cKey in
                value.withCString { cValue in
                    ff_settings_set(cKey, cValue)
                }
            }
            ffiResult = result
        }

        semaphore.wait()

        guard ffiResult == 0 else {
            let errorMessage = getLastError()
            throw CoreBridgeError.ffiError(errorMessage)
        }
    }

    // MARK: - Task Scheduler (Sub-project 9)

    /// Submit a new task to the scheduler
    /// - Parameters:
    ///   - name: Task name
    ///   - description: Task description
    ///   - priority: Task priority (0=low, 1=normal, 2=high)
    /// - Returns: Task ID string
    /// - Throws: CoreBridgeError if operation fails
    func submitTask(taskType: String, paramsJson: String) throws {
        let semaphore = DispatchSemaphore(value: 0)
        var ffiResult: Int32 = -1

        ffiQueue.async {
            defer { semaphore.signal() }

            taskType.withCString { cType in
                paramsJson.withCString { cParams in
                    ffiResult = ff_task_submit(cType, cParams)
                }
            }
        }

        semaphore.wait()

        guard ffiResult == 0 else {
            let errorMessage = getLastError()
            throw CoreBridgeError.ffiError(errorMessage)
        }
    }

    /// Cancel a running or pending task
    /// - Parameter taskId: Task ID to cancel
    /// - Throws: CoreBridgeError if operation fails
    func cancelTask(taskId: Int32) throws {
        let semaphore = DispatchSemaphore(value: 0)
        var ffiResult: Int32 = -1

        ffiQueue.async {
            defer { semaphore.signal() }
            ffiResult = ff_task_cancel(taskId)
        }

        semaphore.wait()

        guard ffiResult == 0 else {
            let errorMessage = getLastError()
            throw CoreBridgeError.ffiError(errorMessage)
        }
    }

    /// List all tasks
    /// - Returns: Array of TaskInfo objects
    func listTasks() -> [TaskInfo] {
        var tasks: [TaskInfo] = []
        let semaphore = DispatchSemaphore(value: 0)

        ffiQueue.async {
            defer { semaphore.signal() }

            withUnsafeMutablePointer(to: &tasks) { tasksPtr in
                var context = TaskListContext(tasks: tasksPtr)
                let _ = withUnsafeMutablePointer(to: &context) { contextPtr in
                    ff_task_list(taskListCallback, contextPtr)
                }
            }
        }

        semaphore.wait()
        return tasks
    }

    /// Get task progress
    /// - Parameter taskId: Task ID
    /// - Returns: Progress value (0.0 to 1.0), or -1 if not found
    func getTaskProgress(taskId: Int32) -> Double {
        var progress: Double = -1.0
        let semaphore = DispatchSemaphore(value: 0)

        ffiQueue.async {
            defer { semaphore.signal() }

            withUnsafeMutablePointer(to: &progress) { progressPtr in
                var context = TaskProgressContext(progress: progressPtr)
                let _ = withUnsafeMutablePointer(to: &context) { contextPtr in
                    ff_task_progress(taskId, taskProgressCallback, contextPtr)
                }
            }
        }

        semaphore.wait()
        return progress
    }

    // MARK: - Volume Management (Sub-project 10)

    /// List all mounted volumes
    /// - Returns: Array of VolumeInfo objects
    func listVolumes() -> [VolumeInfo] {
        var volumes: [VolumeInfo] = []
        let semaphore = DispatchSemaphore(value: 0)

        ffiQueue.async {
            defer { semaphore.signal() }

            withUnsafeMutablePointer(to: &volumes) { volumesPtr in
                var context = VolumeListContext(volumes: volumesPtr)
                let _ = withUnsafeMutablePointer(to: &context) { contextPtr in
                    ff_volume_list(volumeListCallback, contextPtr)
                }
            }
        }

        semaphore.wait()
        return volumes
    }

    /// Get detailed info for a specific volume
    /// - Parameter path: Volume path
    /// - Returns: VolumeInfo object
    /// - Throws: CoreBridgeError if operation fails
    func getVolumeInfo(path: String) throws -> VolumeInfo {
        var volumeInfo: VolumeInfo?
        let semaphore = DispatchSemaphore(value: 0)

        ffiQueue.async {
            defer { semaphore.signal() }

            let result = path.withCString { cPath in
                ff_volume_info(cPath, volumeInfoCallback, &volumeInfo)
            }

            if result != 0 {
                volumeInfo = nil
            }
        }

        semaphore.wait()

        guard let info = volumeInfo else {
            let errorMessage = getLastError()
            throw CoreBridgeError.ffiError(errorMessage)
        }

        return info
    }

    /// Perform health check on a volume
    /// - Parameter path: Volume path
    /// - Returns: Health check result string
    /// - Throws: CoreBridgeError if operation fails
    func checkVolumeHealth(path: String) throws -> String {
        var resultString: String = ""
        let semaphore = DispatchSemaphore(value: 0)

        ffiQueue.async {
            defer { semaphore.signal() }

            _ = path.withCString { cPath in
                ff_volume_health_check(cPath, healthCheckCallback, &resultString)
            }
        }

        semaphore.wait()

        guard !resultString.isEmpty else {
            let errorMessage = getLastError()
            throw CoreBridgeError.ffiError(errorMessage)
        }

        return resultString
    }

    /// Eject a removable volume
    /// - Parameter path: Volume path
    /// - Throws: CoreBridgeError if operation fails
    func ejectVolume(path: String) throws {
        var ffiResult: Int32 = -1
        let semaphore = DispatchSemaphore(value: 0)

        ffiQueue.async {
            defer { semaphore.signal() }

            let result = path.withCString { cPath in
                ff_volume_eject(cPath)
            }
            ffiResult = result
        }

        semaphore.wait()

        guard ffiResult == 0 else {
            let errorMessage = getLastError()
            throw CoreBridgeError.ffiError(errorMessage)
        }
    }

    /// Mount a network or external volume
    /// - Parameters:
    ///   - path: Volume path or URL
    ///   - options: Mount options
    /// - Throws: CoreBridgeError if operation fails
    func mountVolume(path: String, options: String = "") throws {
        var ffiResult: Int32 = -1
        let semaphore = DispatchSemaphore(value: 0)

        ffiQueue.async {
            defer { semaphore.signal() }

            let result = path.withCString { cPath in
                options.withCString { cOptions in
                    ff_volume_mount(cPath, cOptions)
                }
            }
            ffiResult = result
        }

        semaphore.wait()

        guard ffiResult == 0 else {
            let errorMessage = getLastError()
            throw CoreBridgeError.ffiError(errorMessage)
        }
    }

    // MARK: - Entry Collector Context

}


