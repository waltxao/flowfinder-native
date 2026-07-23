import Foundation
import Combine

// MARK: - SortField

enum SortField: String, CaseIterable {
    case name = "名称"
    case modifiedAt = "修改日期"
    case type = "类型"
    case size = "大小"

    var key: String {
        switch self {
        case .name: return "name"
        case .modifiedAt: return "modifiedAt"
        case .type: return "extension"
        case .size: return "size"
        }
    }
}

// MARK: - ViewMode

enum ViewMode: String, CaseIterable {
    case list = "list"
    case grid = "grid"
}

// MARK: - PaneState

struct PaneState {
    var path: String = ""
    var history: [String] = []
    var historyIndex: Int = 0
    var files: [FileEntry] = []
    var selectedFiles: [FileEntry] = []  // 有序数组，支持 Shift/Cmd 选择
    var isLoading: Bool = false
    var error: String?
    var searchQuery: String = ""
    var sortField: SortField = .name
    var sortAscending: Bool = true
    var viewMode: ViewMode = .list
    var groupBy: String = "none"
}

// MARK: - PaneViewModel

public class PaneViewModel: ObservableObject {
    @Published var state: PaneState = PaneState()

    /// 由 MainWindowController 注入，用于注册撤销/重做（per-window UndoManager）
    weak var undoManager: UndoManager?

    var currentPath: String { state.path }
    var files: [FileEntry] { state.files }
    var selectedFiles: [FileEntry] { state.selectedFiles }
    var isLoading: Bool { state.isLoading }
    var error: String? { state.error }

    /// 选中条目（计算属性，用于 DetailsBar）
    var selectedEntries: [FileEntry] { state.selectedFiles }

    init() {}

    init(path: String) {
        state.path = path
        state.history = [path]
        state.historyIndex = 0
        loadDirectory()
    }

    // MARK: - Navigation

    func navigate(to path: String) {
        if state.historyIndex < state.history.count - 1 {
            state.history = Array(state.history.prefix(state.historyIndex + 1))
        }
        state.history.append(path)
        state.historyIndex = state.history.count - 1
        state.path = path
        state.selectedFiles.removeAll()
        state.searchQuery = ""
        state.error = nil
        loadDirectory()
    }

    func goBack() -> Bool {
        guard state.historyIndex > 0 else { return false }
        state.historyIndex -= 1
        state.path = state.history[state.historyIndex]
        state.selectedFiles.removeAll()
        state.searchQuery = ""
        state.error = nil
        loadDirectory()
        return true
    }

    func goForward() -> Bool {
        guard state.historyIndex < state.history.count - 1 else { return false }
        state.historyIndex += 1
        state.path = state.history[state.historyIndex]
        state.selectedFiles.removeAll()
        state.searchQuery = ""
        state.error = nil
        loadDirectory()
        return true
    }

    func goUp() {
        guard !state.path.isEmpty else { return }
        let parentPath = (state.path as NSString).deletingLastPathComponent
        guard parentPath != state.path else { return }
        navigate(to: parentPath)
    }

    func refresh() {
        loadDirectory()
    }

    // MARK: - Selection (有序数组)

    func selectFile(_ file: FileEntry, multi: Bool = false, shiftKey: Bool = false) {
        if shiftKey, let lastSelected = state.selectedFiles.last {
            if let startIndex = state.files.firstIndex(where: { $0.path == lastSelected.path }),
               let endIndex = state.files.firstIndex(where: { $0.path == file.path }) {
                let range = min(startIndex, endIndex)...max(startIndex, endIndex)
                state.selectedFiles = Array(state.files[range])
            }
        } else if multi {
            if let idx = state.selectedFiles.firstIndex(where: { $0.path == file.path }) {
                state.selectedFiles.remove(at: idx)
            } else {
                state.selectedFiles.append(file)
            }
        } else {
            state.selectedFiles = [file]
        }
    }

    func clearSelection() {
        state.selectedFiles.removeAll()
    }

    func selectAll() {
        state.selectedFiles = state.files
    }

    /// 通过路径选择文件（用于 NSTableView 行选择回调）
    func selectByPath(_ path: String, multi: Bool = false, shiftKey: Bool = false) {
        guard let entry = state.files.first(where: { $0.path == path }) else { return }
        selectFile(entry, multi: multi, shiftKey: shiftKey)
    }

    // MARK: - Sorting & Filtering

    func setSortField(_ field: SortField, ascending: Bool? = nil) {
        state.sortField = field
        if let asc = ascending { state.sortAscending = asc }
        applySort()
    }

    func toggleSortDirection() {
        state.sortAscending.toggle()
        applySort()
    }

    func setGroupBy(_ groupBy: String) {
        state.groupBy = groupBy
        applySort()
    }

    func setSearchQuery(_ query: String) {
        state.searchQuery = query
        if query.isEmpty {
            loadDirectory()
        } else {
            applyFilter()
        }
    }

    func setViewMode(_ mode: ViewMode) {
        state.viewMode = mode
    }

    // MARK: - File Operations

    func deleteSelected() {
        let toDelete = state.selectedFiles
        guard !toDelete.isEmpty else { return }

        // 使用 FileManager.trashItem 移到废纸篓（与 macOS Finder 行为一致），
        // 并保留 trashURL 用于撤销时恢复。trashItem 必须在主线程调用，
        // deleteSelected 由菜单/右键菜单触发，已在主线程。
        var trashedItems: [(originalPath: String, trashURL: URL)] = []
        var failedCount = 0

        for entry in toDelete {
            let url = URL(fileURLWithPath: entry.path)
            do {
                var resultingURL: NSURL?
                try FileManager.default.trashItem(at: url, resultingItemURL: &resultingURL)
                if let trashURL = resultingURL as URL? {
                    trashedItems.append((originalPath: entry.path, trashURL: trashURL))
                }
            } catch {
                failedCount += 1
            }
        }

        if !trashedItems.isEmpty {
            // 失效缓存以反映删除（best-effort，缓存错误不阻塞 UI）
            let parentDir = (trashedItems[0].originalPath as NSString).deletingLastPathComponent
            try? CoreBridge.shared.invalidateCache(path: parentDir)

            // 注册撤销：从废纸篓恢复（moveItem 回原路径）
            let items = trashedItems
            let originalDir = items.first.map { ($0.originalPath as NSString).deletingLastPathComponent } ?? ""
            undoManager?.registerUndo(withTarget: self) { vm in
                var restoreFailed = 0
                for (originalPath, trashURL) in items {
                    do {
                        try FileManager.default.moveItem(at: trashURL, to: URL(fileURLWithPath: originalPath))
                    } catch {
                        // I3: 原路径已被占用等原因导致恢复失败，记录并反馈
                        restoreFailed += 1
                    }
                }
                // 失效缓存以反映恢复
                if let firstPath = items.first?.originalPath {
                    let dir = (firstPath as NSString).deletingLastPathComponent
                    try? CoreBridge.shared.invalidateCache(path: dir)
                }
                // 注册 redo：重新移入废纸篓
                vm.undoManager?.registerUndo(withTarget: vm) { vm2 in
                    for (originalPath, _) in items {
                        try? FileManager.default.trashItem(at: URL(fileURLWithPath: originalPath), resultingItemURL: nil)
                    }
                    vm2.loadDirectory()
                }
                vm.undoManager?.setActionName("删除 \(items.count) 个项目")
                if restoreFailed > 0 {
                    vm.state.error = "\(restoreFailed) 个项目无法恢复（原路径已被占用）"
                }
                // I4: 仅当 VM 仍在原目录时才刷新（用户可能已导航离开），
                // 文件已恢复到原位置，用户导航回去后自然可见。
                if vm.state.path == originalDir {
                    vm.loadDirectory()
                }
            }
            undoManager?.setActionName("删除 \(trashedItems.count) 个项目")

            state.selectedFiles.removeAll()
            loadDirectory()
        }

        if failedCount > 0 {
            state.error = "\(failedCount) 个项目删除失败"
        }
    }

    func renameFile(_ oldPath: String, to newName: String) {
        let dir = (oldPath as NSString).deletingLastPathComponent
        let newPath = (dir as NSString).appendingPathComponent(newName)
        do {
            try CoreBridge.shared.renameFile(src: oldPath, dst: newPath)
            // 注册撤销：undo 闭包内调用 renameFile 反向重命名，
            // NSUndoManager 在 undo 模式下会将 registerUndo 加入 redo 栈，
            // 因此 redo 自动支持，且不会无限递归。
            let oldName = (oldPath as NSString).lastPathComponent
            undoManager?.registerUndo(withTarget: self) { vm in
                vm.renameFile(newPath, to: oldName)
            }
            undoManager?.setActionName("重命名")
            loadDirectory()
        } catch {
            state.error = error.localizedDescription
        }
    }

    func createDirectory() {
        let newDirName = "未命名文件夹"
        let newDirPath = (state.path as NSString).appendingPathComponent(newDirName)
        do {
            try CoreBridge.shared.createDirectory(path: newDirPath)
            loadDirectory()
        } catch {
            state.error = error.localizedDescription
        }
    }

    // MARK: - Private

    private func loadDirectory() {
        guard !state.path.isEmpty else { return }
        state.isLoading = true
        state.error = nil

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            do {
                let entries = try CoreBridge.shared.listDirectory(path: self.state.path)
                // 在后台线程完成排序，避免阻塞 UI
                let sortedEntries = self.sortEntries(entries)
                DispatchQueue.main.async {
                    self.state.files = sortedEntries
                    self.state.isLoading = false
                }
            } catch {
                DispatchQueue.main.async {
                    self.state.error = error.localizedDescription
                    self.state.isLoading = false
                }
            }
        }
    }

    /// 在后台线程排序（不触发 @Published 变更）
    private func sortEntries(_ entries: [FileEntry]) -> [FileEntry] {
        let field = state.sortField
        let ascending = state.sortAscending
        return entries.sorted { a, b in
            let comparison: Bool
            switch field {
            case .name:
                comparison = a.sortName.localizedCaseInsensitiveCompare(b.sortName) == .orderedAscending
            case .modifiedAt:
                comparison = a.modificationDate < b.modificationDate
            case .type:
                comparison = a.fileExtension.localizedCaseInsensitiveCompare(b.fileExtension) == .orderedAscending
            case .size:
                comparison = a.size < b.size
            }
            return ascending ? comparison : !comparison
        }
    }

    private func applySort() {
        let sorted = sortEntries(state.files)
        // 仅在顺序实际变化时才更新（减少不必要的 reloadData）
        if sorted.map(\.path) != state.files.map(\.path) {
            state.files = sorted
        }
    }

    private func applyFilter() {
        guard !state.searchQuery.isEmpty else {
            loadDirectory()
            return
        }
        let query = state.searchQuery.lowercased()
        state.files = state.files.filter { $0.name.lowercased().contains(query) }
    }
}
