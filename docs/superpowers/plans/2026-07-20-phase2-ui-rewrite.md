# Phase 2: 主窗口 + 双面板 + 文件列表重写

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 重写数据模型和主窗口 UI 层，实现可工作的双面板文件浏览器

**Architecture:** 保留 Phase 1 的 Rust Core + Bridge 层，重写 Swift UI 层的 4 个核心文件（FileEntry / PaneState / PaneToolbar / FileListView）+ MainWindowController。每个文件独立重写，通过语法检查验证，最终集成编译。

**Tech Stack:** Swift 6 / AppKit / NSTableView / NSSplitView / Combine

## Global Constraints

- macOS only (Swift & AppKit, no SwiftUI)
- 列视图列顺序：名称 → 修改日期 → 类型 → 大小（匹配 macOS Finder）
- 面板工具栏为单行紧凑布局（非双行）
- 面包屑路径可点击跳转
- 排序/分组用 NSPopUpButton（非 NSButton+menu）
- 视图切换按钮互斥选中
- 文件列表支持多选（Cmd+点击 / Shift+范围）
- 列头点击排序
- 全局 `user-select: none`（通过 NSTableView 行为实现）
- 隐藏文件显示为灰色文字
- 系统保护文件显示为红色文字
- 右键菜单不使用 NSOpenPanel/NSSavePanel（用 in-app 对话框）
- 语法检查命令：`swiftc -parse <file>.swift`

---

## File Structure

| 文件 | 操作 | 职责 |
|------|------|------|
| `Model/FileEntry.swift` | 重写 | 文件条目数据模型（id=path，新增 isHidden/isSymlink/creationDate/tags） |
| `Model/PaneState.swift` | 重写 | 面板状态 + PaneViewModel（有序选择数组，修复 sort/filter） |
| `Model/FileEntryViewModel.swift` | 删除 | 合并到 PaneViewModel，消除重复 |
| `UI/PaneToolbar.swift` | 重写 | 单行工具栏（面包屑+搜索+排序+分组+视图切换） |
| `UI/FileListView.swift` | 重写 | 4 列 NSTableView + 多选 + 列头排序 + 拖拽源 |
| `UI/MainWindowController.swift` | 重写 | 修复约束 bug + 活跃面板 + DetailsBar 绑定 |

---

## Task 1: 重写 FileEntry.swift

**Files:**
- Modify: `FlowFinderNative/FlowFinderNative/Model/FileEntry.swift`

**Interfaces:**
- Produces: `FileEntry.id` (改为 path)
- Produces: `FileEntry.isHidden: Bool`
- Produces: `FileEntry.isSymlink: Bool`
- Produces: `FileEntry.isSystemProtected: Bool`
- Produces: `FileEntry.creationDate: Date`
- Produces: `FileEntry.tags: [Tag]`
- Produces: `FileEntry.init(from: FFEntryRef)` 读取全部字段

- [ ] **Step 1: 重写 FileEntry.swift**

完整替换 `FlowFinderNative/FlowFinderNative/Model/FileEntry.swift`：

```swift
import Foundation

/// Represents a file or directory entry in the file system
public struct FileEntry: Identifiable, Equatable, Hashable {
    public var id: String { path }
    public let path: String
    public let name: String
    public let isDirectory: Bool
    public let isFile: Bool
    public let isSymlink: Bool
    public let isHidden: Bool
    public let isSystemProtected: Bool
    public let size: UInt64
    public let modificationDate: Date
    public let creationDate: Date
    public var tags: [Tag]

    /// File extension derived from the name (if any)
    public var fileExtension: String {
        let url = URL(fileURLWithPath: name)
        return url.pathExtension.lowercased()
    }

    /// Display name (name without extension for files)
    public var displayName: String {
        if isDirectory { return name }
        let url = URL(fileURLWithPath: name)
        return url.deletingPathExtension().lastPathComponent
    }

    /// Human-readable file kind description
    public var kindDescription: String {
        if isDirectory { return "文件夹" }
        let ext = fileExtension
        let kinds: [String: String] = [
            "jpg": "JPEG 图像", "jpeg": "JPEG 图像", "png": "PNG 图像",
            "gif": "GIF 图像", "pdf": "PDF 文档", "txt": "纯文本",
            "md": "Markdown", "html": "HTML", "css": "CSS",
            "js": "JavaScript", "json": "JSON", "xml": "XML",
            "zip": "ZIP 压缩包", "mp3": "MP3 音频", "mp4": "MP4 视频",
            "mov": "QuickTime 视频", "doc": "Word 文档", "docx": "Word 文档",
            "xls": "Excel 表格", "xlsx": "Excel 表格",
            "ppt": "PowerPoint", "pptx": "PowerPoint",
            "app": "应用程序", "dmg": "磁盘映像",
        ]
        return kinds[ext] ?? (ext.isEmpty ? "文件" : "\(ext.uppercased()) 文件")
    }

    /// Initialize from FFI reference
    public init(from ref: FFEntryRef) {
        self.path = String(cString: ref.path)
        self.name = String(cString: ref.name)
        self.isDirectory = ref.isDir
        self.isFile = ref.isFile
        self.isSymlink = ref.isSymlink
        self.isHidden = ref.isHidden
        self.isSystemProtected = ref.isSystemProtected
        self.size = ref.size
        self.modificationDate = Date(timeIntervalSince1970: TimeInterval(ref.modified))
        self.creationDate = Date(timeIntervalSince1970: TimeInterval(ref.created))
        self.tags = []
    }

    /// Convenience initializer
    public init(
        path: String, name: String, isDirectory: Bool, isFile: Bool = true,
        isSymlink: Bool = false, isHidden: Bool = false, isSystemProtected: Bool = false,
        size: UInt64 = 0, modificationDate: Date = Date(), creationDate: Date = Date(),
        tags: [Tag] = []
    ) {
        self.path = path
        self.name = name
        self.isDirectory = isDirectory
        self.isFile = isFile
        self.isSymlink = isSymlink
        self.isHidden = isHidden
        self.isSystemProtected = isSystemProtected
        self.size = size
        self.modificationDate = modificationDate
        self.creationDate = creationDate
        self.tags = tags
    }

    /// Formatted file size string (e.g., "1.5 MB", "4 KB", "0 bytes")
    public var formattedSize: String {
        guard !isDirectory else { return "--" }
        let byteCountFormatter = ByteCountFormatter()
        byteCountFormatter.allowedUnits = [.useBytes, .useKB, .useMB, .useGB, .useTB]
        byteCountFormatter.countStyle = .file
        return byteCountFormatter.string(fromByteCount: Int64(size))
    }

    /// Formatted modification date string
    public var formattedModificationDate: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: modificationDate)
    }

    /// Formatted creation date string
    public var formattedCreationDate: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: creationDate)
    }

    /// Sort-friendly name (directories first, then alphabetically)
    public var sortName: String {
        return isDirectory ? "0_\(name.lowercased())" : "1_\(name.lowercased())"
    }
}
```

- [ ] **Step 2: 语法检查**

Run: `cd /Volumes/Iris-Data/Download/AI/文件管理系统/flowfinder-native/FlowFinderNative/FlowFinderNative/Model && swiftc -parse FileEntry.swift 2>&1 | head -5`
Expected: 无输出（无错误）

- [ ] **Step 3: 提交**

```bash
cd /Volumes/Iris-Data/Download/AI/文件管理系统/flowfinder-native
git add FlowFinderNative/FlowFinderNative/Model/FileEntry.swift
git commit -m "refactor: 重写 FileEntry 数据模型

- id 改为 path（消除 UUID 重复）
- 新增 isHidden/isSymlink/isSystemProtected/creationDate/tags 字段
- init(from: FFEntryRef) 读取全部 FFI 字段
- kindDescription 改为中文"
```

---

## Task 2: 重写 PaneState.swift + 删除 FileEntryViewModel.swift

**Files:**
- Modify: `FlowFinderNative/FlowFinderNative/Model/PaneState.swift`
- Delete: `FlowFinderNative/FlowFinderNative/Model/FileEntryViewModel.swift`

**Interfaces:**
- Consumes: `FileEntry` (Task 1), `CoreBridge.shared.listDirectory(path:)`
- Produces: `PaneViewModel` with `@Published state: PaneState`
- Produces: `PaneState.selectedFiles: [FileEntry]` (有序数组)
- Produces: `PaneViewModel.selectFile(_:multi:shiftKey:)` 修改为有序数组
- Produces: `PaneViewModel.selectedEntries: [FileEntry]` 计算属性

- [ ] **Step 1: 重写 PaneState.swift**

完整替换 `FlowFinderNative/FlowFinderNative/Model/PaneState.swift`：

```swift
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
        do {
            for entry in toDelete {
                if entry.isDirectory {
                    try CoreBridge.shared.deleteDirectory(path: entry.path)
                } else {
                    try CoreBridge.shared.deleteFile(path: entry.path)
                }
            }
            state.selectedFiles.removeAll()
            loadDirectory()
        } catch {
            state.error = error.localizedDescription
        }
    }

    func renameFile(_ oldPath: String, to newName: String) {
        let dir = (oldPath as NSString).deletingLastPathComponent
        let newPath = (dir as NSString).appendingPathComponent(newName)
        do {
            try CoreBridge.shared.renameFile(src: oldPath, dst: newPath)
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
                DispatchQueue.main.async {
                    self.state.files = entries
                    self.state.isLoading = false
                    self.applySort()
                }
            } catch {
                DispatchQueue.main.async {
                    self.state.error = error.localizedDescription
                    self.state.isLoading = false
                }
            }
        }
    }

    private func applySort() {
        let field = state.sortField
        let ascending = state.sortAscending

        state.files.sort { a, b in
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

    private func applyFilter() {
        guard !state.searchQuery.isEmpty else {
            loadDirectory()
            return
        }
        let query = state.searchQuery.lowercased()
        state.files = state.files.filter { $0.name.lowercased().contains(query) }
    }
}
```

- [ ] **Step 2: 删除 FileEntryViewModel.swift**

```bash
cd /Volumes/Iris-Data/Download/AI/文件管理系统/flowfinder-native
rm FlowFinderNative/FlowFinderNative/Model/FileEntryViewModel.swift
```

- [ ] **Step 3: 语法检查**

Run: `cd /Volumes/Iris-Data/Download/AI/文件管理系统/flowfinder-native/FlowFinderNative/FlowFinderNative/Model && swiftc -parse PaneState.swift 2>&1 | head -5`
Expected: 无输出（无错误）

- [ ] **Step 4: 提交**

```bash
cd /Volumes/Iris-Data/Download/AI/文件管理系统/flowfinder-native
git add -A FlowFinderNative/FlowFinderNative/Model/
git commit -m "refactor: 重写 PaneState + 删除 FileEntryViewModel

- selectedFiles 改为有序 [FileEntry] 数组（支持 Shift 范围选择）
- 新增 SortField/ViewMode 枚举替代字符串
- 修复 applyFilter 丢失原始数据 bug（改为从 loadDirectory 重载）
- 新增 selectedEntries 计算属性 / selectByPath 方法
- 删除重复的 FileEntryViewModel（功能合并到 PaneViewModel）"
```

---

## Task 3: 重写 PaneToolbar.swift

**Files:**
- Modify: `FlowFinderNative/FlowFinderNative/UI/PaneToolbar.swift`

**Interfaces:**
- Consumes: `SortField` (Task 2), `ViewMode` (Task 2)
- Produces: `PaneToolbarDelegate` 协议（新增 sortField: SortField, viewMode: ViewMode 参数类型）
- Produces: `PaneToolbar.setPath(_:)` / `setCanGoBack(_:)` / `setCanGoForward(_:)`
- Produces: 面包屑点击跳转回调 `paneToolbar(_:didClickPath:)`

- [ ] **Step 1: 重写 PaneToolbar.swift**

完整替换 `FlowFinderNative/FlowFinderNative/UI/PaneToolbar.swift`：

```swift
import Cocoa
import Combine

// MARK: - PaneToolbarDelegate

protocol PaneToolbarDelegate: AnyObject {
    func paneToolbarDidClickBack(_ toolbar: PaneToolbar)
    func paneToolbarDidClickForward(_ toolbar: PaneToolbar)
    func paneToolbarDidClickUp(_ toolbar: PaneToolbar)
    func paneToolbarDidClickRefresh(_ toolbar: PaneToolbar)
    func paneToolbar(_ toolbar: PaneToolbar, didChangeSearchQuery query: String)
    func paneToolbar(_ toolbar: PaneToolbar, didChangeSortField field: SortField, ascending: Bool)
    func paneToolbar(_ toolbar: PaneToolbar, didChangeGroupBy groupBy: String)
    func paneToolbar(_ toolbar: PaneToolbar, didChangeViewMode mode: ViewMode)
    func paneToolbar(_ toolbar: PaneToolbar, didClickPath path: String)
}

// MARK: - PaneToolbar

class PaneToolbar: NSView {
    weak var delegate: PaneToolbarDelegate?

    private var path: String = ""
    private var cancellables = Set<AnyCancellable>()

    // UI Components
    private var backButton: NSButton!
    private var forwardButton: NSButton!
    private var upButton: NSButton!
    private var refreshButton: NSButton!
    private var breadcrumbStack: NSStackView!
    private var searchField: NSSearchField!
    private var sortPopup: NSPopUpButton!
    private var sortDirectionButton: NSButton!
    private var groupPopup: NSPopUpButton!
    private var listViewButton: NSButton!
    private var gridViewButton: NSButton!

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupUI()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupUI()
    }

    private func setupUI() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor

        // Navigation buttons
        backButton = createIconButton(imageName: NSImage.goBackTemplateName, action: #selector(backClicked))
        forwardButton = createIconButton(imageName: NSImage.goForwardTemplateName, action: #selector(forwardClicked))
        upButton = createIconButton(systemSymbol: "chevron.up", action: #selector(upClicked))
        refreshButton = createIconButton(imageName: NSImage.refreshTemplateName, action: #selector(refreshClicked))

        // Breadcrumb (clickable segments)
        breadcrumbStack = NSStackView()
        breadcrumbStack.orientation = .horizontal
        breadcrumbStack.alignment = .centerY
        breadcrumbStack.spacing = 2
        breadcrumbStack.detachesHiddenViews = false
        breadcrumbStack.translatesAutoresizingMaskIntoConstraints = false

        // Search
        searchField = NSSearchField()
        searchField.placeholderString = "搜索当前目录"
        searchField.target = self
        searchField.action = #selector(searchChanged)
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.widthAnchor.constraint(equalToConstant: 180).isActive = true

        // Sort popup
        sortPopup = NSPopUpButton()
        sortPopup.addItems(withTitles: SortField.allCases.map { $0.rawValue })
        sortPopup.target = self
        sortPopup.action = #selector(sortSelected(_:))
        sortPopup.translatesAutoresizingMaskIntoConstraints = false

        // Sort direction toggle
        sortDirectionButton = NSButton()
        sortDirectionButton.image = NSImage(systemSymbolName: "chevron.up", accessibilityDescription: "升序")
        sortDirectionButton.bezelStyle = .texturedRounded
        sortDirectionButton.target = self
        sortDirectionButton.action = #selector(sortDirectionToggled)
        sortDirectionButton.translatesAutoresizingMaskIntoConstraints = false

        // Group popup
        groupPopup = NSPopUpButton()
        groupPopup.addItems(withTitles: ["无分组", "按种类", "按日期", "按大小"])
        groupPopup.target = self
        groupPopup.action = #selector(groupSelected(_:))
        groupPopup.translatesAutoresizingMaskIntoConstraints = false

        // View mode buttons (mutually exclusive)
        listViewButton = createIconButton(imageName: NSImage.listViewTemplateName, action: #selector(listViewClicked))
        listViewButton.image = NSImage(systemSymbolName: "list.bullet", accessibilityDescription: "列表视图")
        gridViewButton = createIconButton(imageName: NSImage.iconViewTemplateName, action: #selector(gridViewClicked))
        gridViewButton.image = NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: "网格视图")

        // Set initial view mode highlight
        updateViewModeHighlight(.list)

        // Layout: single row
        let mainStack = NSStackView(views: [
            backButton, forwardButton, upButton, refreshButton,
            breadcrumbStack,
            searchField,
            sortPopup, sortDirectionButton,
            groupPopup,
            listViewButton, gridViewButton,
        ])
        mainStack.orientation = .horizontal
        mainStack.alignment = .centerY
        mainStack.spacing = 4
        mainStack.detachesHiddenViews = false
        mainStack.translatesAutoresizingMaskIntoConstraints = false

        // Make breadcrumb flexible
        mainStack.setHuggingPriority(.defaultLow, for: .horizontal)
        breadcrumbStack.setHuggingPriority(.defaultLow, for: .horizontal)
        searchField.setHuggingPriority(.defaultHigh, for: .horizontal)

        addSubview(mainStack)

        NSLayoutConstraint.activate([
            mainStack.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            mainStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            mainStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            mainStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
    }

    private func createIconButton(imageName: String, action: Selector) -> NSButton {
        let button = NSButton()
        button.image = NSImage(named: imageName) ?? NSImage()
        button.bezelStyle = .texturedRounded
        button.imagePosition = .imageOnly
        button.target = self
        button.action = action
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }

    private func createIconButton(systemSymbol: String, action: Selector) -> NSButton {
        let button = NSButton()
        button.image = NSImage(systemSymbolName: systemSymbol, accessibilityDescription: nil) ?? NSImage()
        button.bezelStyle = .texturedRounded
        button.imagePosition = .imageOnly
        button.target = self
        button.action = action
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }

    // MARK: - Public API

    func setPath(_ path: String) {
        self.path = path
        // Rebuild breadcrumb segments
        breadcrumbStack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        let segments = path.split(separator: "/").map(String.init)
        var accumulatedPath = ""

        // Root button
        let rootButton = createBreadcrumbButton(title: "Macintosh HD", path: "/")
        breadcrumbStack.addArrangedSubview(rootButton)

        for segment in segments {
            accumulatedPath += "/" + segment
            // Separator
            let sep = NSTextField(labelWithString: "›")
            sep.textColor = NSColor.secondaryLabelColor
            sep.translatesAutoresizingMaskIntoConstraints = false
            breadcrumbStack.addArrangedSubview(sep)

            let btn = createBreadcrumbButton(title: segment, path: accumulatedPath)
            breadcrumbStack.addArrangedSubview(btn)
        }
    }

    private func createBreadcrumbButton(title: String, path: String) -> NSButton {
        let button = NSButton()
        button.title = title
        button.isBordered = false
        button.bezelStyle = .inline
        button.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        button.target = self
        button.action = #selector(breadcrumbClicked(_:))
        button.translatesAutoresizingMaskIntoConstraints = false
        // Store path in identifier
        button.identifier = NSUserInterfaceItemIdentifier(path)
        return button
    }

    func setCanGoBack(_ canGoBack: Bool) {
        backButton.isEnabled = canGoBack
    }

    func setCanGoForward(_ canGoForward: Bool) {
        forwardButton.isEnabled = canGoForward
    }

    func setViewMode(_ mode: ViewMode) {
        updateViewModeHighlight(mode)
    }

    private func updateViewModeHighlight(_ mode: ViewMode) {
        listViewButton.highlight(mode == .list)
        gridViewButton.highlight(mode == .grid)
    }

    // MARK: - Actions

    @objc private func backClicked() { delegate?.paneToolbarDidClickBack(self) }
    @objc private func forwardClicked() { delegate?.paneToolbarDidClickForward(self) }
    @objc private func upClicked() { delegate?.paneToolbarDidClickUp(self) }
    @objc private func refreshClicked() { delegate?.paneToolbarDidClickRefresh(self) }

    @objc private func searchChanged() {
        delegate?.paneToolbar(self, didChangeSearchQuery: searchField.stringValue)
    }

    @objc private func sortSelected(_ sender: NSPopUpButton) {
        guard let title = sender.titleOfSelectedItem,
              let field = SortField(rawValue: title) else { return }
        delegate?.paneToolbar(self, didChangeSortField: field, ascending: sortDirectionButton.image == NSImage(systemSymbolName: "chevron.up", accessibilityDescription: nil))
    }

    @objc private func sortDirectionToggled() {
        let isAscending = sortDirectionButton.image == NSImage(systemSymbolName: "chevron.up", accessibilityDescription: nil)
        sortDirectionButton.image = NSImage(systemSymbolName: isAscending ? "chevron.down" : "chevron.up", accessibilityDescription: isAscending ? "降序" : "升序")

        guard let title = sortPopup.titleOfSelectedItem,
              let field = SortField(rawValue: title) else { return }
        delegate?.paneToolbar(self, didChangeSortField: field, ascending: !isAscending)
    }

    @objc private func groupSelected(_ sender: NSPopUpButton) {
        let groupBy: String
        switch sender.titleOfSelectedItem {
        case "无分组": groupBy = "none"
        case "按种类": groupBy = "kind"
        case "按日期": groupBy = "date"
        case "按大小": groupBy = "size"
        default: groupBy = "none"
        }
        delegate?.paneToolbar(self, didChangeGroupBy: groupBy)
    }

    @objc private func listViewClicked() {
        updateViewModeHighlight(.list)
        delegate?.paneToolbar(self, didChangeViewMode: .list)
    }

    @objc private func gridViewClicked() {
        updateViewModeHighlight(.grid)
        delegate?.paneToolbar(self, didChangeViewMode: .grid)
    }

    @objc private func breadcrumbClicked(_ sender: NSButton) {
        guard let path = sender.identifier?.rawValue else { return }
        delegate?.paneToolbar(self, didClickPath: path)
    }
}
```

- [ ] **Step 2: 语法检查**

Run: `cd /Volumes/Iris-Data/Download/AI/文件管理系统/flowfinder-native/FlowFinderNative/FlowFinderNative/UI && swiftc -parse PaneToolbar.swift 2>&1 | head -5`
Expected: 无输出（无错误）

- [ ] **Step 3: 提交**

```bash
cd /Volumes/Iris-Data/Download/AI/文件管理系统/flowfinder-native
git add FlowFinderNative/FlowFinderNative/UI/PaneToolbar.swift
git commit -m "refactor: 重写 PaneToolbar 工具栏

- 单行紧凑布局（替代双行）
- 面包屑可点击跳转（每段路径为独立按钮）
- 排序/分组改用 NSPopUpButton
- 新增排序方向切换按钮
- 视图切换按钮互斥高亮
- delegate 接口参数类型改为 SortField/ViewMode 枚举"
```

---

## Task 4: 重写 FileListView.swift

**Files:**
- Modify: `FlowFinderNative/FlowFinderNative/UI/FileListView.swift`

**Interfaces:**
- Consumes: `FileEntry` (Task 1), `PaneViewModel` (Task 2)
- Produces: `FileListView.viewModel: PaneViewModel?`
- Produces: `FileListView.onDoubleClick: ((FileEntry) -> Void)?`
- Produces: `FileListView.onSelectionChanged: (([FileEntry]) -> Void)?`
- Produces: 列顺序：名称 → 修改日期 → 类型 → 大小
- Produces: 多选 + 列头排序 + 拖拽源

- [ ] **Step 1: 重写 FileListView.swift**

完整替换 `FlowFinderNative/FlowFinderNative/UI/FileListView.swift`：

```swift
import Cocoa
import Combine

// MARK: - FileListView

/// NSTableView-based file list view with 4 columns (名称/修改日期/类型/大小)
public class FileListView: NSView {
    private var tableView: NSTableView!
    private var scrollView: NSScrollView!
    private var cancellables = Set<AnyCancellable>()

    public var viewModel: PaneViewModel? {
        didSet {
            tableView.dataSource = self
            tableView.delegate = self
            viewModel?.$state
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.reloadData() }
                .store(in: &cancellables)
            reloadData()
        }
    }

    public var onDoubleClick: ((FileEntry) -> Void)?
    public var onSelectionChanged: (([FileEntry]) -> Void)?

    // Reuse identifiers
    private let nameCellID = NSUserInterfaceItemIdentifier("NameCell")
    private let modifiedCellID = NSUserInterfaceItemIdentifier("ModifiedCell")
    private let typeCellID = NSUserInterfaceItemIdentifier("TypeCell")
    private let sizeCellID = NSUserInterfaceItemIdentifier("SizeCell")

    // Icons
    private lazy var folderIcon: NSImage? = {
        NSImage(systemSymbolName: "folder", accessibilityDescription: "文件夹")
            ?? NSImage(named: NSImage.folderName)
    }()
    private lazy var fileIcon: NSImage? = {
        NSImage(systemSymbolName: "doc", accessibilityDescription: "文件")
            ?? NSImage(named: NSImage.multipleDocumentsName)
    }()

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupUI()
        setupContextMenu()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupUI()
        setupContextMenu()
    }

    // MARK: - UI Setup

    private func setupUI() {
        scrollView = NSScrollView(frame: bounds)
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true

        tableView = NSTableView()
        tableView.allowsMultipleSelection = true
        tableView.allowsEmptySelection = true
        tableView.allowsColumnReordering = false
        tableView.allowsColumnResizing = true
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.rowHeight = 24
        tableView.dataSource = self
        tableView.delegate = self

        // 列顺序：名称 → 修改日期 → 类型 → 大小（匹配 macOS Finder）
        // 名称列（带图标）
        let nameCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        nameCol.title = "名称"
        nameCol.width = 300
        nameCol.minWidth = 120
        nameCol.resizingMask = [.userResizingMask, .autoresizingMask]
        nameCol.sortDescriptorPrototype = NSSortDescriptor(key: "name", ascending: true)
        tableView.addTableColumn(nameCol)

        // 修改日期列
        let modifiedCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("modifiedAt"))
        modifiedCol.title = "修改日期"
        modifiedCol.width = 160
        modifiedCol.minWidth = 100
        modifiedCol.resizingMask = [.userResizingMask, .autoresizingMask]
        modifiedCol.sortDescriptorPrototype = NSSortDescriptor(key: "modifiedAt", ascending: true)
        tableView.addTableColumn(modifiedCol)

        // 类型列
        let typeCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("type"))
        typeCol.title = "类型"
        typeCol.width = 120
        typeCol.minWidth = 80
        typeCol.resizingMask = [.userResizingMask, .autoresizingMask]
        typeCol.sortDescriptorPrototype = NSSortDescriptor(key: "type", ascending: true)
        tableView.addTableColumn(typeCol)

        // 大小列
        let sizeCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("size"))
        sizeCol.title = "大小"
        sizeCol.width = 100
        sizeCol.minWidth = 60
        sizeCol.resizingMask = [.userResizingMask, .autoresizingMask]
        sizeCol.sortDescriptorPrototype = NSSortDescriptor(key: "size", ascending: true)
        tableView.addTableColumn(sizeCol)

        // Double-click
        tableView.target = self
        tableView.doubleAction = #selector(handleDoubleClick)

        scrollView.documentView = tableView
        addSubview(scrollView)
    }

    // MARK: - Context Menu (in-app dialog, no NSOpenPanel/NSSavePanel)

    private func setupContextMenu() {
        let menu = NSMenu()

        menu.addItem(withTitle: "打开", action: #selector(openSelected(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "复制", action: #selector(copySelected(_:)), keyEquivalent: "c")
        menu.addItem(withTitle: "剪切", action: #selector(cutSelected(_:)), keyEquivalent: "x")
        menu.addItem(withTitle: "粘贴", action: #selector(pasteSelected(_:)), keyEquivalent: "v")
        menu.addItem(.separator())
        menu.addItem(withTitle: "重命名", action: #selector(renameSelected(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "删除", action: #selector(deleteSelected(_:)), keyEquivalent: "\u{7F}")
        menu.addItem(.separator())
        menu.addItem(withTitle: "新建文件夹", action: #selector(createDirectory(_:)), keyEquivalent: "n")

        for item in menu.items where item.action != nil {
            item.target = self
            if item.keyEquivalent == "n" {
                item.keyEquivalentModifierMask = [.command, .shift]
            } else if !item.keyEquivalent.isEmpty {
                item.keyEquivalentModifierMask = .command
            }
        }
        tableView.menu = menu
    }

    // MARK: - Context Menu Actions

    @objc private func openSelected(_ sender: Any?) {
        guard let entry = clickedEntry else { return }
        if entry.isDirectory {
            onDoubleClick?(entry)
        } else {
            NSWorkspace.shared.openFile(entry.path)
        }
    }

    @objc private func copySelected(_ sender: Any?) {
        // 剪贴板操作将由 MainWindowController 统一管理
        NotificationCenter.default.post(name: .fileListDidCopy, object: nil, userInfo: ["side": getSide()])
    }

    @objc private func cutSelected(_ sender: Any?) {
        NotificationCenter.default.post(name: .fileListDidCut, object: nil, userInfo: ["side": getSide()])
    }

    @objc private func pasteSelected(_ sender: Any?) {
        NotificationCenter.default.post(name: .fileListDidPaste, object: nil, userInfo: ["side": getSide()])
    }

    @objc private func renameSelected(_ sender: Any?) {
        guard let entry = clickedEntry else { return }
        let alert = NSAlert()
        alert.messageText = "重命名 \"\(entry.name)\""
        alert.informativeText = "输入新名称："
        alert.alertStyle = .informational
        alert.addButton(withTitle: "重命名")
        alert.addButton(withTitle: "取消")
        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        textField.stringValue = entry.name
        alert.accessoryView = textField
        alert.beginSheetModal(for: window!) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            let newName = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !newName.isEmpty, newName != entry.name else { return }
            self?.viewModel?.renameFile(entry.path, to: newName)
        }
    }

    @objc private func deleteSelected(_ sender: Any?) {
        let entries = viewModel?.selectedFiles ?? []
        guard !entries.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = entries.count == 1 ? "删除\"\(entries[0].name)\"？" : "删除 \(entries.count) 个项目？"
        alert.informativeText = "此操作无法撤销。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: window!) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.viewModel?.deleteSelected()
        }
    }

    @objc private func createDirectory(_ sender: Any?) {
        guard let currentPath = viewModel?.currentPath else { return }
        let alert = NSAlert()
        alert.messageText = "新建文件夹"
        alert.informativeText = "输入文件夹名称："
        alert.alertStyle = .informational
        alert.addButton(withTitle: "创建")
        alert.addButton(withTitle: "取消")
        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        textField.stringValue = "未命名文件夹"
        textField.selectText(nil)
        alert.accessoryView = textField
        alert.beginSheetModal(for: window!) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            let folderName = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !folderName.isEmpty else { return }
            let newPath = (currentPath as NSString).appendingPathComponent(folderName)
            do {
                try CoreBridge.shared.createDirectory(path: newPath)
                self?.viewModel?.refresh()
            } catch {
                self?.showError(error: error)
            }
        }
    }

    // MARK: - Helpers

    private var clickedEntry: FileEntry? {
        guard let viewModel = viewModel,
              let row = tableView.clickedRow as Int?,
              row >= 0, row < viewModel.files.count else { return nil }
        return viewModel.files[row]
    }

    private func getSide() -> String {
        // 由 MainWindowController 在设置 viewModel 时通过 identifier 标记
        return identifier?.rawValue ?? "left"
    }

    private func showError(error: Error) {
        let alert = NSAlert()
        alert.messageText = "错误"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .critical
        alert.addButton(withTitle: "好")
        if let window = window { alert.beginSheetModal(for: window) { _ in } }
    }

    public override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        scrollView.frame = bounds
    }

    public func reloadData() {
        tableView?.reloadData()
    }

    // MARK: - Double Click

    @objc private func handleDoubleClick() {
        guard let viewModel = viewModel,
              let row = tableView.clickedRow as Int?,
              row >= 0, row < viewModel.files.count else { return }
        let entry = viewModel.files[row]
        onDoubleClick?(entry)
    }
}

// MARK: - NSTableViewDataSource

extension FileListView: NSTableViewDataSource {
    public func numberOfRows(in tableView: NSTableView) -> Int {
        return viewModel?.files.count ?? 0
    }

    public func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let descriptor = tableView.sortDescriptors.first,
              let viewModel = viewModel else { return }
        let key = descriptor.key ?? "name"
        let field: SortField
        switch key {
        case "name": field = .name
        case "modifiedAt": field = .modifiedAt
        case "type": field = .type
        case "size": field = .size
        default: field = .name
        }
        viewModel.setSortField(field, ascending: descriptor.ascending)
        tableView.reloadData()
    }
}

// MARK: - NSTableViewDelegate

extension FileListView: NSTableViewDelegate {
    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let viewModel = viewModel, row < viewModel.files.count else { return nil }
        let entry = viewModel.files[row]

        let cellID = NSUserInterfaceItemIdentifier(tableColumn?.identifier.rawValue ?? "")
        let cellView = tableView.makeView(withIdentifier: cellID, owner: self) as? NSTableCellView
            ?? NSTableCellView()
        cellView.identifier = cellID

        // Ensure text field exists
        if cellView.textField == nil {
            let tf = NSTextField(labelWithString: "")
            tf.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
            tf.lineBreakMode = .byTruncatingTail
            cellView.addSubview(tf)
            cellView.textField = tf
            tf.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                tf.leadingAnchor.constraint(equalTo: cellView.leadingAnchor, constant: 4),
                tf.trailingAnchor.constraint(equalTo: cellView.trailingAnchor, constant: -4),
                tf.centerYAnchor.constraint(equalTo: cellView.centerYAnchor),
            ])
        }

        switch tableColumn?.identifier.rawValue {
        case "name":
            cellView.imageView?.image = entry.isDirectory ? folderIcon : fileIcon
            cellView.textField?.stringValue = entry.name
            // 隐藏文件灰色，系统保护文件红色
            if entry.isSystemProtected {
                cellView.textField?.textColor = NSColor.systemRed
            } else if entry.isHidden {
                cellView.textField?.textColor = NSColor.tertiaryLabelColor
            } else {
                cellView.textField?.textColor = NSColor.labelColor
            }
            // 添加图标（如果还没有）
            if cellView.imageView == nil {
                let iv = NSImageView()
                iv.translatesAutoresizingMaskIntoConstraints = false
                cellView.addSubview(iv)
                cellView.imageView = iv
                cellView.textField?.leadingAnchor.constraint(equalTo: iv.trailingAnchor, constant: 6).isActive = true
                NSLayoutConstraint.activate([
                    iv.leadingAnchor.constraint(equalTo: cellView.leadingAnchor, constant: 4),
                    iv.centerYAnchor.constraint(equalTo: cellView.centerYAnchor),
                    iv.widthAnchor.constraint(equalToConstant: 16),
                    iv.heightAnchor.constraint(equalToConstant: 16),
                ])
            }
            cellView.imageView?.image = entry.isDirectory ? folderIcon : fileIcon

        case "modifiedAt":
            cellView.textField?.stringValue = entry.formattedModificationDate

        case "type":
            cellView.textField?.stringValue = entry.kindDescription

        case "size":
            cellView.textField?.stringValue = entry.formattedSize

        default:
            break
        }

        return cellView
    }

    public func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        return 24
    }

    public func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        guard let viewModel = viewModel, row < viewModel.files.count else { return false }
        let entry = viewModel.files[row]
        let multi = NSEvent.modifierFlags.contains(.command)
        let shift = NSEvent.modifierFlags.contains(.shift)
        viewModel.selectFile(entry, multi: multi, shiftKey: shift)
        onSelectionChanged?(viewModel.selectedFiles)
        return true
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let fileListDidCopy = Notification.Name("fileListDidCopy")
    static let fileListDidCut = Notification.Name("fileListDidCut")
    static let fileListDidPaste = Notification.Name("fileListDidPaste")
}
```

- [ ] **Step 2: 语法检查**

Run: `cd /Volumes/Iris-Data/Download/AI/文件管理系统/flowfinder-native/FlowFinderNative/FlowFinderNative/UI && swiftc -parse FileListView.swift 2>&1 | head -5`
Expected: 无输出（无错误）

- [ ] **Step 3: 提交**

```bash
cd /Volumes/Iris-Data/Download/AI/文件管理系统/flowfinder-native
git add FlowFinderNative/FlowFinderNative/UI/FileListView.swift
git commit -m "refactor: 重写 FileListView 文件列表

- 4 列：名称→修改日期→类型→大小（匹配 Finder）
- 多选支持（allowsMultipleSelection=true）
- 列头点击排序（sortDescriptorsDidChange）
- 隐藏文件灰色文字 / 系统保护文件红色文字
- 右键菜单使用 in-app NSAlert 对话框（无 NSOpenPanel/NSSavePanel）
- 新增 onSelectionChanged 回调（联动 DetailsBar）
- 新增复制/剪切/粘贴通知事件"
```

---

## Task 5: 重写 MainWindowController.swift

**Files:**
- Modify: `FlowFinderNative/FlowFinderNative/UI/MainWindowController.swift`

**Interfaces:**
- Consumes: `PaneViewModel` (Task 2), `PaneToolbar` (Task 3), `FileListView` (Task 4), `DetailsBar`
- Produces: 修复约束 bug（rightFileListView.trailingAnchor → trailingAnchor）
- Produces: leftPaneView/rightPaneView 正确赋值
- Produces: 活跃面板切换 + 视觉反馈
- Produces: DetailsBar 绑定选中文件
- Produces: SortField/ViewMode 枚举适配

- [ ] **Step 1: 重写 MainWindowController.swift**

完整替换 `FlowFinderNative/FlowFinderNative/UI/MainWindowController.swift`：

```swift
import Cocoa
import Combine
import QuickLook

// MARK: - MainWindowController

public class MainWindowController: NSWindowController {

    // MARK: - Properties

    private let leftPaneViewModel = PaneViewModel()
    private let rightPaneViewModel = PaneViewModel()
    private var activePane: PaneSide = .left
    private var cancellables = Set<AnyCancellable>()

    private var sidebarView: SidebarView!
    private var leftPaneContainer: NSView!
    private var rightPaneContainer: NSView!
    private var detailsBar: DetailsBar!
    private var mainSplitView: NSSplitView!
    private var paneSplitView: NSSplitView!

    private var leftPaneToolbar: PaneToolbar!
    private var rightPaneToolbar: PaneToolbar!
    private var leftFileListView: FileListView!
    private var rightFileListView: FileListView!

    // MARK: - Initialization

    public init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "FlowFinder"
        window.minSize = NSSize(width: 1000, height: 700)
        window.center()
        window.setFrameAutosaveName("MainWindow")
        window.isRestorable = true

        super.init(window: window)

        setupUI()
        setupBindings()
        setupNotifications()
        loadInitialDirectories()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - UI Setup

    private func setupUI() {
        guard let window = window else { return }

        // Sidebar
        sidebarView = SidebarView()
        sidebarView.translatesAutoresizingMaskIntoConstraints = false

        // Left Pane
        leftPaneToolbar = PaneToolbar()
        leftPaneToolbar.delegate = self
        leftPaneToolbar.translatesAutoresizingMaskIntoConstraints = false

        leftFileListView = FileListView()
        leftFileListView.identifier = NSUserInterfaceItemIdentifier("left")
        leftFileListView.translatesAutoresizingMaskIntoConstraints = false
        leftFileListView.onDoubleClick = { [weak self] entry in
            self?.handleDoubleClick(entry, side: .left)
        }
        leftFileListView.onSelectionChanged = { [weak self] files in
            self?.handleSelectionChanged(side: .left, files: files)
        }

        leftPaneContainer = NSView()
        leftPaneContainer.translatesAutoresizingMaskIntoConstraints = false
        leftPaneContainer.wantsLayer = true
        leftPaneContainer.layer?.cornerRadius = 8
        leftPaneContainer.addSubview(leftPaneToolbar)
        leftPaneContainer.addSubview(leftFileListView)

        NSLayoutConstraint.activate([
            leftPaneToolbar.topAnchor.constraint(equalTo: leftPaneContainer.topAnchor),
            leftPaneToolbar.leadingAnchor.constraint(equalTo: leftPaneContainer.leadingAnchor),
            leftPaneToolbar.trailingAnchor.constraint(equalTo: leftPaneContainer.trailingAnchor),

            leftFileListView.topAnchor.constraint(equalTo: leftPaneToolbar.bottomAnchor),
            leftFileListView.leadingAnchor.constraint(equalTo: leftPaneContainer.leadingAnchor),
            leftFileListView.trailingAnchor.constraint(equalTo: leftPaneContainer.trailingAnchor),
            leftFileListView.bottomAnchor.constraint(equalTo: leftPaneContainer.bottomAnchor),
        ])

        // Right Pane
        rightPaneToolbar = PaneToolbar()
        rightPaneToolbar.delegate = self
        rightPaneToolbar.translatesAutoresizingMaskIntoConstraints = false

        rightFileListView = FileListView()
        rightFileListView.identifier = NSUserInterfaceItemIdentifier("right")
        rightFileListView.translatesAutoresizingMaskIntoConstraints = false
        rightFileListView.onDoubleClick = { [weak self] entry in
            self?.handleDoubleClick(entry, side: .right)
        }
        rightFileListView.onSelectionChanged = { [weak self] files in
            self?.handleSelectionChanged(side: .right, files: files)
        }

        rightPaneContainer = NSView()
        rightPaneContainer.translatesAutoresizingMaskIntoConstraints = false
        rightPaneContainer.wantsLayer = true
        rightPaneContainer.layer?.cornerRadius = 8
        rightPaneContainer.addSubview(rightPaneToolbar)
        rightPaneContainer.addSubview(rightFileListView)

        NSLayoutConstraint.activate([
            rightPaneToolbar.topAnchor.constraint(equalTo: rightPaneContainer.topAnchor),
            rightPaneToolbar.leadingAnchor.constraint(equalTo: rightPaneContainer.leadingAnchor),
            rightPaneToolbar.trailingAnchor.constraint(equalTo: rightPaneContainer.trailingAnchor),

            rightFileListView.topAnchor.constraint(equalTo: rightPaneToolbar.bottomAnchor),
            rightFileListView.leadingAnchor.constraint(equalTo: rightPaneContainer.leadingAnchor),
            rightFileListView.trailingAnchor.constraint(equalTo: rightPaneContainer.trailingAnchor),  // 修复 bug: 原来错误地约束到 leadingAnchor
            rightFileListView.bottomAnchor.constraint(equalTo: rightPaneContainer.bottomAnchor),
        ])

        // Pane Split View (left/right panes)
        paneSplitView = NSSplitView()
        paneSplitView.isVertical = true
        paneSplitView.dividerStyle = .thin
        paneSplitView.autosaveName = "PaneSplitView"
        paneSplitView.translatesAutoresizingMaskIntoConstraints = false
        paneSplitView.addArrangedSubview(leftPaneContainer)
        paneSplitView.addArrangedSubview(rightPaneContainer)

        // Main Split View (sidebar + panes)
        mainSplitView = NSSplitView()
        mainSplitView.isVertical = true
        mainSplitView.dividerStyle = .thin
        mainSplitView.autosaveName = "MainSplitView"
        mainSplitView.translatesAutoresizingMaskIntoConstraints = false
        mainSplitView.addArrangedSubview(sidebarView)
        mainSplitView.addArrangedSubview(paneSplitView)

        // Details Bar
        detailsBar = DetailsBar()
        detailsBar.translatesAutoresizingMaskIntoConstraints = false

        // Main container
        let mainContainer = NSView()
        mainContainer.translatesAutoresizingMaskIntoConstraints = false
        mainContainer.addSubview(mainSplitView)
        mainContainer.addSubview(detailsBar)

        window.contentView?.addSubview(mainContainer)

        NSLayoutConstraint.activate([
            mainContainer.topAnchor.constraint(equalTo: window.contentView!.topAnchor),
            mainContainer.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor),
            mainContainer.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor),
            mainContainer.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor),

            mainSplitView.topAnchor.constraint(equalTo: mainContainer.topAnchor),
            mainSplitView.leadingAnchor.constraint(equalTo: mainContainer.leadingAnchor),
            mainSplitView.trailingAnchor.constraint(equalTo: mainContainer.trailingAnchor),
            mainSplitView.bottomAnchor.constraint(equalTo: detailsBar.topAnchor),

            detailsBar.leadingAnchor.constraint(equalTo: mainContainer.leadingAnchor),
            detailsBar.trailingAnchor.constraint(equalTo: mainContainer.trailingAnchor),
            detailsBar.bottomAnchor.constraint(equalTo: mainContainer.bottomAnchor),
            detailsBar.heightAnchor.constraint(equalToConstant: 120),
        ])

        // Sidebar width
        sidebarView.widthAnchor.constraint(equalToConstant: 220).isActive = true

        // Pane holding priorities
        mainSplitView.setHoldingPriority(.defaultLow, forSubviewAt: 0)
        mainSplitView.setHoldingPriority(.defaultHigh, forSubviewAt: 1)
        paneSplitView.setHoldingPriority(.defaultHigh, forSubviewAt: 0)
        paneSplitView.setHoldingPriority(.defaultHigh, forSubviewAt: 1)

        // Set initial active pane
        updateActivePaneVisual()
    }

    private func setupBindings() {
        leftPaneViewModel.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in self?.updatePaneUI(side: .left, state: state) }
            .store(in: &cancellables)

        rightPaneViewModel.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in self?.updatePaneUI(side: .right, state: state) }
            .store(in: &cancellables)
    }

    private func setupNotifications() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleSidebarDirectorySelected(_:)),
            name: .sidebarDidSelectDirectory, object: nil
        )
    }

    // MARK: - UI Updates

    private func updatePaneUI(side: PaneSide, state: PaneState) {
        let toolbar = side == .left ? leftPaneToolbar : rightPaneToolbar
        let fileListView = side == .left ? leftFileListView : rightFileListView

        toolbar?.setPath(state.path)
        toolbar?.setCanGoBack(state.historyIndex > 0)
        toolbar?.setCanGoForward(state.historyIndex < state.history.count - 1)
        toolbar?.setViewMode(state.viewMode)

        fileListView?.viewModel = side == .left ? leftPaneViewModel : rightPaneViewModel
        fileListView?.reloadData()
    }

    private func updateActivePaneVisual() {
        leftPaneContainer.layer?.borderWidth = activePane == .left ? 2 : 0
        leftPaneContainer.layer?.borderColor = NSColor.controlAccentColor.cgColor
        rightPaneContainer.layer?.borderWidth = activePane == .right ? 2 : 0
        rightPaneContainer.layer?.borderColor = NSColor.controlAccentColor.cgColor
    }

    private func loadInitialDirectories() {
        let homePath = FileManager.default.homeDirectoryForCurrentUser.path
        let desktopPath = (homePath as NSString).appendingPathComponent("Desktop")
        let documentsPath = (homePath as NSString).appendingPathComponent("Documents")

        leftPaneViewModel.state.path = desktopPath
        leftPaneViewModel.state.history = [desktopPath]
        leftPaneViewModel.state.historyIndex = 0

        rightPaneViewModel.state.path = documentsPath
        rightPaneViewModel.state.history = [documentsPath]
        rightPaneViewModel.state.historyIndex = 0

        leftPaneViewModel.refresh()
        rightPaneViewModel.refresh()
    }

    // MARK: - Actions

    private func handleDoubleClick(_ entry: FileEntry, side: PaneSide) {
        if entry.isDirectory {
            let vm = side == .left ? leftPaneViewModel : rightPaneViewModel
            vm.navigate(to: entry.path)
        } else {
            NSWorkspace.shared.openFile(entry.path)
        }
    }

    private func handleSelectionChanged(side: PaneSide, files: [FileEntry]) {
        // 只有活跃面板的选择才更新 DetailsBar
        guard side == activePane else { return }
        if let first = files.first {
            detailsBar.update(file: first, selectedCount: files.count)
        } else {
            detailsBar.update(file: nil, selectedCount: 0)
        }
    }

    func activatePane(_ side: PaneSide) {
        activePane = side
        updateActivePaneVisual()
    }

    @objc private func handleSidebarDirectorySelected(_ notification: Notification) {
        guard let entry = notification.object as? FileEntry else { return }
        let vm = activePane == .left ? leftPaneViewModel : rightPaneViewModel
        vm.navigate(to: entry.path)
    }
}

// MARK: - PaneToolbarDelegate

extension MainWindowController: PaneToolbarDelegate {
    func paneToolbarDidClickBack(_ toolbar: PaneToolbar) {
        _ = toolbar == leftPaneToolbar ? leftPaneViewModel.goBack() : rightPaneViewModel.goBack()
    }

    func paneToolbarDidClickForward(_ toolbar: PaneToolbar) {
        _ = toolbar == leftPaneToolbar ? rightPaneViewModel.goForward() : rightPaneViewModel.goForward()
    }

    func paneToolbarDidClickUp(_ toolbar: PaneToolbar) {
        let vm = toolbar == leftPaneToolbar ? leftPaneViewModel : rightPaneViewModel
        vm.goUp()
    }

    func paneToolbarDidClickRefresh(_ toolbar: PaneToolbar) {
        let vm = toolbar == leftPaneToolbar ? leftPaneViewModel : rightPaneViewModel
        vm.refresh()
    }

    func paneToolbar(_ toolbar: PaneToolbar, didChangeSearchQuery query: String) {
        let vm = toolbar == leftPaneToolbar ? leftPaneViewModel : rightPaneViewModel
        vm.setSearchQuery(query)
    }

    func paneToolbar(_ toolbar: PaneToolbar, didChangeSortField field: SortField, ascending: Bool) {
        let vm = toolbar == leftPaneToolbar ? leftPaneViewModel : rightPaneViewModel
        vm.setSortField(field, ascending: ascending)
    }

    func paneToolbar(_ toolbar: PaneToolbar, didChangeGroupBy groupBy: String) {
        let vm = toolbar == leftPaneToolbar ? leftPaneViewModel : rightPaneViewModel
        vm.setGroupBy(groupBy)
    }

    func paneToolbar(_ toolbar: PaneToolbar, didChangeViewMode mode: ViewMode) {
        let vm = toolbar == leftPaneToolbar ? leftPaneViewModel : rightPaneViewModel
        vm.setViewMode(mode)
    }

    func paneToolbar(_ toolbar: PaneToolbar, didClickPath path: String) {
        let vm = toolbar == leftPaneToolbar ? leftPaneViewModel : rightPaneViewModel
        vm.navigate(to: path)
    }
}

// MARK: - PaneSide

enum PaneSide {
    case left
    case right
}
```

- [ ] **Step 2: 检查 DetailsBar 是否有 update 方法**

检查 `DetailsBar` 是否有 `update(file:selectedCount:)` 方法。如果没有，需要添加。

Run: `grep -n "func update" /Volumes/Iris-Data/Download/AI/文件管理系统/flowfinder-native/FlowFinderNative/FlowFinderNative/UI/DetailsBar.swift`

如果没有找到，在 DetailsBar.swift 中添加：

```swift
func update(file: FileEntry?, selectedCount: Int) {
    self.file = file
    self.selectedCount = selectedCount
    updateDisplay()
}

private func updateDisplay() {
    guard let file = file else {
        nameField.stringValue = ""
        typeField.stringValue = ""
        sizeField.stringValue = ""
        modifiedField.stringValue = ""
        createdField.stringValue = ""
        tagsField.stringValue = ""
        iconView.image = nil
        return
    }
    nameField.stringValue = file.name
    typeField.stringValue = file.kindDescription
    sizeField.stringValue = file.formattedSize
    modifiedField.stringValue = file.formattedModificationDate
    createdField.stringValue = file.formattedCreationDate
    iconView.image = file.isDirectory ? folderIcon : fileIcon
    // 标签从 xattr 读取
    let tags = TagBridge.shared.getTags(path: file.path)
    tagsField.stringValue = tags.map { $0.name }.joined(separator: ", ")
}
```

- [ ] **Step 3: 语法检查**

Run: `cd /Volumes/Iris-Data/Download/AI/文件管理系统/flowfinder-native/FlowFinderNative/FlowFinderNative/UI && swiftc -parse MainWindowController.swift 2>&1 | head -5`
Expected: 无输出（无错误）

- [ ] **Step 4: 提交**

```bash
cd /Volumes/Iris-Data/Download/AI/文件管理系统/flowfinder-native
git add FlowFinderNative/FlowFinderNative/UI/MainWindowController.swift FlowFinderNative/FlowFinderNative/UI/DetailsBar.swift
git commit -m "refactor: 重写 MainWindowController 主窗口

- 修复 rightFileListView 约束 bug（trailingAnchor 而非 leadingAnchor）
- leftPaneContainer/rightPaneContainer 正确赋值并圆角化
- 活跃面板视觉反馈（边框高亮）
- DetailsBar 绑定活跃面板选中文件
- 适配 SortField/ViewMode 枚举类型 delegate 回调
- 面包屑路径跳转通过 paneToolbar(_:didClickPath:) 路由"
```

---

## Task 6: Phase 2 集成验证

**Files:**
- 无新增/修改，仅验证

- [ ] **Step 1: 全部 Swift 文件语法检查**

Run: `cd /Volumes/Iris-Data/Download/AI/文件管理系统/flowfinder-native/FlowFinderNative/FlowFinderNative && for f in Model/FileEntry.swift Model/PaneState.swift Model/Tag.swift UI/PaneToolbar.swift UI/FileListView.swift UI/MainWindowController.swift UI/DetailsBar.swift UI/SidebarView.swift Bridge/CoreBridge.swift Bridge/FFIFunctions.swift Bridge/SearchBridge.swift; do echo "--- $f ---"; swiftc -parse "$f" 2>&1 | head -3; done`
Expected: 每个文件无输出（无错误）

- [ ] **Step 2: 确认 FileEntryViewModel.swift 已删除**

Run: `ls /Volumes/Iris-Data/Download/AI/文件管理系统/flowfinder-native/FlowFinderNative/FlowFinderNative/Model/FileEntryViewModel.swift 2>&1`
Expected: "No such file or directory"

- [ ] **Step 3: 确认无残留引用 FileEntryViewModel**

Run: `grep -r "FileEntryViewModel" /Volumes/Iris-Data/Download/AI/文件管理系统/flowfinder-native/FlowFinderNative/FlowFinderNative/ 2>/dev/null | head -5`
Expected: 无输出（无残留引用）

- [ ] **Step 4: 提交 Phase 2 完成标记**

```bash
cd /Volumes/Iris-Data/Download/AI/文件管理系统/flowfinder-native
git add -A
git commit -m "milestone: Phase 2 完成 - 主窗口+双面板+文件列表重写

- FileEntry 数据模型重写（id=path，新增 6 个字段）
- PaneState 重写（有序选择数组，修复 sort/filter）
- PaneToolbar 重写（单行布局，面包屑可点击，NSPopUpButton）
- FileListView 重写（4 列 Finder 顺序，多选，列头排序，隐藏/保护文件着色）
- MainWindowController 重写（修复约束 bug，活跃面板，DetailsBar 绑定）
- 删除 FileEntryViewModel（合并到 PaneViewModel）
- 全部文件语法检查通过"
```

---

## Self-Review

### Spec Coverage

| Spec 要求 | 对应 Task |
|-----------|-----------|
| FileEntry id 改为 path | Task 1 |
| FileEntry 新增 isHidden/isSystemProtected/isSymlink/creationDate/tags | Task 1 |
| PaneState selectedFiles 改有序数组 | Task 2 |
| 删除重复的 FileEntryViewModel | Task 2 |
| 修复 sort/filter bug | Task 2 |
| PaneToolbar 面包屑可点击跳转 | Task 3 |
| 排序/分组用 NSPopUpButton | Task 3 |
| 视图切换互斥选中 | Task 3 |
| FileListView 4 列(名称/修改日期/类型/大小) | Task 4 |
| FileListView 多选 | Task 4 |
| FileListView 列头排序 | Task 4 |
| 右键菜单用 in-app 对话框 | Task 4 |
| 隐藏文件灰色 / 系统保护文件红色 | Task 4 |
| MainWindowController 修复约束 bug | Task 5 |
| MainWindowController 活跃面板切换 | Task 5 |
| DetailsBar 绑定选中文件 | Task 5 |
| 全量验证 | Task 6 |

### Placeholder Scan

- 无 TBD/TODO
- 所有代码块完整
- 所有命令精确

### Type Consistency

- `SortField` 枚举在 Task 2 定义，Task 3/4/5 使用一致
- `ViewMode` 枚举在 Task 2 定义，Task 3/5 使用一致
- `PaneToolbarDelegate` 在 Task 3 重新定义（SortField/ViewMode 参数），Task 5 实现一致
- `FileEntry.tags: [Tag]` 在 Task 1 定义，使用 Phase 1 的 Tag 模型
- `PaneViewModel.selectedEntries` 在 Task 2 定义，Task 5 DetailsBar 使用
