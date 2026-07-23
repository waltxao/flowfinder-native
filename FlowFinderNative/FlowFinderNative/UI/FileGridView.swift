import Cocoa
import Combine

// MARK: - FileGridCollectionViewItem

class FileGridCollectionViewItem: NSCollectionViewItem {
    private var thumbnailImageView: NSImageView!
    private var nameLabel: NSTextField!
    private var pathLabel: NSTextField!

    var entry: FileEntry? {
        didSet {
            guard let entry = entry else { return }
            nameLabel.stringValue = entry.name
            pathLabel.stringValue = entry.path

            // 设置图标
            if entry.isDirectory {
                thumbnailImageView.image = NSImage(systemSymbolName: "folder", accessibilityDescription: "文件夹")
                    ?? NSImage(named: NSImage.folderName)
            } else {
                // 使用 ThumbnailManager 获取缩略图
                ThumbnailManager.shared.generateThumbnail(path: entry.path, size: CGSize(width: 96, height: 96)) { [weak self] image in
                    if let image = image {
                        self?.thumbnailImageView.image = image
                    } else {
                        self?.thumbnailImageView.image = NSImage(systemSymbolName: "doc", accessibilityDescription: "文件")
                            ?? NSImage(named: NSImage.multipleDocumentsName)
                    }
                }
            }

            // 隐藏文件灰色
            if entry.isHidden {
                nameLabel.textColor = NSColor.tertiaryLabelColor
            } else if entry.isSystemProtected {
                nameLabel.textColor = NSColor.systemRed
            } else {
                nameLabel.textColor = NSColor.labelColor
            }
        }
    }

    override func loadView() {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 120, height: 120))
        view.wantsLayer = true

        thumbnailImageView = NSImageView()
        thumbnailImageView.imageScaling = .scaleProportionallyDown
        thumbnailImageView.translatesAutoresizingMaskIntoConstraints = false

        nameLabel = NSTextField(labelWithString: "")
        nameLabel.font = NSFont.systemFont(ofSize: 11)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.alignment = .center
        nameLabel.maximumNumberOfLines = 2
        nameLabel.translatesAutoresizingMaskIntoConstraints = false

        pathLabel = NSTextField(labelWithString: "")
        pathLabel.isHidden = true
        pathLabel.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(thumbnailImageView)
        view.addSubview(nameLabel)
        view.addSubview(pathLabel)

        NSLayoutConstraint.activate([
            thumbnailImageView.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            thumbnailImageView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            thumbnailImageView.widthAnchor.constraint(equalToConstant: 64),
            thumbnailImageView.heightAnchor.constraint(equalToConstant: 64),

            nameLabel.topAnchor.constraint(equalTo: thumbnailImageView.bottomAnchor, constant: 4),
            nameLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 4),
            nameLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -4),
            nameLabel.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -4),
        ])

        self.view = view
    }

    override var isSelected: Bool {
        didSet {
            view.layer?.backgroundColor = isSelected
                ? NSColor.controlAccentColor.withAlphaComponent(0.2).cgColor
                : NSColor.clear.cgColor
        }
    }
}

// MARK: - DraggingCollectionView

/// 自定义 NSCollectionView 子类：覆盖拖拽源操作掩码，支持同卷移动/跨卷复制
private class DraggingCollectionView: NSCollectionView {
    override func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        return [.copy, .move, .delete]
    }
}

// MARK: - FileGridView

/// NSCollectionView-based grid view with thumbnails
public class FileGridView: NSView {
    private var collectionView: NSCollectionView!
    private var scrollView: NSScrollView!
    private var cancellables = Set<AnyCancellable>()

    public var viewModel: PaneViewModel? {
        didSet {
            // 清空旧订阅，防止累积泄漏
            cancellables.removeAll()
            collectionView.dataSource = self
            collectionView.delegate = self
            viewModel?.$state
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.reloadData() }
                .store(in: &cancellables)
            reloadData()
        }
    }

    public var onDoubleClick: ((FileEntry) -> Void)?
    public var onSelectionChanged: (([FileEntry]) -> Void)?

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupUI()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupUI()
    }

    private func setupUI() {
        // 透明背景以透出 NSVisualEffectView 玻璃态
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear
        scrollView.contentView.drawsBackground = false
        scrollView.contentView.backgroundColor = .clear

        let layout = NSCollectionViewGridLayout()
        layout.minimumItemSize = NSSize(width: 120, height: 120)
        layout.maximumItemSize = NSSize(width: 120, height: 120)
        layout.minimumInteritemSpacing = 8
        layout.minimumLineSpacing = 8
        layout.margins = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)

        collectionView = DraggingCollectionView()
        collectionView.collectionViewLayout = layout
        collectionView.backgroundColors = [NSColor.clear]
        collectionView.allowsMultipleSelection = true
        collectionView.allowsEmptySelection = true
        collectionView.isSelectable = true
        collectionView.dataSource = self
        collectionView.delegate = self

        // 注册 item
        collectionView.register(FileGridCollectionViewItem.self, forItemWithIdentifier: NSUserInterfaceItemIdentifier("GridItem"))

        scrollView.documentView = collectionView
        addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        // 注册为拖拽目标（接收拖入的文件 URL）
        registerForDraggedTypes([.fileURL])

        setupContextMenu()
    }

    // MARK: - Context Menu

    private func setupContextMenu() {
        let menu = NSMenu()

        menu.addItem(withTitle: "打开", action: #selector(openSelected(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "复制", action: #selector(copySelected(_:)), keyEquivalent: "c")
        menu.addItem(withTitle: "剪切", action: #selector(cutSelected(_:)), keyEquivalent: "x")
        menu.addItem(withTitle: "粘贴", action: #selector(pasteSelected(_:)), keyEquivalent: "v")
        menu.addItem(.separator())
        menu.addItem(withTitle: "复制到另一面板", action: #selector(copyToOtherPane(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "移动到另一面板", action: #selector(moveToOtherPane(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "在对侧面板打开", action: #selector(openInOtherPane(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "重命名", action: #selector(renameSelected(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "删除", action: #selector(deleteSelected(_:)), keyEquivalent: "\u{7F}")
        menu.addItem(.separator())
        menu.addItem(withTitle: "新建文件夹", action: #selector(createDirectory(_:)), keyEquivalent: "n")
        menu.addItem(.separator())
        menu.addItem(withTitle: "添加到收藏夹", action: #selector(addToFavorites(_:)), keyEquivalent: "")

        for item in menu.items where item.action != nil {
            item.target = self
            if item.keyEquivalent == "n" {
                item.keyEquivalentModifierMask = [.command, .shift]
            } else if !item.keyEquivalent.isEmpty {
                item.keyEquivalentModifierMask = .command
            }
        }
        collectionView.menu = menu
    }

    // MARK: - Context Menu Helpers

    private var clickedEntry: FileEntry? {
        let point = collectionView.convert(NSEvent.mouseLocation, from: nil)
        guard let indexPath = collectionView.indexPathForItem(at: point),
              let viewModel = viewModel,
              indexPath.item < viewModel.files.count else { return nil }
        return viewModel.files[indexPath.item]
    }

    private func getSide() -> String {
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
        NotificationCenter.default.post(name: .fileListDidCopy, object: nil, userInfo: ["side": getSide()])
    }

    @objc private func cutSelected(_ sender: Any?) {
        NotificationCenter.default.post(name: .fileListDidCut, object: nil, userInfo: ["side": getSide()])
    }

    @objc private func pasteSelected(_ sender: Any?) {
        NotificationCenter.default.post(name: .fileListDidPaste, object: nil, userInfo: ["side": getSide()])
    }

    @objc private func copyToOtherPane(_ sender: Any?) {
        NotificationCenter.default.post(name: .fileListDidCopyToOther, object: nil, userInfo: ["side": getSide()])
    }

    @objc private func moveToOtherPane(_ sender: Any?) {
        NotificationCenter.default.post(name: .fileListDidMoveToOther, object: nil, userInfo: ["side": getSide()])
    }

    @objc private func openInOtherPane(_ sender: Any?) {
        guard let entry = clickedEntry else { return }
        NotificationCenter.default.post(name: .fileListDidOpenInOther, object: nil, userInfo: ["side": getSide(), "path": entry.path])
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
        if let window = window {
            alert.beginSheetModal(for: window) { [weak self] response in
                guard response == .alertFirstButtonReturn else { return }
                let newName = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !newName.isEmpty, newName != entry.name else { return }
                self?.viewModel?.renameFile(entry.path, to: newName)
            }
        }
    }

    @objc private func deleteSelected(_ sender: Any?) {
        let entries = viewModel?.selectedFiles ?? []
        guard !entries.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = entries.count == 1 ? "删除\"\(entries[0].name)\"？" : "删除 \(entries.count) 个项目？"
        alert.informativeText = "此操作可通过 ⌘Z 撤销。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        if let window = window {
            alert.beginSheetModal(for: window) { [weak self] response in
                guard response == .alertFirstButtonReturn else { return }
                self?.viewModel?.deleteSelected()
            }
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
        alert.accessoryView = textField
        if let window = window {
            alert.beginSheetModal(for: window) { [weak self] response in
                guard response == .alertFirstButtonReturn else { return }
                let folderName = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !folderName.isEmpty else { return }
                let newPath = (currentPath as NSString).appendingPathComponent(folderName)
                do {
                    try CoreBridge.shared.createDirectory(path: newPath)
                    self?.viewModel?.refresh()
                } catch {
                    let errAlert = NSAlert()
                    errAlert.messageText = "错误"
                    errAlert.informativeText = error.localizedDescription
                    errAlert.alertStyle = .critical
                    errAlert.addButton(withTitle: "好")
                    errAlert.beginSheetModal(for: window) { _ in }
                }
            }
        }
    }

    @objc private func addToFavorites(_ sender: Any?) {
        guard let entry = clickedEntry else { return }
        NotificationCenter.default.post(name: .fileListDidAddFavorite, object: nil, userInfo: ["name": entry.name, "path": entry.path])
    }

    public func reloadData() {
        collectionView?.reloadData()
    }
}

// MARK: - NSCollectionViewDataSource

extension FileGridView: NSCollectionViewDataSource {
    public func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        return viewModel?.files.count ?? 0
    }

    public func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: NSUserInterfaceItemIdentifier("GridItem"), for: indexPath) as! FileGridCollectionViewItem
        if let viewModel = viewModel, indexPath.item < viewModel.files.count {
            item.entry = viewModel.files[indexPath.item]
        }
        return item
    }
}

// MARK: - NSCollectionViewDelegate

extension FileGridView: NSCollectionViewDelegate {
    public func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        guard let viewModel = viewModel else { return }
        var selected: [FileEntry] = []
        for indexPath in indexPaths {
            if indexPath.item < viewModel.files.count {
                selected.append(viewModel.files[indexPath.item])
            }
        }
        onSelectionChanged?(selected)
    }

    public func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
        // 更新选择状态
        guard let viewModel = viewModel else { return }
        let selectedIndexPaths = collectionView.selectionIndexPaths
        var selected: [FileEntry] = []
        for indexPath in selectedIndexPaths {
            if indexPath.item < viewModel.files.count {
                selected.append(viewModel.files[indexPath.item])
            }
        }
        onSelectionChanged?(selected)
    }

    public func collectionView(_ collectionView: NSCollectionView, doubleClickItemAt indexPath: IndexPath) {
        guard let viewModel = viewModel, indexPath.item < viewModel.files.count else { return }
        onDoubleClick?(viewModel.files[indexPath.item])
    }

    // MARK: - Drag Source（拖出文件）

    public func collectionView(_ collectionView: NSCollectionView, canDragItemsAt indexPaths: Set<IndexPath>, with event: NSEvent) -> Bool {
        return true
    }

    /// 为每个被拖拽的 item 提供 pasteboard writer（文件 URL）
    /// NSCollectionView 会对所有选中项调用此方法，从而发送选中文件的完整路径数组
    public func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? {
        guard let viewModel = viewModel, indexPath.item < viewModel.files.count else { return nil }
        let entry = viewModel.files[indexPath.item]
        return NSURL(fileURLWithPath: entry.path)
    }

    public func collectionView(_ collectionView: NSCollectionView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint, forItemsAt indexPaths: Set<IndexPath>) {
        // 拖拽即将开始（占位，便于后续扩展）
    }

    public func collectionView(_ collectionView: NSCollectionView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint, dragOperation: NSDragOperation) {
        // 拖拽结束：若为移动/删除操作，源文件可能已被移走，需刷新当前目录
        if dragOperation == .move || dragOperation == .delete {
            viewModel?.refresh()
        }
    }
}

// MARK: - Drag and Drop（拖入目标）

extension FileGridView {
    public override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        return isMoveOperation(sender) ? .move : .copy
    }

    public override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        return isMoveOperation(sender) ? .move : .copy
    }

    public override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pasteboard = sender.draggingPasteboard

        guard let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
              !urls.isEmpty else {
            return false
        }

        let destPath = viewModel?.currentPath ?? ""
        guard !destPath.isEmpty else { return false }

        let isMove = isMoveOperation(sender)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let srcs = urls.map { $0.path }
            let total = srcs.count
            do {
                let success: Int
                if isMove {
                    success = try CoreBridge.shared.parallelMove(srcs: srcs, dstDir: destPath)
                } else {
                    success = try CoreBridge.shared.parallelCopy(srcs: srcs, dstDir: destPath)
                }

                // I2: invalidate cache so the refresh reflects the new state.
                // Destination always changes; for a move each source parent
                // directory also changes (items left those dirs). Best-effort.
                try? CoreBridge.shared.invalidateCache(path: destPath)
                if isMove {
                    let sourceDirs = Set(srcs.map { ($0 as NSString).deletingLastPathComponent })
                    for dir in sourceDirs where !dir.isEmpty {
                        try? CoreBridge.shared.invalidateCache(path: dir)
                    }
                }

                // I3: capture the detailed partial-failure message now
                // (getLastError is read-once) before the async UI refresh.
                let partialDetail = (success < total) ? CoreBridge.shared.getLastError() : ""

                // 计算 dst 路径用于撤销注册（best-effort：假设 srcs 都成功）
                let dstPaths = srcs.map { src -> String in
                    let name = (src as NSString).lastPathComponent
                    return (destPath as NSString).appendingPathComponent(name)
                }

                DispatchQueue.main.async {
                    self?.viewModel?.refresh()

                    // 注册撤销（通过 viewModel?.undoManager 访问 per-window UndoManager）
                    if success > 0, let vm = self?.viewModel, let undoManager = vm.undoManager {
                        if isMove {
                            let pairs = zip(srcs, dstPaths).map { (src: $0, dst: $1) }
                            undoManager.registerUndo(withTarget: vm) { targetVM in
                                for (src, dst) in pairs {
                                    try? CoreBridge.shared.moveFile(src: dst, dst: src)
                                }
                                targetVM.refresh()
                            }
                            undoManager.setActionName("移动 \(success) 个项目")
                        } else {
                            undoManager.registerUndo(withTarget: vm) { targetVM in
                                for dst in dstPaths {
                                    try? CoreBridge.shared.deleteFile(path: dst)
                                }
                                targetVM.refresh()
                            }
                            undoManager.setActionName("复制 \(success) 个项目")
                        }
                    }

                    if success < total {
                        self?.showError(error: NSError(
                            domain: "FlowFinder", code: -1,
                            userInfo: [NSLocalizedDescriptionKey: "\(total - success) 个项目操作失败：\(partialDetail)"])
                        )
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self?.showError(error: error)
                }
            }
        }

        return true
    }

    /// 判断是否为移动操作（同卷 + 未按 Cmd）
    private func isMoveOperation(_ sender: NSDraggingInfo) -> Bool {
        // Cmd 键切换为复制
        if sender.draggingSourceOperationMask.contains(.copy) &&
           !sender.draggingSourceOperationMask.contains(.move) {
            return false
        }

        // 检查源和目标是否在同一卷
        guard let destPath = viewModel?.currentPath else { return false }

        if let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
           let srcPath = urls.first?.path {
            return isSameVolume(srcPath: srcPath, destPath: destPath)
        }

        return false
    }

    /// 检查两个路径是否在同一卷（通过 statfs）
    private func isSameVolume(srcPath: String, destPath: String) -> Bool {
        var srcStat = statfs()
        var dstStat = statfs()

        let srcResult = srcPath.withCString { statfs($0, &srcStat) }
        let dstResult = destPath.withCString { statfs($0, &dstStat) }

        guard srcResult == 0 && dstResult == 0 else { return false }

        // 比较设备 ID (使用 memcmp 比较 fsid_t 原始字节)
        var srcFsid = srcStat.f_fsid
        var dstFsid = dstStat.f_fsid
        return withUnsafeBytes(of: &srcFsid) { srcBytes in
            withUnsafeBytes(of: &dstFsid) { dstBytes in
                srcBytes.elementsEqual(dstBytes)
            }
        }
    }
}
