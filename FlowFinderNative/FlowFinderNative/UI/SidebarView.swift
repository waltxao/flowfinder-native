import Cocoa

// MARK: - Sidebar Notifications

extension Notification.Name {
    static let sidebarDidSelectDirectory = Notification.Name("sidebarDidSelectDirectory")
    static let paneDidActivate = Notification.Name("paneDidActivate")
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
        // 透明背景，依赖 MainWindowController 的 NSVisualEffectView 玻璃态
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear
        // NSClipView 默认绘制 controlBackgroundColor（浅灰），必须显式清除
        scrollView.contentView.drawsBackground = false
        scrollView.contentView.backgroundColor = .clear

        outlineView = NSOutlineView()
        outlineView.allowsMultipleSelection = false
        outlineView.dataSource = dataSource
        outlineView.delegate = dataSource
        outlineView.headerView = nil  // 无表头
        outlineView.rowHeight = 24
        outlineView.indentationPerLevel = 12
        outlineView.backgroundColor = NSColor.clear

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("SidebarItem"))
        column.width = 200
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column

        // 右键菜单
        let contextMenu = NSMenu()
        contextMenu.addItem(withTitle: "移除收藏", action: #selector(removeFavorite(_:)), keyEquivalent: "")
        contextMenu.items.forEach { $0.target = self }
        outlineView.menu = contextMenu

        scrollView.documentView = outlineView
        addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        // 监听卷挂载/卸载通知
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(self, selector: #selector(handleVolumeMount(_:)),
                       name: NSWorkspace.didMountNotification, object: nil)
        nc.addObserver(self, selector: #selector(handleVolumeUnmount(_:)),
                       name: NSWorkspace.didUnmountNotification, object: nil)

        // 展开所有区域
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            for section in SidebarSection.allCases {
                self.outlineView.expandItem(section)
            }
        }
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    @objc private func handleVolumeMount(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            self?.refreshDevices()
        }
    }

    @objc private func handleVolumeUnmount(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            self?.refreshDevices()
        }
    }

    @objc private func removeFavorite(_ sender: Any?) {
        let row = outlineView.clickedRow
        guard row >= 0 else { return }
        let item = outlineView.item(atRow: row)
        if case .favorite(let fav) = item as? SidebarItem {
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
            let isNetwork = vol.fsType.lowercased().contains("smb") || vol.fsType.lowercased().contains("nfs") || vol.fsType.lowercased().contains("afp")
            return DeviceItem(
                name: vol.name,
                path: vol.path,
                isRemovable: vol.isRemovable,
                isNetwork: isNetwork,
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
                ?? NSImage(systemSymbolName: "externaldrive", accessibilityDescription: nil)

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
        guard let sidebarItem = item as? SidebarItem else { return }

        switch sidebarItem {
        case .favorite(let fav):
            let entry = FileEntry(path: fav.path, name: fav.name, isDirectory: true)
            NotificationCenter.default.post(name: .sidebarDidSelectDirectory, object: entry)
        case .device(let dev):
            let entry = FileEntry(path: dev.path, name: dev.name, isDirectory: true)
            NotificationCenter.default.post(name: .sidebarDidSelectDirectory, object: entry)
        case .tag:
            // 标签点击可选不做导航（未来可筛选同名标签文件）
            break
        }
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
