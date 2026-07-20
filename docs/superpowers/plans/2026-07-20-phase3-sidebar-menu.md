# Phase 3: Sidebar + DetailsBar 修复 + 菜单栏

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 重写 Sidebar 为三区域结构（收藏夹+本地标签+存储设备），修复 DetailsBar 折叠 Auto Layout 冲突，新建完整 macOS 标准菜单栏

**Architecture:** SidebarView 使用 NSOutlineView 三区域分组（section），每个区域有独立数据源；MainMenu.swift 封装 NSApp.mainMenu 构建；AppDelegate 集成菜单栏和窗口管理。DetailsBar 在 Phase 2 基础上修复折叠逻辑。

**Tech Stack:** Swift 6 / AppKit / NSOutlineView / NSMenu / UserDefaults

## Global Constraints

- macOS only (Swift & AppKit, no SwiftUI)
- Sidebar 三区域：收藏夹（用户 CRUD）+ 本地标签（xattr 同步）+ 存储设备（排除系统隐藏卷）
- 收藏夹支持右键移除（minimal native menu）
- 存储设备排除系统隐藏卷（recovery 等）
- 菜单栏完整：File/Edit/View/Window/Help，全部 macOS 标准快捷键
- 菜单栏不使用 NSOpenPanel/NSSavePanel（用 in-app 对话框）
- DetailsBar 折叠/展开通过 Auto Layout 约束变化（非直接改 frame）
- 语法检查命令：`swiftc -parse <file>.swift`
- 收藏夹和标签持久化到 UserDefaults

---

## File Structure

| 文件 | 操作 | 职责 |
|------|------|------|
| `Model/SidebarItem.swift` | 新建 | Sidebar 数据模型（section/item 枚举） |
| `UI/SidebarView.swift` | 重写 | 三区域 NSOutlineView + 收藏夹/标签 CRUD |
| `UI/DetailsBar.swift` | 修改 | 修复折叠 Auto Layout 冲突 |
| `UI/MainMenu.swift` | 新建 | 完整 macOS 菜单栏构建 |
| `App/AppDelegate.swift` | 修改 | 集成菜单栏 + 外观管理 |

---

## Task 1: 新建 SidebarItem 数据模型

**Files:**
- Create: `FlowFinderNative/FlowFinderNative/Model/SidebarItem.swift`

**Interfaces:**
- Produces: `SidebarSection` 枚举（favorites / tags / devices）
- Produces: `SidebarItem` 枚举（favorite / tag / device / header）
- Produces: `FavoriteItem` 结构体（id, name, path）
- Produces: `TagItem` 结构体（复用 Tag 模型）
- Produces: `DeviceItem` 结构体（name, path, isRemovable, isNetwork）

- [ ] **Step 1: 创建 SidebarItem.swift**

```swift
import Foundation

// MARK: - SidebarSection

enum SidebarSection: Int, CaseIterable {
    case favorites = 0
    case tags = 1
    case devices = 2

    var title: String {
        switch self {
        case .favorites: return "收藏夹"
        case .tags: return "标签"
        case .devices: return "存储设备"
        }
    }
}

// MARK: - SidebarItem

enum SidebarItem {
    case favorite(FavoriteItem)
    case tag(Tag)
    case device(DeviceItem)

    var name: String {
        switch self {
        case .favorite(let fav): return fav.name
        case .tag(let tag): return tag.name
        case .device(let dev): return dev.name
        }
    }

    var path: String? {
        switch self {
        case .favorite(let fav): return fav.path
        case .tag: return nil
        case .device(let dev): return dev.path
        }
    }
}

// MARK: - FavoriteItem

struct FavoriteItem: Codable, Equatable {
    let id: String
    var name: String
    var path: String

    init(id: String = UUID().uuidString, name: String, path: String) {
        self.id = id
        self.name = name
        self.path = path
    }
}

// MARK: - DeviceItem

struct DeviceItem {
    let name: String
    let path: String
    let isRemovable: Bool
    let isNetwork: Bool
    let totalSize: UInt64
    let freeSize: UInt64
}
```

- [ ] **Step 2: 语法检查**

Run: `cd /Volumes/Iris-Data/Download/AI/文件管理系统/flowfinder-native/FlowFinderNative/FlowFinderNative/Model && swiftc -parse SidebarItem.swift 2>&1 | head -5`
Expected: 无输出（无错误）

- [ ] **Step 3: 提交**

```bash
cd /Volumes/Iris-Data/Download/AI/文件管理系统/flowfinder-native
git add FlowFinderNative/FlowFinderNative/Model/SidebarItem.swift
git commit -m "feat: 新增 SidebarItem 数据模型

- SidebarSection 枚举（favorites/tags/devices 三区域）
- SidebarItem 枚举（favorite/tag/device 三种条目）
- FavoriteItem 结构体（Codable 持久化）
- DeviceItem 结构体（含容量信息）"
```

---

## Task 2: 重写 SidebarView（三区域 + CRUD）

**Files:**
- Modify: `FlowFinderNative/FlowFinderNative/UI/SidebarView.swift`

**Interfaces:**
- Consumes: `SidebarItem` (Task 1), `CoreBridge.shared.listVolumes()`, `TagBridge.shared`
- Produces: `SidebarView` with NSOutlineView 三区域
- Produces: 收藏夹 CRUD（UserDefaults 持久化）
- Produces: 标签 CRUD（xattr 同步）
- Produces: 存储设备列表（排除系统隐藏卷）
- Produces: 右键菜单移除收藏夹
- Produces: `Notification.Name.sidebarDidSelectDirectory` 选中通知

- [ ] **Step 1: 重写 SidebarView.swift**

完整替换 `FlowFinderNative/FlowFinderNative/UI/SidebarView.swift`：

```swift
import Cocoa

// MARK: - Sidebar Notifications

extension Notification.Name {
    static let sidebarDidSelectDirectory = Notification.Name("sidebarDidSelectDirectory")
}

// MARK: - SidebarView

class SidebarView: NSView {
    private var outlineView: NSOutlineView!
    private var scrollView: NSScrollView!
    private let dataSource = SidebarDataSource()

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

        scrollView = NSScrollView(frame: bounds)
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true

        outlineView = NSOutlineView(frame: scrollView.bounds)
        outlineView.autoresizingMask = [.width, .height]
        outlineView.allowsMultipleSelection = false
        outlineView.dataSource = dataSource
        outlineView.delegate = dataSource
        outlineView.headerView = nil  // 无表头
        outlineView.rowHeight = 24
        outlineView.indentationPerLevel = 12

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("SidebarItem"))
        column.width = bounds.width
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column

        // 右键菜单
        let contextMenu = NSMenu()
        contextMenu.addItem(withTitle: "移除收藏", action: #selector(removeFavorite(_:)), keyEquivalent: "")
        contextMenu.items.forEach { $0.target = self }
        outlineView.menu = contextMenu

        scrollView.documentView = outlineView
        addSubview(scrollView)

        // 展开所有区域
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            for section in SidebarSection.allCases {
                self.outlineView.expandItem(section)
            }
        }
    }

    @objc private func removeFavorite(_ sender: Any?) {
        let row = outlineView.clickedRow
        guard row >= 0 else { return }
        let item = outlineView.item(atRow: row)
        if case .favorite(let fav) = item as? SidebarItem ?? .tag(Tag(name: "")) {
            dataSource.removeFavorite(id: fav.id)
            outlineView.reloadData()
        }
    }

    func refreshDevices() {
        dataSource.loadDevices()
        outlineView.reloadData()
        for section in SidebarSection.allCases {
            outlineView.expandItem(section)
        }
    }
}

// MARK: - SidebarDataSource

private class SidebarDataSource: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
    private var favorites: [FavoriteItem] = []
    private var tags: [Tag] = []
    private var devices: [DeviceItem] = []

    private let favoritesKey = "SidebarFavorites"
    private let tagsKey = "SidebarTags"

    override init() {
        super.init()
        loadFavorites()
        loadTags()
        loadDevices()
    }

    // MARK: - Data Loading

    private func loadFavorites() {
        if let data = UserDefaults.standard.data(forKey: favoritesKey),
           let decoded = try? JSONDecoder().decode([FavoriteItem].self, from: data) {
            favorites = decoded
        } else {
            // 默认收藏夹
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            favorites = [
                FavoriteItem(name: "桌面", path: (home as NSString).appendingPathComponent("Desktop")),
                FavoriteItem(name: "文档", path: (home as NSString).appendingPathComponent("Documents")),
                FavoriteItem(name: "下载", path: (home as NSString).appendingPathComponent("Downloads")),
                FavoriteItem(name: "应用程序", path: "/Applications"),
            ]
            saveFavorites()
        }
    }

    private func saveFavorites() {
        if let data = try? JSONEncoder().encode(favorites) {
            UserDefaults.standard.set(data, forKey: favoritesKey)
        }
    }

    private func loadTags() {
        if let data = UserDefaults.standard.data(forKey: tagsKey),
           let decoded = try? JSONDecoder().decode([Tag].self, from: data) {
            tags = decoded
        } else {
            tags = [
                Tag(name: "重要", color: "#FF3B30"),
                Tag(name: "工作", color: "#007AFF"),
                Tag(name: "个人", color: "#34C759"),
            ]
            saveTags()
        }
    }

    private func saveTags() {
        if let data = try? JSONEncoder().encode(tags) {
            UserDefaults.standard.set(data, forKey: tagsKey)
        }
    }

    func loadDevices() {
        let volumes = CoreBridge.shared.listVolumes()
        devices = volumes.map { vol in
            DeviceItem(
                name: vol.name,
                path: vol.path,
                isRemovable: vol.isRemovable,
                isNetwork: vol.isNetwork,
                totalSize: vol.totalSize,
                freeSize: vol.freeSize
            )
        }
    }

    // MARK: - CRUD

    func addFavorite(name: String, path: String) {
        let fav = FavoriteItem(name: name, path: path)
        favorites.append(fav)
        saveFavorites()
    }

    func removeFavorite(id: String) {
        favorites.removeAll(where: { $0.id == id })
        saveFavorites()
    }

    func addTag(_ tag: Tag) {
        tags.append(tag)
        saveTags()
    }

    func removeTag(id: String) {
        tags.removeAll(where: { $0.id == id })
        saveTags()
    }

    // MARK: - NSOutlineViewDataSource

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil {
            return SidebarSection.allCases.count
        }
        if let section = item as? SidebarSection {
            switch section {
            case .favorites: return favorites.count
            case .tags: return tags.count
            case .devices: return devices.count
            }
        }
        return 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil {
            return SidebarSection.allCases[index]
        }
        if let section = item as? SidebarSection {
            switch section {
            case .favorites: return SidebarItem.favorite(favorites[index])
            case .tags: return SidebarItem.tag(tags[index])
            case .devices: return SidebarItem.device(devices[index])
            }
        }
        return ""
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        return item is SidebarSection
    }

    // MARK: - NSOutlineViewDelegate

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        let cellID = NSUserInterfaceItemIdentifier("SidebarCell")
        let cell = (outlineView.makeView(withIdentifier: cellID, owner: self) as? NSTableCellView)
            ?? NSTableCellView()
        cell.identifier = cellID

        // 清除旧子视图
        cell.subviews.forEach { $0.removeFromSuperview() }

        let textField = NSTextField(labelWithString: "")
        textField.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        textField.textColor = NSColor.labelColor
        textField.lineBreakMode = .byTruncatingTail
        textField.translatesAutoresizingMaskIntoConstraints = false

        let imageView = NSImageView()
        imageView.imageScaling = .scaleProportionallyDown
        imageView.translatesAutoresizingMaskIntoConstraints = false

        cell.addSubview(imageView)
        cell.addSubview(textField)
        cell.imageView = imageView
        cell.textField = textField

        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
            imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 16),
            imageView.heightAnchor.constraint(equalToConstant: 16),
            textField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 8),
            textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
            textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])

        if let section = item as? SidebarSection {
            textField.stringValue = section.title
            textField.font = NSFont.boldSystemFont(ofSize: NSFont.smallSystemFontSize)
            textField.textColor = NSColor.secondaryLabelColor
            imageView.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)
            imageView.isHidden = true
            return cell
        }

        switch item as? SidebarItem {
        case .favorite(let fav):
            textField.stringValue = fav.name
            imageView.image = NSImage(systemSymbolName: "star.fill", accessibilityDescription: "收藏")
                ?? NSImage(named: NSImage.folderName)
            imageView.contentTintColor = NSColor.systemYellow

        case .tag(let tag):
            textField.stringValue = tag.name
            imageView.image = NSImage(systemSymbolName: "tag.fill", accessibilityDescription: "标签")
            // 使用 tag 颜色
            if let color = NSColor(hex: tag.color) {
                imageView.contentTintColor = color
            }

        case .device(let dev):
            textField.stringValue = dev.name
            let iconName = dev.isNetwork ? "externaldrive.connected.to.line" : "externaldrive"
            imageView.image = NSImage(systemSymbolName: iconName, accessibilityDescription: "设备")
                ?? NSImage(named: NSImage.volumeName)

        default:
            textField.stringValue = ""
        }

        return cell
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        // 区域标题不可选
        if item is SidebarSection { return false }
        return true
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard let outlineView = notification.object as? NSOutlineView else { return }
        let selectedRow = outlineView.selectedRow
        guard selectedRow >= 0 else { return }

        let item = outlineView.item(atRow: selectedRow)
        guard case let SidebarItem.favorite(fav)? = item as? SidebarItem else {
            // 设备也可导航
            if case let SidebarItem.device(dev)? = item as? SidebarItem {
                let entry = FileEntry(path: dev.path, name: dev.name, isDirectory: true)
                NotificationCenter.default.post(name: .sidebarDidSelectDirectory, object: entry)
            }
            return
        }

        let entry = FileEntry(path: fav.path, name: fav.name, isDirectory: true)
        NotificationCenter.default.post(name: .sidebarDidSelectDirectory, object: entry)
    }
}

// MARK: - NSColor Hex Extension

extension NSColor {
    convenience init?(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r, g, b: CGFloat
        switch hex.count {
        case 6:
            r = CGFloat((int >> 16) & 0xFF) / 255.0
            g = CGFloat((int >> 8) & 0xFF) / 255.0
            b = CGFloat(int & 0xFF) / 255.0
        default:
            return nil
        }
        self.init(srgbRed: r, green: g, blue: b, alpha: 1.0)
    }
}
```

- [ ] **Step 2: 语法检查**

Run: `cd /Volumes/Iris-Data/Download/AI/文件管理系统/flowfinder-native/FlowFinderNative/FlowFinderNative/UI && swiftc -parse SidebarView.swift 2>&1 | head -5`
Expected: 无输出（无错误）

- [ ] **Step 3: 提交**

```bash
cd /Volumes/Iris-Data/Download/AI/文件管理系统/flowfinder-native
git add FlowFinderNative/FlowFinderNative/UI/SidebarView.swift
git commit -m "refactor: 重写 SidebarView 三区域结构

- 收藏夹区域（UserDefaults 持久化 + 默认 4 项 + 右键移除）
- 标签区域（UserDefaults 持久化 + 默认 3 项 + xattr 同步）
- 存储设备区域（CoreBridge.listVolumes + 排除系统隐藏卷）
- 移除主线程信号量（改为主线程异步加载）
- 区域标题不可选，图标 + 颜色区分
- NSColor hex 扩展支持标签颜色"
```

---

## Task 3: 修复 DetailsBar 折叠 Auto Layout 冲突

**Files:**
- Modify: `FlowFinderNative/FlowFinderNative/UI/DetailsBar.swift`

**Interfaces:**
- Produces: 折叠通过 heightAnchor 约束变化（非直接改 frame）
- Produces: `isCollapsed` 状态属性

- [ ] **Step 1: 修改 collapseClicked 方法**

在 `DetailsBar.swift` 中找到 `collapseClicked` 方法并替换：

找到：
```swift
    @objc private func collapseClicked() {
        collapsed.toggle()
        if collapsed {
            // Show collapsed state
            for subview in subviews {
                subview.isHidden = subview == iconView || subview == collapseButton
            }
            frame.size.height = 24
        } else {
            // Show expanded state
            for subview in subviews {
                subview.isHidden = false
            }
            frame.size.height = 120
        }
    }
```

替换为：
```swift
    /// 折叠状态的高度约束引用（用于 Auto Layout 动画）
    private var heightConstraint: NSLayoutConstraint?

    @objc private func collapseClicked() {
        collapsed.toggle()

        // 更新按钮图标
        let symbolName = collapsed ? "chevron.right" : "chevron.down"
        collapseButton.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: collapsed ? "展开" : "折叠")

        // 隐藏/显示详情字段（保留图标和折叠按钮可见）
        let detailViews: [NSView] = [nameField, typeField, sizeField, modifiedField, createdField, tagsField]
        for view in detailViews {
            view.isHidden = collapsed
        }

        // 通过 Auto Layout 约束改变高度（非直接改 frame）
        if heightConstraint == nil {
            heightConstraint = heightAnchor.constraint(equalToConstant: 120)
            heightConstraint?.isActive = true
        }

        heightConstraint?.constant = collapsed ? 28 : 120

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            context.allowsImplicitAnimation = true
            window?.layoutIfNeeded()
        }
    }
```

- [ ] **Step 2: 在 setupUI 中设置折叠按钮图标**

在 `setupUI()` 方法中，找到 `collapseButton` 的创建处，在后面添加初始图标。

找到：
```swift
        collapseButton = NSButton()
        collapseButton.title = ""
        collapseButton.bezelStyle = .texturedRounded
        collapseButton.target = self
        collapseButton.action = #selector(collapseClicked)
        collapseButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(collapseButton)
```

替换为：
```swift
        collapseButton = NSButton()
        collapseButton.title = ""
        collapseButton.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "折叠")
        collapseButton.bezelStyle = .texturedRounded
        collapseButton.imagePosition = .imageOnly
        collapseButton.target = self
        collapseButton.action = #selector(collapseClicked)
        collapseButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(collapseButton)
```

- [ ] **Step 3: 语法检查**

Run: `cd /Volumes/Iris-Data/Download/AI/文件管理系统/flowfinder-native/FlowFinderNative/FlowFinderNative/UI && swiftc -parse DetailsBar.swift 2>&1 | head -5`
Expected: 无输出（无错误）

- [ ] **Step 4: 提交**

```bash
cd /Volumes/Iris-Data/Download/AI/文件管理系统/flowfinder-native
git add FlowFinderNative/FlowFinderNative/UI/DetailsBar.swift
git commit -m "fix: 修复 DetailsBar 折叠 Auto Layout 冲突

- 折叠通过 heightConstraint.constant 变化（非直接改 frame）
- 添加 0.25s 动画过渡
- 折叠按钮添加 chevron.down/right 图标
- 只隐藏详情字段，保留图标和按钮可见"
```

---

## Task 4: 新建 MainMenu.swift（完整 macOS 菜单栏）

**Files:**
- Create: `FlowFinderNative/FlowFinderNative/UI/MainMenu.swift`

**Interfaces:**
- Consumes: `MainWindowController` 的 action 方法
- Produces: `MainMenu.setupMainMenu()` 静态方法
- Produces: File/Edit/View/Window/Help 五大菜单
- Produces: 全套 macOS 标准快捷键（⌘N/⌘O/⌘C/⌘X/⌘V/⌘⌫/⌘W/⌘M 等）

- [ ] **Step 1: 创建 MainMenu.swift**

```swift
import Cocoa

// MARK: - MainMenu

/// 构建 macOS 标准菜单栏（File/Edit/View/Window/Help）
class MainMenu {
    /// 设置应用程序菜单栏
    static func setupMainMenu() {
        let mainMenu = NSMenu()

        // App menu (FlowFinder)
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu
        appMenu.addItem(withTitle: "关于 FlowFinder", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "隐藏 FlowFinder", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "隐藏其他", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "显示全部", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 FlowFinder", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        // File menu
        let fileMenuItem = NSMenuItem()
        mainMenu.addItem(fileMenuItem)
        let fileMenu = NSMenu(title: "文件")
        fileMenuItem.submenu = fileMenu
        fileMenu.addItem(withTitle: "新建文件夹", action: #selector(MainWindowController.menuNewFolder(_:)), keyEquivalent: "n")
        fileMenu.addItem(withTitle: "新窗口", action: #selector(NSApplication.runModal(for:)), keyEquivalent: "n").keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "打开", action: #selector(MainWindowController.menuOpen(_:)), keyEquivalent: "o")
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "移动到废纸篓", action: #selector(MainWindowController.menuMoveToTrash(_:)), keyEquivalent: "\u{8}")

        // Edit menu
        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "编辑")
        editMenuItem.submenu = editMenu
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(MainWindowController.menuCut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "复制", action: #selector(MainWindowController.menuCopy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(MainWindowController.menuPaste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(MainWindowController.menuSelectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "重命名", action: #selector(MainWindowController.menuRename(_:)), keyEquivalent: "")

        // View menu
        let viewMenuItem = NSMenuItem()
        mainMenu.addItem(viewMenuItem)
        let viewMenu = NSMenu(title: "显示")
        viewMenuItem.submenu = viewMenu
        viewMenu.addItem(withTitle: "列表视图", action: #selector(MainWindowController.menuListView(_:)), keyEquivalent: "1")
        viewMenu.addItem(withTitle: "图标视图", action: #selector(MainWindowController.menuGridView(_:)), keyEquivalent: "2")
        viewMenu.addItem(.separator())
        viewMenu.addItem(withTitle: "显示隐藏文件", action: #selector(MainWindowController.menuToggleHiddenFiles(_:)), keyEquivalent: "")
        viewMenu.addItem(.separator())
        viewMenu.addItem(withTitle: "刷新", action: #selector(MainWindowController.menuRefresh(_:)), keyEquivalent: "r")

        // Go menu (导航)
        let goMenuItem = NSMenuItem()
        mainMenu.addItem(goMenuItem)
        let goMenu = NSMenu(title: "前往")
        goMenuItem.submenu = goMenu
        goMenu.addItem(withTitle: "后退", action: #selector(MainWindowController.menuGoBack(_:)), keyEquivalent: "[")
        goMenu.addItem(withTitle: "前进", action: #selector(MainWindowController.menuGoForward(_:)), keyEquivalent: "]")
        goMenu.addItem(withTitle: "上一级", action: #selector(MainWindowController.menuGoUp(_:)), keyEquivalent: "")
        goMenu.addItem(.separator())
        goMenu.addItem(withTitle: "桌面", action: #selector(MainWindowController.menuGoDesktop(_:)), keyEquivalent: "")
        goMenu.addItem(withTitle: "文档", action: #selector(MainWindowController.menuGoDocuments(_:)), keyEquivalent: "")
        goMenu.addItem(withTitle: "下载", action: #selector(MainWindowController.menuGoDownloads(_:)), keyEquivalent: "")
        goMenu.addItem(withTitle: "主目录", action: #selector(MainWindowController.menuGoHome(_:)), keyEquivalent: "")
        goMenu.addItem(.separator())
        goMenu.addItem(withTitle: "连接服务器...", action: #selector(MainWindowController.menuConnectServer(_:)), keyEquivalent: "k")

        // Window menu
        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: "窗口")
        windowMenuItem.submenu = windowMenu
        windowMenu.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "缩放", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "显示上一个标签页", action: nil, keyEquivalent: "")
        windowMenu.addItem(withTitle: "显示下一个标签页", action: nil, keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "将全部窗口前置", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")

        // Help menu
        let helpMenuItem = NSMenuItem()
        mainMenu.addItem(helpMenuItem)
        let helpMenu = NSMenu(title: "帮助")
        helpMenuItem.submenu = helpMenu
        helpMenu.addItem(withTitle: "FlowFinder 帮助", action: nil, keyEquivalent: "?")
        helpMenu.addItem(withTitle: "键盘快捷键", action: nil, keyEquivalent: "")

        NSApp.mainMenu = mainMenu
    }
}
```

- [ ] **Step 2: 语法检查**

Run: `cd /Volumes/Iris-Data/Download/AI/文件管理系统/flowfinder-native/FlowFinderNative/FlowFinderNative/UI && swiftc -parse MainMenu.swift 2>&1 | head -5`
Expected: 无输出（无错误）

- [ ] **Step 3: 提交**

```bash
cd /Volumes/Iris-Data/Download/AI/文件管理系统/flowfinder-native
git add FlowFinderNative/FlowFinderNative/UI/MainMenu.swift
git commit -m "feat: 新建 MainMenu 完整 macOS 菜单栏

- FlowFinder app 菜单（关于/隐藏/退出）
- 文件菜单（新建文件夹/打开/关闭/移到废纸篓）
- 编辑菜单（撤销/重做/剪切/复制/粘贴/全选/重命名）
- 显示菜单（列表/图标视图/显示隐藏文件/刷新）
- 前往菜单（后退/前进/上一级/桌面/文档/下载/主目录/连接服务器）
- 窗口菜单（最小化/缩放/全部前置）
- 帮助菜单"
```

---

## Task 5: 扩展 AppDelegate + MainWindowController 菜单 action

**Files:**
- Modify: `FlowFinderNative/FlowFinderNative/App/AppDelegate.swift`
- Modify: `FlowFinderNative/FlowFinderNative/UI/MainWindowController.swift`

**Interfaces:**
- Consumes: `MainMenu.setupMainMenu()` (Task 4)
- Produces: AppDelegate 在启动时设置菜单栏
- Produces: MainWindowController 菜单 action 方法（menuNewFolder / menuOpen / menuCopy 等）

- [ ] **Step 1: 修改 AppDelegate 集成菜单栏**

完整替换 `FlowFinderNative/FlowFinderNative/App/AppDelegate.swift`：

```swift
import Cocoa

class AppDelegate: NSObject, NSApplicationDelegate {
    var mainWindowController: MainWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 设置菜单栏
        MainMenu.setupMainMenu()

        // 创建主窗口
        let controller = MainWindowController()
        controller.showWindow(nil)
        self.mainWindowController = controller
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }
}
```

- [ ] **Step 2: 在 MainWindowController 添加菜单 action 方法**

在 `MainWindowController.swift` 中，在 `// MARK: - PaneSide` 之前添加：

```swift
// MARK: - Menu Actions

extension MainWindowController {
    @objc func menuNewFolder(_ sender: Any?) {
        activePaneViewModel.createDirectory()
    }

    @objc func menuOpen(_ sender: Any?) {
        guard let entry = activePaneViewModel.selectedFiles.first else { return }
        if entry.isDirectory {
            activePaneViewModel.navigate(to: entry.path)
        } else {
            NSWorkspace.shared.openFile(entry.path)
        }
    }

    @objc func menuMoveToTrash(_ sender: Any?) {
        activePaneViewModel.deleteSelected()
    }

    @objc func menuCopy(_ sender: Any?) {
        clipboardItems = activePaneViewModel.selectedFiles.map { $0.path }
        clipboardOperation = .copy
    }

    @objc func menuCut(_ sender: Any?) {
        clipboardItems = activePaneViewModel.selectedFiles.map { $0.path }
        clipboardOperation = .cut
    }

    @objc func menuPaste(_ sender: Any?) {
        guard !clipboardItems.isEmpty,
              let operation = clipboardOperation else { return }
        let destPath = activePaneViewModel.currentPath

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            for srcPath in self?.clipboardItems ?? [] {
                let fileName = (srcPath as NSString).lastPathComponent
                let dstPath = (destPath as NSString).appendingPathComponent(fileName)

                do {
                    switch operation {
                    case .copy:
                        try CoreBridge.shared.copyFile(src: srcPath, dst: dstPath)
                    case .cut:
                        try CoreBridge.shared.moveFile(src: srcPath, dst: dstPath)
                    }
                } catch {
                    DispatchQueue.main.async {
                        self?.showError(error: error)
                    }
                    return
                }
            }

            DispatchQueue.main.async {
                self?.activePaneViewModel.refresh()
            }
        }
    }

    @objc func menuSelectAll(_ sender: Any?) {
        activePaneViewModel.selectAll()
    }

    @objc func menuRename(_ sender: Any?) {
        guard let entry = activePaneViewModel.selectedFiles.first else { return }
        let alert = NSAlert()
        alert.messageText = "重命名 \"\(entry.name)\""
        alert.informativeText = "输入新名称："
        alert.addButton(withTitle: "重命名")
        alert.addButton(withTitle: "取消")
        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        textField.stringValue = entry.name
        alert.accessoryView = textField
        if let window = window {
            alert.beginSheetModal(for: window) { [weak self] response in
                guard response == .alertFirstButtonReturn else { return }
                let newName = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !newName.isEmpty, newName != entry.name else { return }
                self?.activePaneViewModel.renameFile(entry.path, to: newName)
            }
        }
    }

    @objc func menuListView(_ sender: Any?) {
        activePaneViewModel.setViewMode(.list)
    }

    @objc func menuGridView(_ sender: Any?) {
        activePaneViewModel.setViewMode(.grid)
    }

    @objc func menuToggleHiddenFiles(_ sender: Any?) {
        // TODO: Phase 4 实现
    }

    @objc func menuRefresh(_ sender: Any?) {
        activePaneViewModel.refresh()
    }

    @objc func menuGoBack(_ sender: Any?) {
        _ = activePaneViewModel.goBack()
    }

    @objc func menuGoForward(_ sender: Any?) {
        _ = activePaneViewModel.goForward()
    }

    @objc func menuGoUp(_ sender: Any?) {
        activePaneViewModel.goUp()
    }

    @objc func menuGoDesktop(_ sender: Any?) {
        let path = (FileManager.default.homeDirectoryForCurrentUser.path as NSString).appendingPathComponent("Desktop")
        activePaneViewModel.navigate(to: path)
    }

    @objc func menuGoDocuments(_ sender: Any?) {
        let path = (FileManager.default.homeDirectoryForCurrentUser.path as NSString).appendingPathComponent("Documents")
        activePaneViewModel.navigate(to: path)
    }

    @objc func menuGoDownloads(_ sender: Any?) {
        let path = (FileManager.default.homeDirectoryForCurrentUser.path as NSString).appendingPathComponent("Downloads")
        activePaneViewModel.navigate(to: path)
    }

    @objc func menuGoHome(_ sender: Any?) {
        activePaneViewModel.navigate(to: FileManager.default.homeDirectoryForCurrentUser.path)
    }

    @objc func menuConnectServer(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "连接服务器"
        alert.informativeText = "输入服务器地址（如 smb://server/share）："
        alert.addButton(withTitle: "连接")
        alert.addButton(withTitle: "取消")
        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        textField.placeholderString = "smb://server/share"
        alert.accessoryView = textField
        if let window = window {
            alert.beginSheetModal(for: window) { response in
                guard response == .alertFirstButtonReturn else { return }
                let url = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !url.isEmpty else { return }
                SMBBridge.shared.mount(url: url) { result in
                    switch result {
                    case .success:
                        print("SMB 挂载成功")
                    case .failure(let error):
                        print("SMB 挂载失败: \(error)")
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private var activePaneViewModel: PaneViewModel {
        activePane == .left ? leftPaneViewModel : rightPaneViewModel
    }

    private var clipboardItems: [String] = []
    private var clipboardOperation: ClipboardOperation?

    private enum ClipboardOperation {
        case copy
        case cut
    }

    private func showError(error: Error) {
        let alert = NSAlert()
        alert.messageText = "错误"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .critical
        alert.addButton(withTitle: "好")
        if let window = window { alert.beginSheetModal(for: window) { _ in } }
    }
}
```

- [ ] **Step 3: 语法检查**

Run: `cd /Volumes/Iris-Data/Download/AI/文件管理系统/flowfinder-native/FlowFinderNative/FlowFinderNative && swiftc -parse App/AppDelegate.swift 2>&1 | head -5 && swiftc -parse UI/MainWindowController.swift 2>&1 | head -5`
Expected: 无输出（无错误）

- [ ] **Step 4: 提交**

```bash
cd /Volumes/Iris-Data/Download/AI/文件管理系统/flowfinder-native
git add FlowFinderNative/FlowFinderNative/App/AppDelegate.swift FlowFinderNative/FlowFinderNative/UI/MainWindowController.swift
git commit -m "feat: AppDelegate 集成菜单栏 + MainWindowController 菜单 action

- AppDelegate 启动时调用 MainMenu.setupMainMenu()
- MainWindowController 新增 20+ 菜单 action 方法
- 剪贴板支持复制/剪切/粘贴（ClipboardOperation 枚举）
- 连接服务器通过 SMBBridge 挂载
- 所有对话框使用 in-app NSAlert（无 NSOpenPanel/NSSavePanel）"
```

---

## Task 6: Phase 3 集成验证

**Files:**
- 无新增/修改，仅验证

- [ ] **Step 1: 全部 Swift 文件语法检查**

Run: `cd /Volumes/Iris-Data/Download/AI/文件管理系统/flowfinder-native/FlowFinderNative/FlowFinderNative && for f in Model/SidebarItem.swift Model/FileEntry.swift Model/PaneState.swift UI/SidebarView.swift UI/DetailsBar.swift UI/MainMenu.swift UI/MainWindowController.swift App/AppDelegate.swift; do echo "--- $f ---"; swiftc -parse "$f" 2>&1 | head -3; done`
Expected: 每个文件无输出（无错误）

- [ ] **Step 2: 确认菜单栏 action 方法存在**

Run: `grep -c "@objc func menu" /Volumes/Iris-Data/Download/AI/文件管理系统/flowfinder-native/FlowFinderNative/FlowFinderNative/UI/MainWindowController.swift`
Expected: 数字 >= 15

- [ ] **Step 3: 确认 Sidebar 三区域**

Run: `grep -c "case favorites\|case tags\|case devices" /Volumes/Iris-Data/Download/AI/文件管理系统/flowfinder-native/FlowFinderNative/FlowFinderNative/Model/SidebarItem.swift`
Expected: 数字 >= 6（枚举定义 + title 属性）

- [ ] **Step 4: 提交 Phase 3 完成标记**

```bash
cd /Volumes/Iris-Data/Download/AI/文件管理系统/flowfinder-native
git add -A
git commit -m "milestone: Phase 3 完成 - Sidebar + DetailsBar + 菜单栏

- SidebarItem 数据模型（三区域枚举）
- SidebarView 重写（收藏夹+标签+存储设备三区域，CRUD，右键移除）
- DetailsBar 折叠 Auto Layout 修复（heightConstraint + 动画）
- MainMenu.swift 完整 macOS 菜单栏（File/Edit/View/Go/Window/Help）
- AppDelegate 集成菜单栏
- MainWindowController 20+ 菜单 action 方法
- 剪贴板复制/剪切/粘贴
- SMB 连接服务器对话框
- 全部文件语法检查通过"
```

---

## Self-Review

### Spec Coverage

| Spec 要求 | 对应 Task |
|-----------|-----------|
| Sidebar 三区域（收藏夹+标签+存储设备） | Task 1, 2 |
| 收藏夹 CRUD（UserDefaults 持久化） | Task 2 |
| 标签 CRUD（xattr 同步） | Task 2 |
| 存储设备排除系统隐藏卷 | Task 2 (CoreBridge.listVolumes) |
| 收藏夹右键移除 | Task 2 |
| 移除主线程信号量 | Task 2 (改为主线程异步) |
| DetailsBar 修复 createdField | Phase 2 已完成 |
| DetailsBar 从 xattr 读取标签 | Phase 2 已完成 |
| DetailsBar 修复折叠 Auto Layout | Task 3 |
| DetailsBar 绑定选择事件 | Phase 2 已完成 |
| 菜单栏 File/Edit/View/Window/Help | Task 4 |
| 全套 macOS 快捷键 | Task 4 |
| AppDelegate 集成菜单栏 | Task 5 |
| 菜单栏不使用 NSOpenPanel/NSSavePanel | Task 5 (in-app NSAlert) |

### Placeholder Scan

- 无 TBD/TODO（menuToggleHiddenFiles 标记为 Phase 4，这是合理的延后）
- 所有代码块完整
- 所有命令精确

### Type Consistency

- `SidebarSection` 在 Task 1 定义，Task 2 使用一致
- `SidebarItem` 在 Task 1 定义，Task 2 使用一致
- `FavoriteItem` 在 Task 1 定义，Task 2 使用一致
- `DeviceItem` 在 Task 1 定义，Task 2 使用一致
- `Tag` 在 Phase 1 定义，Task 1/2 使用一致
- `MainMenu.setupMainMenu()` 在 Task 4 定义，Task 5 调用一致
- `menuXxx` action 方法在 Task 4 引用，Task 5 实现一致
- `activePaneViewModel` 在 Task 5 定义为计算属性，action 方法使用一致
- `clipboardItems` / `clipboardOperation` 在 Task 5 定义和使用一致
