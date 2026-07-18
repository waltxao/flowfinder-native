import Foundation
import AppKit
import QuickLook

// MARK: - Duplicate Scan Bridge

/// Thread-safe bridge for duplicate file detection via FFI
public final class DuplicateScanBridge {

    public static let shared = DuplicateScanBridge()

    private let ffiQueue = DispatchQueue(label: "com.flowfinder.dedup", qos: .userInitiated)

    private init() {}

    /// Scan for duplicate files under a path
    /// - Parameters:
    ///   - path: Root directory path to scan
    ///   - progressHandler: Called with (scanned, total) progress updates
    ///   - groupHandler: Called for each duplicate group found
    ///   - completion: Called when scan completes or errors
    public func scanDuplicates(
        path: String,
        progressHandler: @escaping (Int, Int) -> Void,
        groupHandler: @escaping (FFDuplicateGroup) -> Void,
        completion: @escaping (Error?) -> Void
    ) {
        ffiQueue.async {
            var progressContext = DedupProgressContext(progressHandler: progressHandler)
            var groupContext = DedupGroupContext(groupHandler: groupHandler)

            let result = path.withCString { cPath in
                ff_scan_duplicates(
                    cPath,
                    dedupProgressCallback,
                    dedupGroupCallback,
                    &groupContext
                )
            }

            if result == 0 {
                completion(nil)
            } else {
                let errorMessage = self.getLastError()
                completion(CoreBridgeError.ffiError(errorMessage))
            }
        }
    }

    /// Cancel an ongoing duplicate scan
    public func cancelScan() {
        ff_cancel_scan()
    }

    private func getLastError() -> String {
        guard let cString = ff_last_error() else {
            return "Unknown error"
        }
        let message = String(cString: cString)
        ff_free_string(UnsafeMutablePointer(mutating: cString))
        return message
    }
}

// MARK: - Search Bridge

/// Thread-safe bridge for file search via FFI
public final class SearchBridge {

    public static let shared = SearchBridge()

    private let ffiQueue = DispatchQueue(label: "com.flowfinder.search", qos: .userInitiated)

    private init() {}

    /// Search for files matching query under path
    /// - Parameters:
    ///   - path: Root directory path
    ///   - query: Search query string
    ///   - resultHandler: Called for each matching result
    ///   - completion: Called when search completes or errors
    public func search(
        path: String,
        query: String,
        resultHandler: @escaping (FFSearchResult) -> Void,
        completion: @escaping (Error?) -> Void
    ) {
        ffiQueue.async {
            var context = SearchContext(resultHandler: resultHandler)

            let result = path.withCString { cPath in
                query.withCString { cQuery in
                    ff_search(cPath, cQuery, searchCallback, &context)
                }
            }

            if result == 0 {
                completion(nil)
            } else {
                let errorMessage = self.getLastError()
                completion(CoreBridgeError.ffiError(errorMessage))
            }
        }
    }

    /// Search for files with advanced filters
    /// - Parameters:
    ///   - path: Root directory path
    ///   - query: Search query string
    ///   - filters: Search filter criteria
    ///   - resultHandler: Called for each matching result
    ///   - completion: Called when search completes or errors
    public func searchWithFilters(
        path: String,
        query: String,
        filters: FFSearchFilters,
        resultHandler: @escaping (FFSearchResult) -> Void,
        completion: @escaping (Error?) -> Void
    ) {
        ffiQueue.async {
            var context = SearchContext(resultHandler: resultHandler)

            // Build C-compatible filters
            var cFilters = FFSearchFilters_C(
                file_types: nil,
                min_size: filters.minSize ?? 0,
                max_size: filters.maxSize ?? 0,
                modified_after: filters.modifiedAfter ?? 0,
                modified_before: filters.modifiedBefore ?? 0,
                has_file_types: filters.fileTypes != nil,
                has_min_size: filters.minSize != nil,
                has_max_size: filters.maxSize != nil,
                has_modified_after: filters.modifiedAfter != nil,
                has_modified_before: filters.modifiedBefore != nil
            )

            if let fileTypes = filters.fileTypes {
                let cFileTypes = fileTypes.withCString { ptr in
                    return strdup(ptr)
                }
                cFilters.file_types = cFileTypes
            }

            let result = path.withCString { cPath in
                query.withCString { cQuery in
                    ff_search_with_filters(cPath, cQuery, &cFilters, searchCallback, &context)
                }
            }

            if cFilters.file_types != nil {
                free(cFilters.file_types)
            }

            if result == 0 {
                completion(nil)
            } else {
                let errorMessage = self.getLastError()
                completion(CoreBridgeError.ffiError(errorMessage))
            }
        }
    }

    private func getLastError() -> String {
        guard let cString = ff_last_error() else {
            return "Unknown error"
        }
        let message = String(cString: cString)
        ff_free_string(UnsafeMutablePointer(mutating: cString))
        return message
    }
}

// MARK: - QuickLook Preview Bridge

/// Bridge for QuickLook preview functionality
public final class QuickLookBridge {

    public static let shared = QuickLookBridge()

    private init() {}

    /// Get the file type/extension for a path
    /// - Parameter path: File path
    /// - Returns: File extension or empty string
    public func getFileType(path: String) -> String {
        let result = path.withCString { cPath in
            ff_get_file_type(cPath)
        }

        guard let cString = result else {
            return ""
        }

        let type = String(cString: cString)
        ff_free_string(UnsafeMutablePointer(mutating: cString))
        return type
    }

    /// Check if a file can be previewed
    /// - Parameter path: File path
    /// - Returns: True if the file type supports preview
    public func canPreview(path: String) -> Bool {
        let ext = getFileType(path: path).lowercased()
        let supportedExtensions = [
            // Images
            "jpg", "jpeg", "png", "gif", "bmp", "tiff", "tif", "heic", "webp",
            // Documents
            "pdf", "txt", "md", "rtf",
            // Audio
            "mp3", "aac", "wav", "aiff",
            // Video
            "mp4", "mov", "m4v", "avi",
            // Archives
            "zip"
        ]
        return supportedExtensions.contains(ext)
    }

    // MARK: - QuickLook Panel

    private var previewWindow: NSWindow?

    /// Show Quick Look preview for the given file paths
    /// - Parameter paths: Array of file paths to preview
    public func show(paths: [String]) {
        guard !paths.isEmpty else { return }

        let url = URL(fileURLWithPath: paths[0])

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            // Close existing preview window
            self.close()

            // Create a simple preview window
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = url.lastPathComponent
            window.center()
            window.makeKeyAndOrderFront(nil)

            // Add a simple text view showing file info
            let textView = NSTextView(frame: window.contentView!.bounds)
            textView.autoresizingMask = [.width, .height]
            textView.isEditable = false
            textView.font = NSFont.systemFont(ofSize: 14)

            let fileInfo = """
            File: \(url.lastPathComponent)
            Path: \(url.path)
            Type: \(self.getFileType(path: url.path))

            Note: Full Quick Look preview requires macOS Quick Look integration.
            For beta, this shows file information instead.
            """

            textView.string = fileInfo
            window.contentView?.addSubview(textView)

            self.previewWindow = window
        }
    }

    /// Close the Quick Look preview panel
    public func close() {
        DispatchQueue.main.async { [weak self] in
            self?.previewWindow?.close()
            self?.previewWindow = nil
        }
    }
}

// MARK: - C-compatible Search Filters

/// Internal C-compatible search filters structure
private struct FFSearchFilters_C {
    var file_types: UnsafeMutablePointer<CChar>?
    var min_size: UInt64
    var max_size: UInt64
    var modified_after: Int64
    var modified_before: Int64
    var has_file_types: Bool
    var has_min_size: Bool
    var has_max_size: Bool
    var has_modified_after: Bool
    var has_modified_before: Bool
}

// MARK: - Callback Contexts

private struct DedupProgressContext {
    var progressHandler: (Int, Int) -> Void
}

private struct DedupGroupContext {
    var groupHandler: (FFDuplicateGroup) -> Void
}

private struct SearchContext {
    var resultHandler: (FFSearchResult) -> Void
}

// MARK: - C Callbacks

private func dedupProgressCallback(scanned: Int, total: Int, userData: UnsafeMutableRawPointer?) {
    guard let userData = userData else { return }
    let context = userData.withMemoryRebound(to: DedupProgressContext.self, capacity: 1) { $0 }
    DispatchQueue.main.async {
        context.pointee.progressHandler(scanned, total)
    }
}

private func dedupGroupCallback(groupPtr: UnsafeRawPointer?, userData: UnsafeMutableRawPointer?) {
    guard let groupPtr = groupPtr else { return }
    // Parse the C struct and call the handler
    // This is a simplified version - in production you'd parse the full struct
}

private func searchCallback(resultPtr: UnsafeRawPointer?, userData: UnsafeMutableRawPointer?) {
    guard let resultPtr = resultPtr,
          let userData = userData else { return }

    let context = userData.withMemoryRebound(to: SearchContext.self, capacity: 1) { $0 }

    // Parse the C struct (simplified)
    // In production, you'd properly parse the FFSearchResult C struct
}
