# FlowFinder Beta UI 补全实施计划 — Week 1：文件浏览/管理路径

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 打通文件浏览/管理路径的完整链路，实现目录树导航、面包屑导航、空格预览。

**Architecture:** 基于现有 CoreBridge 和 FFI 层，补充 Swift UI 侧的缺失逻辑。SidebarView 使用 NSOutlineView 实现目录树；ContentView 添加面包屑导航；QuickLookPreviewView 接入 QuickLookBridge。

**Tech Stack:** Swift + AppKit + CoreBridge + FFI + Rust Core

## Global Constraints

- 平台：仅 macOS（Apple Silicon）
- Swift 5.9+，AppKit
- 沿用现有 CoreBridge API，不修改 FFI 接口
- 所有 UI 文本使用英文（与现有代码保持一致）
- 每个任务结束后必须运行 `swift build` 验证编译

---

## Task 1: 实现 SidebarView 目录树

**Files:**
- Modify: `FlowFinderNative/FlowFinderNative/UI/SidebarView.swift`
- Modify: `FlowFinderNative/FlowFinderNative/Bridge/CoreBridge.swift` (如需新增 listDirectory 包装方法)

**Interfaces:**
- Consumes: `CoreBridge.shared.listDirectory(path:)` → `[FileEntry]`
- Produces: `SidebarView` 作为 `NSOutlineViewDataSource` 和 `NSOutlineViewDelegate`，显示可展开的目录树

### Step 1: 读取现有 SidebarView 和 CoreBridge.listDirectory

首先读取当前实现，确认接口签名。

- [ ] Read `FlowFinderNative/FlowFinderNative/UI/SidebarView.swift`
- [ ] Read `FlowFinderNative/FlowFinderNative/Bridge/CoreBridge.swift` 中的 `listDirectory` 方法
- [ ] Read `FlowFinderNative/FlowFinderNative/Model/FileEntry.swift` 确认数据结构

### Step 2: 实现 SidebarViewModel

在 `SidebarView.swift` 中添加简单的 ViewModel 或数据源，负责：

- 存储根目录列表（如 `/`, `~/Desktop`, `~/Documents`, `~/Downloads`）
- 展开节点时异步加载子目录
- 提供 `children(for item:) -> [FileEntry]` 方法

```swift
private class SidebarDataSource: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
    private let outlineView: NSOutlineView
    private var rootItems: [FileEntry] = []
    private var expandedItems: [URL: [FileEntry]] = [:]
    
    init(outlineView: NSOutlineView) {
        self.outlineView = outlineView
        super.init()
        loadRootItems()
    }
    
    func loadRootItems() {
        // 加载常用目录：Desktop, Documents, Downloads, Home
        let paths = FileManager.default.urls(for: .userDirectory, in: .allDomainsSearch)
        // 过滤出存在的目录
    }
    
    func children(for item: Any?) -> [FileEntry] {
        guard let entry = item as? FileEntry else { return rootItems }
        guard entry.isDir else { return [] }
        
        if let cached = expandedItems[entry.url] {
            return cached
        }
        
        // 异步加载子目录
        var children: [FileEntry] = []
        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                children = try CoreBridge.shared.listDirectory(path: entry.url.path)
                    .filter { $0.isDir }
            } catch {
                print("Failed to load children: \(error)")
            }
            semaphore.signal()
        }
        semaphore.wait()
        
        expandedItems[entry.url] = children
        return children
    }
    
    // MARK: - NSOutlineViewDataSource
    
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        return children(for: item).count
    }
    
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        return children(for: item)[index]
    }
    
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let entry = item as? FileEntry else { return false }
        return entry.isDir
    }
    
    // MARK: - NSOutlineViewDelegate
    
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        let cell = outlineView.makeView(withIdentifier: NSUserInterfaceItemIdentifier("SidebarCell"), owner: self) as? NSTableCellView
            ?? NSTableCellView()
        cell.identifier = NSUserInterfaceItemIdentifier("SidebarCell")
        
        guard let entry = item as? FileEntry else { return cell }
        cell.textField = NSTextField(labelWithString: entry.name)
        cell.imageView = NSImage(named: NSImage.folderNameImageName)
        
        return cell
    }
    
    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard let outlineView = notification.object as? NSOutlineView,
              let selectedItem = outlineView.item(atRow: outlineView.selectedRow) as? FileEntry else { return }
        
        // 通知主窗口导航到选中目录
        NotificationCenter.default.post(
            name: .sidebarDidSelectDirectory,
            object: selectedItem
        )
    }
}
```

- [ ] 在 `SidebarView.swift` 中实现上述 `SidebarDataSource`
- [ ] 在 `SidebarView` 的 `setupUI` 中设置 `NSOutlineView` 的 dataSource 和 delegate

### Step 3: 添加目录选择通知处理

在 `MainWindowController.swift` 中监听 `sidebarDidSelectDirectory` 通知，调用 `viewModel.navigateToEntry`：

```swift
private func setupBindings() {
    // 现有绑定...
    
    NotificationCenter.default.addObserver(
        forName: .sidebarDidSelectDirectory,
        object: nil
    ) { [weak self] notification in
        guard let entry = notification.object as? FileEntry else { return }
        self?.viewModel.navigateToEntry(entry)
    }
}
```

- [ ] 在 `MainWindowController.swift` 中添加通知监听
- [ ] 定义 `Notification.Name.sidebarDidSelectDirectory` 扩展

### Step 4: 验证编译

- [ ] Run: `cd FlowFinderNative && swift build 2>&1 | tail -10`
- Expected: Build complete, no errors

### Step 5: Commit

```bash
git add FlowFinderNative/FlowFinderNative/UI/SidebarView.swift FlowFinderNative/FlowFinderNative/Bridge/CoreBridge.swift FlowFinderNative/FlowFinderNative/UI/MainWindowController.swift
git commit -m "feat(ui): 实现 SidebarView 目录树导航"
```

---

## Task 2: 实现面包屑导航

**Files:**
- Modify: `FlowFinderNative/FlowFinderNative/UI/ContentView.swift`
- Modify: `FlowFinderNative/FlowFinderNative/UI/MainWindowController.swift` (如需)

**Interfaces:**
- Consumes: `viewModel.$currentPath` (CurrentValueSubject<String?>)
- Produces: ContentView 顶部显示路径各层级的可点击按钮

### Step 1: 读取现有 ContentView

- [ ] Read `FlowFinderNative/FlowFinderNative/UI/ContentView.swift`
- [ ] 确认当前布局结构和视图层次

### Step 2: 创建 BreadcrumbView

在 `ContentView.swift` 中添加 `BreadcrumbView` 类：

```swift
public class BreadcrumbView: NSView {
    private var pathComponents: [String] = []
    private var onNavigate: ((String) -> Void)?
    
    public var path: String = "" {
        didSet {
            updateComponents()
            needsDisplay = true
        }
    }
    
    public var onNavigateToPath: ((String) -> Void)? {
        didSet {
            self.onNavigate = onNavigateToPath
        }
    }
    
    private func updateComponents() {
        pathComponents = path.split(separator: "/").map(String.init)
        if path.hasPrefix("/") {
            pathComponents.insert("/", at: 0)
        }
    }
    
    public override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        
        var x: CGFloat = 8
        let y: CGFloat = 4
        let height = bounds.height - 8
        
        for (index, component) in pathComponents.enumerated() {
            let isLast = index == pathComponents.count - 1
            
            let text = component.isEmpty ? "/" : component
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
                .foregroundColor: isLast ? NSColor.controlTextColor : NSColor.systemBlue
            ]
            
            let size = text.size(withAttributes: attributes)
            let rect = NSRect(x: x, y: y, width: size.width, height: height)
            
            // 绘制文本
            text.draw(in: rect, withAttributes: attributes)
            
            x += size.width + 4
            
            // 如果不是最后一个，绘制分隔符
            if !isLast {
                let separator = "/"
                let sepSize = separator.size(withAttributes: attributes)
                let sepRect = NSRect(x: x, y: y, width: sepSize.width, height: height)
                separator.draw(in: sepRect, withAttributes: attributes)
                x += sepSize.width + 4
            }
        }
    }
    
    public override func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        var x: CGFloat = 8
        let y: CGFloat = 4
        let height = bounds.height - 8
        
        for (index, component) in pathComponents.enumerated() {
            let isLast = index == pathComponents.count - 1
            let text = component.isEmpty ? "/" : component
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
                .foregroundColor: isLast ? NSColor.controlTextColor : NSColor.systemBlue
            ]
            
            let size = text.size(withAttributes: attributes)
            
            if location.x >= x && location.x <= x + size.width {
                // 构建到该层级的路径
                let targetPath = "/" + pathComponents[1...index].joined(separator: "/")
                onNavigate?(targetPath)
                return
            }
            
            x += size.width + 4
            
            if !isLast {
                let separator = "/"
                let sepSize = separator.size(withAttributes: attributes)
                x += sepSize.width + 4
            }
        }
    }
}
```

### Step 3: 集成到 ContentView

修改 `ContentView` 的布局，在文件列表上方添加面包屑：

```swift
public override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    setupUI()
}

private func setupUI() {
    // 面包屑导航
    breadcrumbView = BreadcrumbView(frame: NSRect(x: 0, y: 0, width: frameRect.width, height: 24))
    breadcrumbView.onNavigateToPath = { [weak self] path in
        self?.viewModel?.navigateToPath(path)
    }
    addSubview(breadcrumbView)
    
    // 现有的 splitView 和文件列表...
    // 调整 y 起始位置，为面包屑留出空间
}
```

同时监听 `viewModel.$currentPath` 更新面包屑：

```swift
private var cancellables: Set<AnyCancellable> = []

public func bind(to viewModel: FileListViewModel) {
    self.viewModel = viewModel
    
    viewModel.$currentPath
        .receive(on: DispatchQueue.main)
        .sink { [weak self] path in
            self?.breadcrumbView.path = path ?? ""
        }
        .store(in: &cancellables)
    
    // 现有绑定...
}
```

### Step 4: 验证编译

- [ ] Run: `cd FlowFinderNative && swift build 2>&1 | tail -10`
- Expected: Build complete, no errors

### Step 5: Commit

```bash
git add FlowFinderNative/FlowFinderNative/UI/ContentView.swift FlowFinderNative/FlowFinderNative/UI/MainWindowController.swift
git commit -m "feat(ui): 添加面包屑路径导航"
```

---

## Task 3: 接入 QuickLook 空格预览

**Files:**
- Modify: `FlowFinderNative/FlowFinderNative/UI/FileListView.swift`
- Modify: `FlowFinderNative/FlowFinderNative/Bridge/SearchBridge.swift` (QuickLookBridge)

**Interfaces:**
- Consumes: `QuickLookBridge.shared.show(paths: [String])` 和 `QuickLookBridge.shared.close()`
- Produces: FileListView 选中文件按空格键触发 Quick Look，按 Esc 关闭

### Step 1: 读取现有 FileListView 和 QuickLookBridge

- [ ] Read `FlowFinderNative/FlowFinderNative/UI/FileListView.swift`
- [ ] Read `FlowFinderNative/FlowFinderNative/Bridge/SearchBridge.swift` 中的 QuickLookBridge
- [ ] 确认 QuickLookBridge 的 API 签名

### Step 2: 在 FileListView 中添加键盘监听

在 `FileListView` 中添加 `NSTextField` 的键盘事件监听，或使用 `NSResponder` 链：

```swift
public override func keyDown(with event: NSEvent) {
    guard let keyCode = KeyCode(rawValue: Int(event.keyCode)) else {
        super.keyDown(with: event)
        return
    }
    
    switch keyCode {
    case .space:
        // 阻止默认行为（空格滚动）
        handleQuickLook()
    case .escape:
        QuickLookBridge.shared.close()
        super.keyDown(with: event)
    default:
        super.keyDown(with: event)
    }
}

private func handleQuickLook() {
    guard let selectedEntry = tableView.item(atRow: tableView.selectedRow) as? FileEntry else { return }
    
    let paths = [selectedEntry.url.path]
    QuickLookBridge.shared.show(paths: paths)
}
```

### Step 3: 处理 Quick Look 关闭后的焦点恢复

Quick Look 关闭后，焦点应回到文件列表：

```swift
// 在 FileListView 中添加
public override func viewDidAppear() {
    super.viewDidAppear()
    window?.makeFirstResponder(tableView)
}
```

### Step 4: 验证编译

- [ ] Run: `cd FlowFinderNative && swift build 2>&1 | tail -10`
- Expected: Build complete, no errors

### Step 5: 手动测试

- [ ] 运行应用，打开一个包含图片/PDF 的目录
- [ ] 选中一个文件，按空格键 → 预期 Quick Look 面板弹出
- [ ] 按 Esc 键 → 预期 Quick Look 关闭
- [ ] 点击其他窗口再回来 → 预期 Quick Look 已关闭

### Step 6: Commit

```bash
git add FlowFinderNative/FlowFinderNative/UI/FileListView.swift
git commit -m "feat(ui): FileListView 接入 QuickLook 空格预览"
```

---

## Task 4: Week 1 集成验证

### Step 1: 完整构建验证

- [ ] Run: `cd FlowFinderNative && swift build 2>&1 | tail -10`
- Expected: Build complete

### Step 2: 功能验证清单

- [ ] 应用启动后，左侧边栏显示目录树
- [ ] 点击边栏目录项，右侧加载该目录文件列表
- [ ] 点击边栏可展开子目录
- [ ] 顶部面包屑显示当前路径
- [ ] 点击面包屑任意层级，导航到该目录
- [ ] 选中文件按空格，Quick Look 弹出
- [ ] 按 Esc，Quick Look 关闭
- [ ] 复制/移动/删除/重命名/新建文件夹操作正常

### Step 3: 提交 Week 1 完成

```bash
git add -A
git commit -m "feat: Week 1 完成 - 文件浏览/管理路径打通

- SidebarView 目录树导航
- ContentView 面包屑导航
- FileListView QuickLook 空格预览
- 集成验证通过"
```

---

## 下周预告：Week 2 — 搜索路径

- SearchBridge 回调解析（FFSearchResult C 结构体）
- SearchBarView.onSearch 连接到 SearchBridge
- SearchResultsView 数据绑定
- 搜索结果双击定位和右键菜单

---

计划已保存到 `docs/superpowers/plans/2026-07-18-beta-ui-completion-week1.md`。

**两个执行选项：**

1. **Subagent-Driven（推荐）** - 我为每个 Task 派发一个独立子代理，逐任务执行并审查，速度快
2. **Inline Execution** - 我在当前会话中逐 Task 执行，带检查点

你选哪个？或者我直接开始执行 Week 1？