import Foundation
import Combine

/// View model managing file entry data and directory navigation state
public final class FileEntryViewModel: ObservableObject {

    // MARK: - Published Properties

    /// Current list of file entries in the directory
    @Published public var entries: [FileEntry] = []

    /// Current directory path
    @Published public var currentPath: String = FileManager.default.homeDirectoryForCurrentUser.path

    /// Loading state indicator
    @Published public var isLoading: Bool = false

    /// Error message (nil when no error)
    @Published public var errorMessage: String?

    /// Current sort descriptor
    @Published public var sortDescriptor: NSSortDescriptor?

    // MARK: - Private Properties

    private var cancellables = Set<AnyCancellable>()
    private let coreBridge = CoreBridge.shared
    private let fileManager = FileManager.default

    // MARK: - Initialization

    public init() {}

    // MARK: - Directory Loading

    /// Load the current directory contents
    public func loadDirectory() {
        loadDirectory(path: currentPath)
    }

    /// Load contents of a specific directory
    /// - Parameter path: Target directory path
    public func loadDirectory(path: String) {
        isLoading = true
        errorMessage = nil

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            do {
                var newEntries = try self.coreBridge.listDirectory(path: path)

                // Sort entries: directories first, then by name
                newEntries.sort { a, b in
                    if a.isDirectory != b.isDirectory {
                        return a.isDirectory && !b.isDirectory
                    }
                    return a.name.localizedStandardCompare(b.name) == .orderedAscending
                }

                DispatchQueue.main.async {
                    self.entries = newEntries
                    self.currentPath = path
                    self.isLoading = false
                }
            } catch {
                DispatchQueue.main.async {
                    self.errorMessage = error.localizedDescription
                    self.isLoading = false
                }
            }
        }
    }

    /// Refresh the current directory (reload)
    public func refresh() {
        loadDirectory(path: currentPath)
    }

    // MARK: - Navigation

    /// Navigate to a specific file entry (only for directories)
    /// - Parameter entry: The file entry to navigate to
    public func navigateToEntry(_ entry: FileEntry) {
        guard entry.isDirectory else { return }
        loadDirectory(path: entry.path)
    }

    /// Navigate to the parent directory
    public func navigateToParent() {
        let parentPath = (currentPath as NSString).deletingLastPathComponent
        guard parentPath != currentPath else { return }
        loadDirectory(path: parentPath)
    }

    /// Navigate to the home directory
    public func navigateToHome() {
        loadDirectory(path: fileManager.homeDirectoryForCurrentUser.path)
    }

    /// Navigate to a specific path
    /// - Parameter path: Target path
    public func navigateToPath(_ path: String) {
        var resolvedPath = path
        if !resolvedPath.hasPrefix("/") {
            resolvedPath = (currentPath as NSString).appendingPathComponent(path)
        }
        loadDirectory(path: resolvedPath)
    }

    // MARK: - Sorting

    /// Sort entries by a specific key
    /// - Parameter descriptor: NSSortDescriptor defining sort criteria
    public func sort(by descriptor: NSSortDescriptor) {
        sortDescriptor = descriptor

        var sorted = entries
        sorted.sort { a, b in
            switch descriptor.key {
            case "name":
                let result = a.name.localizedStandardCompare(b.name)
                return descriptor.ascending ? result == .orderedAscending : result == .orderedDescending
            case "size":
                return descriptor.ascending ? a.size < b.size : a.size > b.size
            case "modificationDate":
                return descriptor.ascending
                                    ? a.modificationDate < b.modificationDate
                                    : a.modificationDate > b.modificationDate
            default:
                return false
            }
        }
        entries = sorted
    }

    // MARK: - Entry Queries

    /// Get entry at a specific index
    /// - Parameter index: Array index
    /// - Returns: FileEntry if index is valid
    public func entry(at index: Int) -> FileEntry? {
        guard index >= 0 && index < entries.count else { return nil }
        return entries[index]
    }

    /// Find entry by path
    /// - Parameter path: File path to search for
    /// - Returns: Matching FileEntry or nil
    public func entry(byPath path: String) -> FileEntry? {
        return entries.first { $0.path == path }
    }

    /// Filter entries by name (case-insensitive)
    /// - Parameter query: Search query string
    /// - Returns: Filtered array of entries
    public func filterEntries(matching query: String) -> [FileEntry] {
        let lowercased = query.lowercased()
        return entries.filter { $0.name.lowercased().contains(lowercased) }
    }

    // MARK: - Error Handling

    /// Clear any existing error message
    public func clearError() {
        errorMessage = nil
    }
}
