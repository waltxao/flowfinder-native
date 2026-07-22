import Cocoa

// MARK: - Sidebar Notifications

extension Notification.Name {
    static let sidebarDidSelectDirectory = Notification.Name("sidebarDidSelectDirectory")
    static let paneDidActivate = Notification.Name("paneDidActivate")
}

// MARK: - SidebarView

class SidebarView: NSView {
    private var mainOutlineView: NSOutlineView!
    private var deviceOutlineView: NSOutlineView!
    private var mainScrollView: NSScrollView!
    private var deviceScrollView: NSScrollView!
    /// 上方区域圆角遮罩（包裹收藏夹 + 标签）
    private var mainMaskView: GlassSectionMaskView!
    /// 下方区域圆角遮罩（包裹存储设备）
    private var deviceMaskView: GlassSectionMaskView!
    private let mainDataSource = MainSidebarDataSource()
    private let deviceDataSource = DeviceSidebarDataSource()
    private var deviceHeightConstraint: NSLayoutConstraint!

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

        // 圆角遮罩区域：上方（收藏夹 + 标签）
        mainMaskView = GlassSectionMaskView()
        mainMaskView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(mainMaskView)

        // 圆角遮罩区域：下方（存储设备）
        deviceMaskView = GlassSectionMaskView()
        deviceMaskView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(deviceMaskView)

        // 上方：收藏夹 + 标签
        mainScrollView = makeScrollView()
        mainOutlineView = makeOutlineView()
        mainOutlineView.dataSource = mainDataSource
        mainOutlineView.delegate = mainDataSource
        // 右键菜单（仅主列表需要「移除收藏」）
        let contextMenu = NSMenu()
        contextMenu.addItem(withTitle: "移除收藏", action: #selector(removeFavorite(_:)), keyEquivalent: "")
        contextMenu.items.forEach { $0.target = self }
        mainOutlineView.menu = contextMenu
        mainScrollView.documentView = mainOutlineView
        // 放入遮罩容器，由 mask 提供圆角半透明背景
        mainMaskView.addSubview(mainScrollView)

        // 下方：存储设备（独立区域，固定底部）
        deviceScrollView = makeScrollView()
        deviceOutlineView = makeOutlineView()
        deviceOutlineView.dataSource = deviceDataSource
        deviceOutlineView.delegate = deviceDataSource
        deviceScrollView.documentView = deviceOutlineView
        // 放入遮罩容器
        deviceMaskView.addSubview(deviceScrollView)

        // 设备区高度根据设备数量动态调整（保留最小高度）
        // 高度约束作用于设备遮罩容器，scrollView 填满遮罩
        deviceHeightConstraint = deviceMaskView.heightAnchor.constraint(equalToConstant: 48)
        deviceHeightConstraint.priority = .required

        let padding: CGFloat = 12

        NSLayoutConstraint.activate([
            // 主遮罩区域填充顶部剩余空间
            mainMaskView.topAnchor.constraint(equalTo: topAnchor, constant: padding),
            mainMaskView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: padding),
            mainMaskView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -padding),
            mainMaskView.bottomAnchor.constraint(equalTo: deviceMaskView.topAnchor, constant: -padding),

            // 设备遮罩区域固定底部
            deviceMaskView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: padding),
            deviceMaskView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -padding),
            deviceMaskView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -padding),
            deviceHeightConstraint,

            // 主 scrollView 填满主遮罩（内边距 8pt，圆角由 mask 的 masksToBounds 裁剪）
            mainScrollView.topAnchor.constraint(equalTo: mainMaskView.topAnchor, constant: 8),
            mainScrollView.leadingAnchor.constraint(equalTo: mainMaskView.leadingAnchor, constant: 8),
            mainScrollView.trailingAnchor.constraint(equalTo: mainMaskView.trailingAnchor, constant: -8),
            mainScrollView.bottomAnchor.constraint(equalTo: mainMaskView.bottomAnchor, constant: -8),

            // 设备 scrollView 填满设备遮罩（内边距 8pt）
            deviceScrollView.topAnchor.constraint(equalTo: deviceMaskView.topAnchor, constant: 8),
            deviceScrollView.leadingAnchor.constraint(equalTo: deviceMaskView.leadingAnchor, constant: 8),
            deviceScrollView.trailingAnchor.constraint(equalTo: deviceMaskView.trailingAnchor, constant: -8),
            deviceScrollView.bottomAnchor.constraint(equalTo: deviceMaskView.bottomAnchor, constant: -8),
        ])

        // 监听卷挂载/卸载通知
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(self, selector: #selector(handleVolumeMount(_:)),
                       name: NSWorkspace.didMountNotification, object: nil)
        nc.addObserver(self, selector: #selector(handleVolumeUnmount(_:)),
                       name: NSWorkspace.didUnmountNotification, object: nil)

        // 展开各自区域
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.mainOutlineView.expandItem(SidebarSection.favorites)
            self.mainOutlineView.expandItem(SidebarSection.tags)
            self.deviceOutlineView.expandItem(SidebarSection.devices)
            self.updateDeviceHeight()
        }
    }

    // MARK: - Helpers

    private func makeScrollView() -> NSScrollView {
        let sv = NSScrollView()
        sv.translatesAutoresizingMaskIntoConstraints = false
        sv.hasVerticalScroller = true
        sv.hasHorizontalScroller = false
        sv.autohidesScrollers = true
        sv.drawsBackground = false
        sv.backgroundColor = .clear
        // NSClipView 默认绘制 controlBackgroundColor（浅灰），必须显式清除
        sv.contentView.drawsBackground = false
        sv.contentView.backgroundColor = .clear
        return sv
    }

    private func makeOutlineView() -> NSOutlineView {
        let ov = NSOutlineView()
        ov.allowsMultipleSelection = false
        ov.headerView = nil  // 无表头
        ov.rowHeight = 24
        ov.indentationPerLevel = 12
        ov.backgroundColor = NSColor.clear

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("SidebarItem"))
        column.width = 200
        ov.addTableColumn(column)
        ov.outlineTableColumn = column
        return ov
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    // MARK: - Volume Events

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

    // MARK: - Context Menu

    @objc private func removeFavorite(_ sender: Any?) {
        let row = mainOutlineView.clickedRow
        guard row >= 0 else { return }
        let item = mainOutlineView.item(atRow: row)
        if case .favorite(let fav) = item as? SidebarItem {
            mainDataSource.removeFavorite(id: fav.id)
            mainOutlineView.reloadData()
        }
    }

    // MARK: - Refresh

    func refreshDevices() {
        deviceDataSource.loadDevices()
        deviceOutlineView.reloadData()
        deviceOutlineView.expandItem(SidebarSection.devices)
        updateDeviceHeight()
    }

    private func updateDeviceHeight() {
        // section 标题行（24pt） + 设备行（52pt：图标行20 + 进度条行8 + 文字行12 + 间距8 + padding4）
        let sectionHeight: CGFloat = 24
        let deviceRowHeight: CGFloat = 52
        let height = sectionHeight + CGFloat(deviceDataSource.deviceCount) * deviceRowHeight
        deviceHeightConstraint.constant = max(height, 48)
    }
}

// MARK: - SidebarDataSourceBase

private class SidebarDataSourceBase: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        // 收藏夹不可折叠（始终展开），标签和设备可折叠
        if let section = item as? SidebarSection {
            return section != .favorites
        }
        return false
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        // 区域标题不可选
        if item is SidebarSection { return false }
        return true
    }

    // MARK: - Shared Cell Rendering

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        let cellID = NSUserInterfaceItemIdentifier("SidebarCell")
        let cell = (outlineView.makeView(withIdentifier: cellID, owner: self) as? NSTableCellView)
            ?? NSTableCellView()
        cell.identifier = cellID

        // 清除旧子视图与引用
        cell.subviews.forEach { $0.removeFromSuperview() }
        cell.imageView = nil
        cell.textField = nil

        // 标签：药丸样式（自定义布局）
        if case .tag(let tag) = item as? SidebarItem {
            configureTagPill(cell: cell, tag: tag)
            return cell
        }

        // 设备：进度条 + 可用空间（自定义布局）
        if case .device(let dev) = item as? SidebarItem {
            configureDeviceCell(cell: cell, dev: dev)
            return cell
        }

        // 默认布局：图标 + 文字（区域标题 / 收藏夹）
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
            // 使用 NSWorkspace 获取真实位置图标（桌面、文稿、下载等各有不同图标）
            let workspaceIcon = NSWorkspace.shared.icon(forFile: fav.path)
            workspaceIcon.size = NSSize(width: 16, height: 16)
            imageView.image = workspaceIcon

        default:
            textField.stringValue = ""
        }

        return cell
    }

    // MARK: - Row Height

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        // 设备行使用更高的高度以容纳「图标 + 进度条 + 可用空间」三行
        if case .device = item as? SidebarItem {
            return 52
        }
        return 24
    }

    // MARK: - Tag Pill (药丸样式)

    private func configureTagPill(cell: NSTableCellView, tag: Tag) {
        let pillHeight: CGFloat = 20

        let pill = NSView()
        pill.wantsLayer = true
        pill.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.6).cgColor
        pill.layer?.cornerRadius = pillHeight / 2  // ≈10pt
        pill.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(pill)

        // 左侧彩色小圆点（8x8，cornerRadius = 4）
        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.backgroundColor = (NSColor(hex: tag.color) ?? .systemBlue).cgColor
        dot.layer?.cornerRadius = 4
        dot.translatesAutoresizingMaskIntoConstraints = false
        pill.addSubview(dot)

        // 标签文字
        let label = NSTextField(labelWithString: tag.name)
        label.font = NSFont.systemFont(ofSize: 11)
        label.textColor = NSColor.labelColor
        label.lineBreakMode = .byTruncatingTail
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false
        pill.addSubview(label)

        cell.textField = label

        NSLayoutConstraint.activate([
            pill.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
            pill.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            pill.heightAnchor.constraint(equalToConstant: pillHeight),

            dot.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 8),
            dot.centerYAnchor.constraint(equalTo: pill.centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8),

            label.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 6),
            label.centerYAnchor.constraint(equalTo: pill.centerYAnchor),
            pill.trailingAnchor.constraint(equalTo: label.trailingAnchor, constant: 8),
        ])
    }

    // MARK: - Device Cell (进度条 + 可用空间)

    private func configureDeviceCell(cell: NSTableCellView, dev: DeviceItem) {
        // 上行：图标(14x14) + 名称(11pt)
        let icon = NSImageView()
        icon.imageScaling = .scaleProportionallyDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        let iconName: String
        if dev.path == "/" {
            iconName = "internaldrive"
        } else if dev.path == FileManager.default.homeDirectoryForCurrentUser.path {
            iconName = "house"
        } else if dev.isNetwork {
            iconName = "externaldrive.connected.to.line"
        } else {
            iconName = "externaldrive"
        }
        icon.image = NSImage(systemSymbolName: iconName, accessibilityDescription: "设备")
            ?? NSImage(systemSymbolName: "externaldrive", accessibilityDescription: nil)

        let nameField = NSTextField(labelWithString: dev.name)
        nameField.font = NSFont.systemFont(ofSize: 11)
        nameField.textColor = NSColor.labelColor
        nameField.lineBreakMode = .byTruncatingTail
        nameField.translatesAutoresizingMaskIntoConstraints = false

        // 中行：水平进度条（4pt 高，填充宽度）
        let progress = NSProgressIndicator()
        progress.style = .bar
        progress.controlSize = .small
        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 1
        // NSProgressIndicator.controlTint 自 10.15 起已弃用且不生效，
        // 进度条已用部分自动跟随系统强调色（默认即为 systemBlue），剩余轨道为系统灰色。
        progress.translatesAutoresizingMaskIntoConstraints = false
        if dev.totalSize > 0 {
            let used = Double(dev.totalSize - dev.freeSize) / Double(dev.totalSize)
            progress.doubleValue = min(max(used, 0), 1)
        } else {
            progress.doubleValue = 0
        }

        // 下行：可用空间文字(9pt)
        let freeField = NSTextField(labelWithString: formatFreeSpace(dev.freeSize))
        freeField.font = NSFont.systemFont(ofSize: 9)
        freeField.textColor = NSColor.tertiaryLabelColor
        freeField.lineBreakMode = .byTruncatingTail
        freeField.translatesAutoresizingMaskIntoConstraints = false

        cell.addSubview(icon)
        cell.addSubview(nameField)
        cell.addSubview(progress)
        cell.addSubview(freeField)
        cell.imageView = icon
        cell.textField = nameField

        let progressHeight = progress.heightAnchor.constraint(equalToConstant: 4)
        progressHeight.priority = .required

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
            icon.topAnchor.constraint(equalTo: cell.topAnchor, constant: 3),
            icon.widthAnchor.constraint(equalToConstant: 14),
            icon.heightAnchor.constraint(equalToConstant: 14),

            nameField.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            nameField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
            nameField.centerYAnchor.constraint(equalTo: icon.centerYAnchor),

            progress.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
            progress.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
            progress.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 2),
            progressHeight,

            freeField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
            freeField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
            freeField.topAnchor.constraint(equalTo: progress.bottomAnchor, constant: 2),
        ])
    }

    // MARK: - Free Space Formatting

    private func formatFreeSpace(_ bytes: UInt64) -> String {
        if bytes == 0 { return "" }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useTB]
        formatter.countStyle = .file
        return "\(formatter.string(fromByteCount: Int64(bytes))) 可用"
    }

    // MARK: - Selection

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

// MARK: - MainSidebarDataSource (收藏夹 + 标签)

private class MainSidebarDataSource: SidebarDataSourceBase {
    private var favorites: [FavoriteItem] = []
    private var tags: [Tag] = []

    private let favoritesKey = "SidebarFavorites"
    private let tagsKey = "SidebarTags"

    override init() {
        super.init()
        loadFavorites()
        loadTags()
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
            // 收藏夹 + 标签 两个 section
            return 2
        }
        if let section = item as? SidebarSection {
            switch section {
            case .favorites: return favorites.count
            case .tags: return tags.count
            case .devices: return 0
            }
        }
        return 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil {
            // 0 -> 收藏夹, 1 -> 标签
            return index == 0 ? SidebarSection.favorites : SidebarSection.tags
        }
        if let section = item as? SidebarSection {
            switch section {
            case .favorites: return SidebarItem.favorite(favorites[index])
            case .tags: return SidebarItem.tag(tags[index])
            case .devices: return ""
            }
        }
        return ""
    }
}

// MARK: - DeviceSidebarDataSource (存储设备)

private class DeviceSidebarDataSource: SidebarDataSourceBase {
    private var devices: [DeviceItem] = []

    var deviceCount: Int { devices.count }

    override init() {
        super.init()
        loadDevices()
    }

    // MARK: - Data Loading

    func loadDevices() {
        let volumes = CoreBridge.shared.listVolumes()
        devices = []

        // 1. 始终添加主硬盘（根目录 /），即使 Rust 端过滤了它
        // volumeNameKey 可能返回电脑名而非卷名，使用 volumeLocalizedNameKey 并提供回退
        let homePath = FileManager.default.homeDirectoryForCurrentUser.path
        let rootURL = URL(fileURLWithPath: "/")
        var rootName = "Macintosh HD"
        if let name = try? rootURL.resourceValues(forKeys: [.volumeLocalizedNameKey]).volumeLocalizedName,
           !name.isEmpty, name != Host.current().localizedName {
            rootName = name
        }
        devices.append(DeviceItem(
            name: rootName,
            path: "/",
            isRemovable: false,
            isNetwork: false,
            totalSize: 0,
            freeSize: 0
        ))

        // 2. 添加用户主目录（作为快捷设备入口）
        let homeName = homePath.components(separatedBy: "/").last ?? "Home"
        devices.append(DeviceItem(
            name: homeName,
            path: homePath,
            isRemovable: false,
            isNetwork: false,
            totalSize: 0,
            freeSize: 0
        ))

        // 3. 过滤并添加外部/网络卷
        for vol in volumes {
            // 只保留 /Volumes/ 下的挂载卷（U盘、外接硬盘、网络驱动器等）
            guard vol.path.hasPrefix("/Volumes/") else { continue }

            // 过滤系统隐藏卷（VM、Preboot、Update 等）
            let volName = vol.name
            let systemNames: Set<String> = [
                "VM", "Preboot", "Update", "xarts", "iSCPreboot",
                "Hardware", "Recovery", "SSV", "Data"
            ]
            if systemNames.contains(volName) { continue }

            // 过滤 UUID 命名的快照卷
            if volName.count == 36 && volName.contains("-") { continue }

            let isNetwork = vol.fsType.lowercased().contains("smb")
                || vol.fsType.lowercased().contains("nfs")
                || vol.fsType.lowercased().contains("afp")

            devices.append(DeviceItem(
                name: volName,
                path: vol.path,
                isRemovable: vol.isRemovable,
                isNetwork: isNetwork,
                totalSize: vol.totalSize,
                freeSize: vol.freeSize
            ))
        }
    }

    // MARK: - NSOutlineViewDataSource

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil {
            // 仅存储设备一个 section
            return 1
        }
        if let section = item as? SidebarSection, section == .devices {
            return devices.count
        }
        return 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil {
            return SidebarSection.devices
        }
        if let section = item as? SidebarSection, section == .devices {
            return SidebarItem.device(devices[index])
        }
        return ""
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
