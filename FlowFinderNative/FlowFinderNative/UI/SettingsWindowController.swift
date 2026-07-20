import Cocoa

/// 设置窗口控制器：NSTabViewController 三标签页（外观/SMB/快捷键）
public class SettingsWindowController: NSWindowController {

    public static let shared = SettingsWindowController()

    private var tabViewController: NSTabViewController!

    private override init(window: NSWindow?) {
        super.init(window: window)
    }

    private convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 450),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "设置"
        window.minSize = NSSize(width: 500, height: 400)
        window.center()
        window.setFrameAutosaveName("SettingsWindow")
        self.init(window: window)
        setupUI()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - UI Setup

    private func setupUI() {
        tabViewController = NSTabViewController()
        tabViewController.tabStyle = .toolbar

        // 外观标签页
        let appearanceTab = NSTabViewItem(viewController: NSViewController())
        appearanceTab.label = "外观"
        appearanceTab.image = NSImage(systemSymbolName: "paintbrush", accessibilityDescription: "外观")
        let appearanceView = AppearanceSettingsView(frame: .zero)
        appearanceTab.viewController?.view = appearanceView
        tabViewController.addTabViewItem(appearanceTab)

        // SMB 标签页
        let smbTab = NSTabViewItem(viewController: NSViewController())
        smbTab.label = "SMB"
        smbTab.image = NSImage(systemSymbolName: "network", accessibilityDescription: "SMB")
        let smbPanel = SMBManagerPanel(frame: .zero)
        smbTab.viewController?.view = smbPanel
        tabViewController.addTabViewItem(smbTab)

        // 快捷键标签页
        let shortcutsTab = NSTabViewItem(viewController: NSViewController())
        shortcutsTab.label = "快捷键"
        shortcutsTab.image = NSImage(systemSymbolName: "keyboard", accessibilityDescription: "快捷键")
        let shortcutsView = createShortcutsView()
        shortcutsTab.viewController?.view = shortcutsView
        tabViewController.addTabViewItem(shortcutsTab)

        window?.contentViewController = tabViewController
    }

    private func createShortcutsView() -> NSView {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 400))

        let titleLabel = NSTextField(labelWithString: "键盘快捷键")
        titleLabel.font = NSFont.boldSystemFont(ofSize: 16)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let tableView = NSTableView()
        tableView.allowsMultipleSelection = false
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.rowHeight = 24

        let actionCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("action"))
        actionCol.title = "操作"
        actionCol.width = 200
        tableView.addTableColumn(actionCol)

        let shortcutCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("shortcut"))
        shortcutCol.title = "快捷键"
        shortcutCol.width = 150
        tableView.addTableColumn(shortcutCol)

        // 快捷键数据
        let shortcuts: [(String, String)] = [
            ("新建文件夹", "⌘N"),
            ("打开文件", "⌘O"),
            ("关闭窗口", "⌘W"),
            ("复制", "⌘C"),
            ("剪切", "⌘X"),
            ("粘贴", "⌘V"),
            ("全选", "⌘A"),
            ("移动到废纸篓", "⌘⌫"),
            ("撤销", "⌘Z"),
            ("重做", "⌘⇧Z"),
            ("列表视图", "⌘1"),
            ("图标视图", "⌘2"),
            ("刷新", "⌘R"),
            ("搜索", "⌘F"),
            ("重复文件扫描", "⌘⇧D"),
            ("任务面板", "⌘0"),
            ("QuickLook 预览", "空格键"),
            ("复制选中项", "⌘D"),
            ("连接服务器", "⌘K"),
            ("偏好设置", "⌘,"),
        ]

        let dataSource = ShortcutsDataSource(shortcuts: shortcuts)
        tableView.dataSource = dataSource
        tableView.delegate = dataSource

        // 使用关联对象保存 dataSource 防止被释放
        objc_setAssociatedObject(view, "shortcutsDataSource", dataSource, .OBJC_ASSOCIATION_RETAIN)

        scrollView.documentView = tableView

        view.addSubview(titleLabel)
        view.addSubview(scrollView)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            titleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),

            scrollView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 16),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20),
        ])

        return view
    }

    // MARK: - Public API

    public func showWindow() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - ShortcutsDataSource

private class ShortcutsDataSource: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let shortcuts: [(String, String)]

    init(shortcuts: [(String, String)]) {
        self.shortcuts = shortcuts
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        return shortcuts.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < shortcuts.count else { return nil }

        let cellID = NSUserInterfaceItemIdentifier(tableColumn?.identifier.rawValue ?? "")
        let cellView = tableView.makeView(withIdentifier: cellID, owner: self) as? NSTableCellView
            ?? NSTableCellView()
        cellView.identifier = cellID

        if cellView.textField == nil {
            let tf = NSTextField(labelWithString: "")
            tf.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
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
        case "action":
            cellView.textField?.stringValue = shortcuts[row].0
        case "shortcut":
            cellView.textField?.stringValue = shortcuts[row].1
            cellView.textField?.font = NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        default:
            break
        }

        return cellView
    }
}
