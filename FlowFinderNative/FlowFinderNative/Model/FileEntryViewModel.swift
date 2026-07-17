import Foundation
import Combine

/// 文件条目视图模型，管理目录浏览状态
public final class FileEntryViewModel: ObservableObject {
    @Published public var entries: [FileEntry] = []
    @Published public var currentPath: String = FileManager.default.homeDirectoryForCurrentUser.path
    @Published public var isLoading: Bool = false
    @Published public var errorMessage: String?

    private var cancellables = Set<AnyCancellable>()
    private let coreBridge = CoreBridge.shared

    public init() {}

    /// 加载当前目录的内容
    public func loadDirectory() {
        loadDirectory(path: currentPath)
    }

    /// 加载指定目录的内容
    /// - Parameter path: 目标目录路径
    public func loadDirectory(path: String) {
        isLoading = true
        errorMessage = nil

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            do {
                let newEntries = try self.coreBridge.listDirectory(path: path)
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

    /// 导航到指定条目
    /// - Parameter entry: 目标文件条目
    public func navigateToEntry(_ entry: FileEntry) {
        guard entry.isDirectory else { return }
        loadDirectory(path: entry.path)
    }

    /// 导航到上级目录
    public func navigateToParent() {
        let parentPath = (currentPath as NSString).deletingLastPathComponent
        guard parentPath != currentPath else { return }
        loadDirectory(path: parentPath)
    }

    /// 导航到主目录
    public func navigateToHome() {
        loadDirectory(path: FileManager.default.homeDirectoryForCurrentUser.path)
    }
}
