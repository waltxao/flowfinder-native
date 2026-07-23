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

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        value = nil
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

/// FSEvents 变更通知回调上下文：持有 changeHandler 闭包
private final class FSEventsContext {
    let changeHandler: (String) -> Void
    init(changeHandler: @escaping (String) -> Void) {
        self.changeHandler = changeHandler
    }
}

/// FSEvents 变更通知回调：从 userData 恢复上下文并调用 changeHandler
private func fseventsCallback(
    _ path: UnsafePointer<CChar>?,
    _ userData: UnsafeMutableRawPointer?
) {
    guard let path = path, let userData = userData else { return }
    let context = Unmanaged<FSEventsContext>.fromOpaque(userData).takeUnretainedValue()
    let pathString = String(cString: path)
    context.changeHandler(pathString)
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

/// Box holding an optional Swift progress closure for parallel batch operations.
/// Stored on the heap so a `@convention(c)` FFI callback can recover it via
/// `Unmanaged` and invoke the closure from worker threads.
private final class ProgressBox {
    let handler: ((Int, Int) -> Void)?
    init(handler: ((Int, Int) -> Void)?) { self.handler = handler }
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

    /// FSEvents watcher 句柄（由 ff_fsevents_start 返回）
    private var fseventsWatcherHandle: Int32 = 0

    /// FSEvents 回调上下文（持有 changeHandler 闭包，防止被释放）
    private var fseventsContext: FSEventsContext?

    // MARK: - Initialization

    private init() {}

    // MARK: - Directory Operations

    /// List directory contents via FFI
    ///
    /// Two-tier cache lookup: the L1 (in-memory) and L2 (SQLite persistent)
    /// caches are consulted first via `ff_cache_get`. On a cache hit the
    /// entries are delivered directly from the cache, skipping the live
    /// filesystem scan. On a cache miss the directory is scanned with
    /// `ff_list_dir` and, on success, the result is written back to the
    /// cache via `ff_cache_put` so subsequent navigations hit the cache.
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

            // ── L1 + L2 cache lookup ───────────────────────────────────
            // ff_cache_get delivers cached entries through the same
            // entryCallback used by ff_list_dir. A return of FF_OK (0) with
            // a non-empty entry list is a cache hit — skip the live scan.
            // Any other return (including FF_ERR_NOT_FOUND) is a miss.
            var cacheContext = EntryCollectorContext()
            cacheContext.entries = []
            let cacheResult = path.withCString { cPath in
                withUnsafeMutablePointer(to: &cacheContext) { contextPtr in
                    ff_cache_get(cPath, entryCallback, contextPtr)
                }
            }

            if cacheResult == 0 && !cacheContext.entries.isEmpty {
                // Cache hit — use the cached entries directly.
                ffiResult = 0
                ffiEntries = cacheContext.entries
                return
            }

            // ── Cache miss — live scan via ff_list_dir ─────────────────
            var scanContext = EntryCollectorContext()
            scanContext.entries = []
            let result = path.withCString { cPath in
                withUnsafeMutablePointer(to: &scanContext) { contextPtr in
                    ff_list_dir(cPath, entryCallback, contextPtr)
                }
            }

            ffiResult = result
            ffiEntries = scanContext.entries

            // On a successful scan, populate the cache (best-effort) so the
            // next navigation hits the cache. Failures are swallowed —
            // cache write errors must not break directory listing.
            if result == 0 && !scanContext.entries.isEmpty {
                self.populateCache(path: path, entries: scanContext.entries)
            }
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

    /// Best-effort cache population. Builds an `FFEntryRef` array (with
    /// heap-allocated C strings) from `entries` and calls `ff_cache_put`.
    /// All allocations are freed before returning; cache write failures
    /// are silently ignored — navigation must not fail because the cache
    /// could not be written.
    private func populateCache(path: String, entries: [FileEntry]) {
        var refs: [FFEntryRef] = []
        refs.reserveCapacity(entries.count)
        var allocated: [UnsafeMutablePointer<CChar>] = []
        allocated.reserveCapacity(entries.count * 3)

        for entry in entries {
            guard let namePtr = strdup(entry.name),
                  let pathPtr = strdup(entry.path),
                  let extPtr = strdup(entry.fileExtension) else {
                // Allocation failed — free what we have and bail out
                // (best-effort: skip caching this directory).
                for p in allocated { free(p) }
                return
            }
            allocated.append(namePtr)
            allocated.append(pathPtr)
            allocated.append(extPtr)

            refs.append(FFEntryRef(
                name: namePtr,
                path: pathPtr,
                `extension`: extPtr,
                isDir: entry.isDirectory,
                isFile: entry.isFile,
                isSymlink: entry.isSymlink,
                isHidden: entry.isHidden,
                isSystemProtected: entry.isSystemProtected,
                size: entry.size,
                modified: Int64(entry.modificationDate.timeIntervalSince1970),
                created: Int64(entry.creationDate.timeIntervalSince1970)
            ))
        }

        // ff_cache_put copies the entries into Rust-owned memory, so the
        // C strings we allocated are safe to free immediately after the call.
        let _ = path.withCString { cPath in
            refs.withUnsafeBufferPointer { buffer in
                ff_cache_put(cPath, buffer.baseAddress, refs.count)
            }
        }

        for p in allocated { free(p) }
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

    // MARK: - Parallel Batch File Operations

    /// No-op C callback used when the caller does not supply a progress handler.
    private static let noopBatchProgress: FFBatchProgressCallback = { _, _, _, _ in }

    /// Parallel copy multiple files into a destination directory (rayon-backed).
    ///
    /// Each source file is copied (CoW when possible) into `dstDir` keeping its
    /// basename. Partial failures are reported via the return value.
    ///
    /// - Parameters:
    ///   - srcs: Array of source file paths.
    ///   - dstDir: Destination directory path.
    ///   - progress: Optional `(completed, total)` callback invoked from worker threads.
    /// - Returns: Number of successfully copied files.
    /// - Throws: `CoreBridgeError.ffiError` if FFI returns a negative error code.
    func parallelCopy(srcs: [String], dstDir: String, progress: ((Int, Int) -> Void)? = nil) throws -> Int {
        guard !dstDir.isEmpty else {
            throw CoreBridgeError.invalidPath("Destination directory is empty")
        }
        if srcs.isEmpty { return 0 }

        var ffiResult: Int32 = -1
        let semaphore = DispatchSemaphore(value: 0)

        // Allocate C string pointers (`strdup`) so the array remains valid
        // across the FFI call. Cleanup happens after `semaphore.wait()`.
        let cStringPtrs: [UnsafeMutablePointer<CChar>?] = srcs.map { strdup($0) }
        defer {
            for p in cStringPtrs { if let p = p { free(p) } }
        }

        // Bridge the optional Swift closure to a C function pointer via a
        // context box. When `progress` is nil, a no-op callback is used.
        let progressBox = ProgressBox(handler: progress)
        let progressCallback: FFBatchProgressCallback = { completed, total, _, userData in
            guard let userData = userData else { return }
            let box = Unmanaged<ProgressBox>.fromOpaque(userData).takeUnretainedValue()
            box.handler?(completed, total)
        }

        ffiQueue.async {
            defer { semaphore.signal() }

            let result = dstDir.withCString { cDstDir in
                cStringPtrs.withUnsafeBufferPointer { buffer in
                    ff_parallel_copy(
                        buffer.baseAddress,
                        cStringPtrs.count,
                        cDstDir,
                        progressBox.handler != nil ? progressCallback : CoreBridge.noopBatchProgress,
                        Unmanaged.passUnretained(progressBox).toOpaque()
                    )
                }
            }
            ffiResult = result
            // I3: capture ff_last_error() on this FFI thread so callers on
            // the UI thread can retrieve partial-failure details ("N/M
            // failed: …") via getLastError(). Only stored when non-empty so
            // a fully-successful batch does not mask a later error.
            let captured = self.captureLastErrorFFI()
            if !captured.isEmpty {
                self.lastErrorMessage.set(captured)
            }
        }

        semaphore.wait()

        guard ffiResult >= 0 else {
            let errorMessage = getLastError()
            throw CoreBridgeError.ffiError(errorMessage)
        }
        return Int(ffiResult)
    }

    /// Parallel move multiple files into a destination directory (rayon-backed).
    ///
    /// Same semantics as `parallelCopy`, but moves files instead. Falls back
    /// to copy-then-delete for cross-volume moves.
    func parallelMove(srcs: [String], dstDir: String, progress: ((Int, Int) -> Void)? = nil) throws -> Int {
        guard !dstDir.isEmpty else {
            throw CoreBridgeError.invalidPath("Destination directory is empty")
        }
        if srcs.isEmpty { return 0 }

        var ffiResult: Int32 = -1
        let semaphore = DispatchSemaphore(value: 0)

        let cStringPtrs: [UnsafeMutablePointer<CChar>?] = srcs.map { strdup($0) }
        defer {
            for p in cStringPtrs { if let p = p { free(p) } }
        }

        let progressBox = ProgressBox(handler: progress)
        let progressCallback: FFBatchProgressCallback = { completed, total, _, userData in
            guard let userData = userData else { return }
            let box = Unmanaged<ProgressBox>.fromOpaque(userData).takeUnretainedValue()
            box.handler?(completed, total)
        }

        ffiQueue.async {
            defer { semaphore.signal() }

            let result = dstDir.withCString { cDstDir in
                cStringPtrs.withUnsafeBufferPointer { buffer in
                    ff_parallel_move(
                        buffer.baseAddress,
                        cStringPtrs.count,
                        cDstDir,
                        progressBox.handler != nil ? progressCallback : CoreBridge.noopBatchProgress,
                        Unmanaged.passUnretained(progressBox).toOpaque()
                    )
                }
            }
            ffiResult = result
            // I3: capture ff_last_error() on this FFI thread so callers on
            // the UI thread can retrieve partial-failure details ("N/M
            // failed: …") via getLastError(). Only stored when non-empty so
            // a fully-successful batch does not mask a later error.
            let captured = self.captureLastErrorFFI()
            if !captured.isEmpty {
                self.lastErrorMessage.set(captured)
            }
        }

        semaphore.wait()

        guard ffiResult >= 0 else {
            let errorMessage = getLastError()
            throw CoreBridgeError.ffiError(errorMessage)
        }
        return Int(ffiResult)
    }

    /// Parallel delete multiple files/directories (rayon-backed).
    /// Directories are removed recursively.
    ///
    /// - Parameters:
    ///   - paths: Array of paths to delete.
    ///   - progress: Optional `(completed, total)` callback invoked from worker threads.
    /// - Returns: Number of successfully deleted paths.
    /// - Throws: `CoreBridgeError.ffiError` if FFI returns a negative error code.
    func parallelDelete(paths: [String], progress: ((Int, Int) -> Void)? = nil) throws -> Int {
        if paths.isEmpty { return 0 }

        var ffiResult: Int32 = -1
        let semaphore = DispatchSemaphore(value: 0)

        let cStringPtrs: [UnsafeMutablePointer<CChar>?] = paths.map { strdup($0) }
        defer {
            for p in cStringPtrs { if let p = p { free(p) } }
        }

        let progressBox = ProgressBox(handler: progress)
        let progressCallback: FFBatchProgressCallback = { completed, total, _, userData in
            guard let userData = userData else { return }
            let box = Unmanaged<ProgressBox>.fromOpaque(userData).takeUnretainedValue()
            box.handler?(completed, total)
        }

        ffiQueue.async {
            defer { semaphore.signal() }

            let result = cStringPtrs.withUnsafeBufferPointer { buffer in
                ff_parallel_delete(
                    buffer.baseAddress,
                    cStringPtrs.count,
                    progressBox.handler != nil ? progressCallback : CoreBridge.noopBatchProgress,
                    Unmanaged.passUnretained(progressBox).toOpaque()
                )
            }
            ffiResult = result
            // I3: capture ff_last_error() on this FFI thread so callers on
            // the UI thread can retrieve partial-failure details ("N/M
            // failed: …") via getLastError(). Only stored when non-empty so
            // a fully-successful batch does not mask a later error.
            let captured = self.captureLastErrorFFI()
            if !captured.isEmpty {
                self.lastErrorMessage.set(captured)
            }
        }

        semaphore.wait()

        guard ffiResult >= 0 else {
            let errorMessage = getLastError()
            throw CoreBridgeError.ffiError(errorMessage)
        }
        return Int(ffiResult)
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

    /// Initialize the L2 persistent (SQLite) directory cache.
    ///
    /// Must be called once at app startup with a writable filesystem path.
    /// After this call succeeds, `ff_cache_get`/`ff_cache_put`/`ff_cache_invalidate`
    /// additionally consult/persist to the SQLite database (best-effort).
    /// Safe to call multiple times — subsequent calls are no-ops if already
    /// initialized.
    /// - Parameter dbPath: Filesystem path to the SQLite database file
    /// - Throws: CoreBridgeError if initialization fails
    func initCache(dbPath: String) throws {
        guard !dbPath.isEmpty else {
            throw CoreBridgeError.invalidPath("dbPath is empty")
        }

        var ffiResult: Int32 = -1
        let semaphore = DispatchSemaphore(value: 0)

        ffiQueue.async {
            defer { semaphore.signal() }
            let result = dbPath.withCString { cPath in
                ff_cache_init(cPath)
            }
            ffiResult = result
        }

        semaphore.wait()

        guard ffiResult == 0 else {
            let errorMessage = getLastError()
            throw CoreBridgeError.ffiError(errorMessage)
        }
    }

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

        // 创建上下文并保留引用，防止被释放
        let context = FSEventsContext(changeHandler: changeHandler)
        self.fseventsContext = context
        let contextPtr = Unmanaged.passUnretained(context).toOpaque()

        var ffiResult: Int32 = -1
        let semaphore = DispatchSemaphore(value: 0)

        ffiQueue.async {
            defer { semaphore.signal() }

            let result = path.withCString { cPath in
                ff_fsevents_start(cPath, fseventsCallback, contextPtr)
            }
            ffiResult = result
        }

        semaphore.wait()

        guard ffiResult == 0 else {
            self.fseventsContext = nil
            let errorMessage = getLastError()
            throw CoreBridgeError.ffiError(errorMessage)
        }

        // 存储返回的 watcher 句柄
        self.fseventsWatcherHandle = ffiResult
    }

    /// Stop the FSEvents watcher
    /// - Throws: CoreBridgeError if operation fails
    func stopFSEventsWatcher() throws {
        let handle = self.fseventsWatcherHandle
        var ffiResult: Int32 = -1
        let semaphore = DispatchSemaphore(value: 0)

        ffiQueue.async {
            defer { semaphore.signal() }
            ffiResult = ff_fsevents_stop(handle)
        }

        semaphore.wait()

        // 清理上下文和句柄
        self.fseventsContext = nil
        self.fseventsWatcherHandle = 0

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

    /// Get the last error message from the Rust core.
    ///
    /// Rust stores `last_error` in thread-local storage, so a direct
    /// `ff_last_error()` call only returns a value when called on the same
    /// thread that ran the FFI function. Because every CoreBridge FFI call
    /// runs on the serial `ffiQueue`, calling `ff_last_error()` from the
    /// UI thread returns nothing.
    ///
    /// To bridge that gap, the parallel batch methods (parallelCopy /
    /// parallelMove / parallelDelete) capture `ff_last_error()` on the
    /// FFI thread right after the call and stash the result in
    /// `lastErrorMessage`. This getter prefers that captured value
    /// (read-once: it is cleared after being returned so subsequent calls
    /// do not observe a stale message) and falls back to a direct
    /// `ff_last_error()` call for non-parallel methods.
    /// - Returns: Error message string
    func getLastError() -> String {
        // Prefer the captured error from the FFI thread (set by parallel ops).
        // Read-once: clear after reading so stale messages don't leak across
        // unrelated operations.
        if let captured = lastErrorMessage.get() {
            lastErrorMessage.clear()
            if !captured.isEmpty {
                return captured
            }
        }

        guard let cString = ff_last_error() else {
            return "Unknown error"
        }

        // Safely convert C string to Swift String
        let message = String(cString: cString)

        // Free the C string allocated by Rust
        ff_free_string(UnsafeMutablePointer(mutating: cString))

        return message
    }

    /// Capture the current thread's `ff_last_error()` as a Swift String.
    /// Must be called on the same thread that ran the FFI function (i.e.
    /// inside `ffiQueue.async`). Returns an empty string when no error is
    /// set. The C string returned by Rust is freed before returning.
    private func captureLastErrorFFI() -> String {
        guard let cString = ff_last_error() else {
            return ""
        }
        let message = String(cString: cString)
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

    /// 提交一个新任务到调度器
    /// - Parameters:
    ///   - name: 任务类型名称（如 "Copy", "Move", "Delete", "Scan", "Index"）
    ///   - description: 任务描述
    ///   - priority: 任务优先级（0=Low, 1=Normal, 2=High）
    /// - Returns: 任务 ID 字符串
    /// - Throws: CoreBridgeError if operation fails
    func submitTask(name: String, description: String, priority: Int32) throws -> String {
        let semaphore = DispatchSemaphore(value: 0)
        var ffiResult: Int32 = -1
        var outTaskId: UnsafeMutablePointer<CChar>? = nil

        ffiQueue.async {
            defer { semaphore.signal() }

            name.withCString { cName in
                description.withCString { cDesc in
                    withUnsafeMutablePointer(to: &outTaskId) { outPtr in
                        ffiResult = ff_task_submit(cName, cDesc, priority, outPtr)
                    }
                }
            }
        }

        semaphore.wait()

        guard ffiResult == 0, let taskIdPtr = outTaskId else {
            let errorMessage = getLastError()
            throw CoreBridgeError.ffiError(errorMessage)
        }

        let taskId = String(cString: taskIdPtr)
        ff_free_string(taskIdPtr)
        return taskId
    }

    /// 取消正在运行或等待中的任务
    /// - Parameter taskId: 任务 ID 字符串
    /// - Throws: CoreBridgeError if operation fails
    func cancelTask(taskId: String) throws {
        let semaphore = DispatchSemaphore(value: 0)
        var ffiResult: Int32 = -1

        ffiQueue.async {
            defer { semaphore.signal() }
            taskId.withCString { cTaskId in
                ffiResult = ff_task_cancel(cTaskId)
            }
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

    /// 获取指定卷的详细信息
    /// - Parameter path: 卷路径
    /// - Returns: VolumeInfo 对象
    /// - Throws: CoreBridgeError if operation fails
    func getVolumeInfo(path: String) throws -> VolumeInfo {
        var ffiVolumeInfo = FFVolumeInfo(
            name: nil, path: nil, fs_type: nil,
            total_size: 0, free_size: 0, used_size: 0,
            is_removable: false, is_ejectable: false, is_writable: false
        )
        var ffiResult: Int32 = -1
        let semaphore = DispatchSemaphore(value: 0)

        ffiQueue.async {
            defer { semaphore.signal() }

            ffiResult = path.withCString { cPath in
                withUnsafeMutablePointer(to: &ffiVolumeInfo) { outInfo in
                    ff_volume_info(cPath, outInfo)
                }
            }
        }

        semaphore.wait()

        guard ffiResult == 0 else {
            let errorMessage = getLastError()
            throw CoreBridgeError.ffiError(errorMessage)
        }

        let volume = VolumeInfo(from: ffiVolumeInfo)

        // 释放 Rust 分配的字符串
        ff_free_string(ffiVolumeInfo.name)
        ff_free_string(ffiVolumeInfo.path)
        ff_free_string(ffiVolumeInfo.fs_type)

        return volume
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


