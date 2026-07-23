import Cocoa
import Combine

// MARK: - FileListView

/// NSTableView-based file list view with 4 columns (名称/修改日期/类型/大小)
public class FileListView: NSView {
    private var tableView: NSTableView!
    private var scrollView: NSScrollView!
    private var cancellables = Set<AnyCancellable>()
    private var lastFilesCount: Int = -1

    // 内联重命名状态
    private var renamingRow: Int = -1
    private var renamingOriginalName: String = ""
    private var renamingPath: String = ""
    private weak var renamingTextField: NSTextField?
    private var renameCancelled: Bool = false

    public var viewModel: PaneViewModel? {
        didSet {
            // 清空旧订阅，防止累积泄漏
            cancellables.removeAll()
            tableView.dataSource = self
            tableView.delegate = self
            viewModel?.$state
                .receive(on: DispatchQueue.main)
                .sink { [weak self] state in
                    // 仅在 files 数量变化时才 reloadData（避免 isLoading/error 等变化触发不必要的刷新）
                    guard let self = self else { return }
                    if self.lastFilesCount != state.files.count {
                        self.lastFilesCount = state.files.count
                        self.reloadData()
                    }
                }
                .store(in: &cancellables)
            reloadData()
        }
    }

    /// 对侧面板的 ViewModel（由 MainWindowController 在 setupUI 中注入），
    /// 用于拖拽 undo/redo 后刷新对侧面板（跨面板拖拽时源面板需同步更新）
    weak var counterpartViewModel: PaneViewModel?

    public var onDoubleClick: ((FileEntry) -> Void)?
    public var onSelectionChanged: (([FileEntry]) -> Void)?
    public var onActivatePane: (() -> Void)?

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
        // 透明背景以透出 NSVisualEffectView 玻璃态
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true

        tableView = NSTableView()
        tableView.allowsMultipleSelection = true
        tableView.allowsEmptySelection = true
        tableView.allowsColumnReordering = false
        tableView.allowsColumnResizing = true
        // 使用系统默认蓝色高亮（确保单击选中可见）
        tableView.selectionHighlightStyle = .regular
        // 使用 firstColumnOnlyAutoresizingStyle：名称列自动填充剩余空间，其他列保持固定宽度
        tableView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.rowHeight = 24
        // 半透明背景：既保持玻璃通透感，又确保选中高亮可见
        tableView.backgroundColor = NSColor.textBackgroundColor.withAlphaComponent(0.85)
        tableView.enclosingScrollView?.drawsBackground = false
        scrollView.drawsBackground = false
        scrollView.backgroundColor = NSColor.clear
        // NSClipView 默认绘制 controlBackgroundColor（浅灰），必须显式清除
        scrollView.contentView.drawsBackground = false
        scrollView.contentView.backgroundColor = .clear
        tableView.dataSource = self
        tableView.delegate = self

        // 列顺序：名称 → 修改日期 → 类型 → 大小（匹配 macOS Finder）
        // 名称列（带图标）— 自动调整宽度
        let nameCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        nameCol.title = "名称"
        nameCol.width = 200
        nameCol.minWidth = 80
        nameCol.maxWidth = 1000
        nameCol.resizingMask = [.userResizingMask, .autoresizingMask]
        nameCol.sortDescriptorPrototype = NSSortDescriptor(key: "name", ascending: true)
        tableView.addTableColumn(nameCol)

        // 修改日期列
        let modifiedCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("modifiedAt"))
        modifiedCol.title = "修改日期"
        modifiedCol.width = 130
        modifiedCol.minWidth = 80
        modifiedCol.resizingMask = [.userResizingMask]
        modifiedCol.sortDescriptorPrototype = NSSortDescriptor(key: "modifiedAt", ascending: true)
        tableView.addTableColumn(modifiedCol)

        // 类型列
        let typeCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("type"))
        typeCol.title = "类型"
        typeCol.width = 80
        typeCol.minWidth = 50
        typeCol.resizingMask = [.userResizingMask]
        typeCol.sortDescriptorPrototype = NSSortDescriptor(key: "type", ascending: true)
        tableView.addTableColumn(typeCol)

        // 大小列
        let sizeCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("size"))
        sizeCol.title = "大小"
        sizeCol.width = 70
        sizeCol.minWidth = 40
        sizeCol.resizingMask = [.userResizingMask]
        sizeCol.sortDescriptorPrototype = NSSortDescriptor(key: "size", ascending: true)
        tableView.addTableColumn(sizeCol)

        // Double-click
        tableView.target = self
        tableView.doubleAction = #selector(handleDoubleClick)

        scrollView.documentView = tableView
        addSubview(scrollView)

        // 使用 Auto Layout 约束确保 scrollView 正确填充
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        // 强制重新计算列宽
        tableView.sizeToFit()

        // 注册为拖拽目标
        registerForDraggedTypes([.fileURL])

        // 启用拖拽源（通过 tableView）
        tableView.setDraggingSourceOperationMask([.copy, .move, .delete], forLocal: false)
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
        alert.informativeText = "此操作可通过 ⌘Z 撤销。"
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

    @objc private func addToFavorites(_ sender: Any?) {
        guard let entry = clickedEntry else { return }
        NotificationCenter.default.post(name: .fileListDidAddFavorite, object: nil, userInfo: ["name": entry.name, "path": entry.path])
    }

    // MARK: - Cross-Pane Actions

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

    // MARK: - Drag Source

    /// 开始拖拽（在 tableView 的 mouseDown 中触发）
    @objc private func handleTableDrag() {
        guard let viewModel = viewModel,
              let selectedRow = tableView.selectedRow as Int?,
              selectedRow >= 0, selectedRow < viewModel.files.count else { return }

        let entry = viewModel.files[selectedRow]
        let url = URL(fileURLWithPath: entry.path)

        let draggingItem = NSDraggingItem(pasteboardWriter: url as NSURL)
        draggingItem.setDraggingFrame(tableView.rect(ofRow: selectedRow), contents: nil)

        beginDraggingSession(with: [draggingItem], event: NSApp.currentEvent!, source: self)
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

        // Ensure text field exists (NSTableCellView handles layout)
        if cellView.textField == nil {
            let tf = NSTextField(labelWithString: "")
            tf.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
            tf.lineBreakMode = .byTruncatingTail
            tf.translatesAutoresizingMaskIntoConstraints = false
            cellView.addSubview(tf)
            cellView.textField = tf
            NSLayoutConstraint.activate([
                tf.leadingAnchor.constraint(equalTo: cellView.leadingAnchor, constant: 4),
                tf.trailingAnchor.constraint(equalTo: cellView.trailingAnchor, constant: -4),
                tf.centerYAnchor.constraint(equalTo: cellView.centerYAnchor),
            ])
        }

        switch tableColumn?.identifier.rawValue {
        case "name":
            cellView.textField?.stringValue = entry.name
            // 隐藏文件灰色，系统保护文件红色
            if entry.isSystemProtected {
                cellView.textField?.textColor = NSColor.systemRed
            } else if entry.isHidden {
                cellView.textField?.textColor = NSColor.tertiaryLabelColor
            } else {
                cellView.textField?.textColor = NSColor.labelColor
            }
            // 使用 Auto Layout 约束布局 imageView，避免手动 frame 冲突
            if cellView.imageView == nil {
                let iv = NSImageView()
                iv.imageScaling = .scaleProportionallyDown
                iv.translatesAutoresizingMaskIntoConstraints = false
                cellView.imageView = iv
                cellView.addSubview(iv)
                NSLayoutConstraint.activate([
                    iv.leadingAnchor.constraint(equalTo: cellView.leadingAnchor, constant: 4),
                    iv.centerYAnchor.constraint(equalTo: cellView.centerYAnchor),
                    iv.widthAnchor.constraint(equalToConstant: 18),
                    iv.heightAnchor.constraint(equalToConstant: 18),
                ])
                // 更新 textField 的 leading 约束到 imageView 之后
                if let tf = cellView.textField {
                    // 移除旧的 leading 约束并添加新的
                    cellView.removeConstraints(cellView.constraints.filter {
                        $0.firstItem === tf && $0.firstAttribute == .leading
                    })
                    tf.leadingAnchor.constraint(equalTo: iv.trailingAnchor, constant: 4).isActive = true
                }
            }
            // 使用 NSWorkspace.shared.icon(forFile:) 获取真实文件图标（访达风格）
            // 文件夹、应用、图片、文档等都会显示正确的系统图标
            let workspaceIcon = NSWorkspace.shared.icon(forFile: entry.path)
            workspaceIcon.size = NSSize(width: 18, height: 18)
            cellView.imageView?.image = workspaceIcon

            // 非目录文件额外异步加载 QuickLook 缩略图（图片、视频等预览）
            if !entry.isDirectory {
                let path = entry.path
                ThumbnailManager.shared.generateThumbnail(path: path, size: CGSize(width: 32, height: 32)) { [weak cellView] image in
                    guard let image = image else { return }
                    if cellView?.textField?.stringValue == entry.name {
                        cellView?.imageView?.image = image
                    }
                }
            }

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
        return true
    }

    // 选择变更时才执行选择逻辑（单击选中、Cmd+点击多选、Shift+范围选）
    public func tableViewSelectionDidChange(_ notification: Notification) {
        guard let viewModel = viewModel else { return }
        // 确保 tableView 是 firstResponder，否则选中高亮会变成灰色（de-emphasized）
        if let window = tableView.window, window.firstResponder !== tableView {
            window.makeFirstResponder(tableView)
        }
        let selectedRows = tableView.selectedRowIndexes
        let entries = selectedRows.compactMap { idx -> FileEntry? in
            guard idx >= 0, idx < viewModel.files.count else { return nil }
            return viewModel.files[idx]
        }
        // 同步更新 viewModel 的选择状态
        viewModel.state.selectedFiles = entries
        // 异步触发回调，避免阻塞双击事件
        DispatchQueue.main.async { [weak self] in
            self?.onSelectionChanged?(entries)
        }
    }
}

// MARK: - Keyboard Events

extension FileListView {
    /// 重写 mouseDown，先激活面板再传递事件给 tableView 处理选中
    public override func mouseDown(with event: NSEvent) {
        onActivatePane?()
        super.mouseDown(with: event)
    }

    /// 重写 keyDown，空格键触发 QuickLook 预览，Enter 触发内联重命名
    public override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags

        // Space: QuickLook 预览
        if event.keyCode == 49 && modifiers.isEmpty {
            // 发送通知让 MainWindowController 处理
            NotificationCenter.default.post(name: .fileListRequestQuickLook, object: nil, userInfo: ["side": getSide()])
            return
        }

        // Enter / Return：触发内联重命名（拦截事件，不再沿响应链传递到 MainWindowController 的打开逻辑）
        if (event.keyCode == 36 || event.keyCode == 76) && modifiers.isEmpty {
            beginInlineRename()
            return
        }

        // 其他键传给 nextResponder（沿响应链传递到 MainWindowController）
        super.keyDown(with: event)
    }

    // MARK: - Inline Rename（内联重命名）

    /// 开始内联重命名：选中单个文件时按 Enter 触发
    private func beginInlineRename() {
        // 正在重命名时不重复触发
        guard renamingRow < 0 else { return }
        guard let viewModel = viewModel else { return }

        // 仅单选时触发重命名
        let selectedRows = tableView.selectedRowIndexes
        guard selectedRows.count == 1, let row = selectedRows.first,
              row >= 0, row < viewModel.files.count else { return }

        let entry = viewModel.files[row]

        // 获取名称列的 cell view
        guard let cellView = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? NSTableCellView,
              let textField = cellView.textField else { return }

        // 记录重命名上下文
        renamingRow = row
        renamingOriginalName = entry.name
        renamingPath = entry.path
        renamingTextField = textField
        renameCancelled = false

        // 进入编辑模式：将名称 textField 设为可编辑并获取焦点
        textField.isEditable = true
        textField.isSelectable = true
        textField.delegate = self

        guard window?.makeFirstResponder(textField) == true else {
            // 无法进入编辑模式，清理状态
            textField.isEditable = false
            textField.delegate = nil
            renamingRow = -1
            renamingOriginalName = ""
            renamingPath = ""
            renamingTextField = nil
            renameCancelled = false
            return
        }

        // 选中文件名（不含扩展名），与访达行为一致
        if let editor = textField.currentEditor() {
            let name = entry.name as NSString
            let extRange = name.range(of: ".", options: .backwards)
            if entry.isDirectory || extRange.location == NSNotFound || extRange.location == 0 {
                editor.selectAll(nil)
            } else {
                editor.selectedRange = NSRange(location: 0, length: extRange.location)
            }
        }
    }

    /// 结束内联重命名，根据取消标志决定是否提交
    private func endInlineRename() {
        guard renamingRow >= 0 else { return }
        let textField = renamingTextField
        let originalName = renamingOriginalName
        let path = renamingPath
        let cancelled = renameCancelled

        // 清理状态
        renamingRow = -1
        renamingOriginalName = ""
        renamingPath = ""
        renamingTextField = nil
        renameCancelled = false

        // 恢复 textField 为非编辑状态
        textField?.delegate = nil
        if let tf = textField {
            tf.isEditable = false
            // 取消时恢复原名称显示
            if cancelled {
                tf.stringValue = originalName
            }
        }

        // 取消则不重命名
        guard !cancelled else { return }

        // 提交重命名（复用 viewModel.renameFile，与右键菜单重命名一致）
        guard let tf = textField else { return }
        let newName = tf.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newName.isEmpty, newName != originalName else { return }
        viewModel?.renameFile(path, to: newName)
    }
}

// MARK: - NSTextFieldDelegate（内联重命名编辑事件）

extension FileListView: NSTextFieldDelegate {
    /// 处理编辑中的特殊按键（Enter 确认 / Esc 取消）
    public func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.cancelOperation(_:)):
            // Esc：取消重命名
            renameCancelled = true
            window?.makeFirstResponder(tableView)
            return true
        case #selector(NSResponder.insertNewline(_:)):
            // Enter/Return：确认重命名（交还焦点触发 controlTextDidEndEditing）
            window?.makeFirstResponder(tableView)
            return true
        default:
            return false
        }
    }

    /// 编辑结束（Enter 确认 / 失焦自动确认 / Esc 取消）
    public func controlTextDidEndEditing(_ obj: Notification) {
        guard renamingRow >= 0 else { return }
        endInlineRename()
    }
}

// MARK: - Drag and Drop

extension FileListView: NSDraggingSource {
    public func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        return [.copy, .move, .delete]
    }
}

extension FileListView {
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
                        let counterpart = self?.counterpartViewModel
                        if isMove {
                            let pairs = zip(srcs, dstPaths).map { (src: $0, dst: $1) }
                            undoManager.registerUndo(withTarget: vm) { [weak counterpart] targetVM in
                                // undo: 移回原位
                                for (src, dst) in pairs {
                                    try? CoreBridge.shared.moveFile(src: dst, dst: src)
                                }
                                // 注册 redo：再次移动
                                targetVM.undoManager?.registerUndo(withTarget: targetVM) { [weak counterpart] vm2 in
                                    for (src, dst) in pairs {
                                        try? CoreBridge.shared.moveFile(src: src, dst: dst)
                                    }
                                    vm2.refresh()
                                    counterpart?.refresh()
                                }
                                targetVM.undoManager?.setActionName("移动 \(success) 个项目")
                                // I1: 刷新双面板（跨面板移动 undo 后源面板需同步）
                                targetVM.refresh()
                                counterpart?.refresh()
                            }
                            undoManager.setActionName("移动 \(success) 个项目")
                        } else {
                            let pairs = zip(srcs, dstPaths).map { (src: $0, dst: $1) }
                            undoManager.registerUndo(withTarget: vm) { [weak counterpart] targetVM in
                                // undo: 删除复制项
                                for (_, dst) in pairs {
                                    try? CoreBridge.shared.deleteFile(path: dst)
                                }
                                // 注册 redo：重新复制
                                targetVM.undoManager?.registerUndo(withTarget: targetVM) { [weak counterpart] vm2 in
                                    for (src, dst) in pairs {
                                        try? CoreBridge.shared.copyFile(src: src, dst: dst)
                                    }
                                    vm2.refresh()
                                    counterpart?.refresh()
                                }
                                targetVM.undoManager?.setActionName("复制 \(success) 个项目")
                                // I1: 刷新双面板
                                targetVM.refresh()
                                counterpart?.refresh()
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

// MARK: - Notification Names

extension Notification.Name {
    static let fileListDidCopy = Notification.Name("fileListDidCopy")
    static let fileListDidCut = Notification.Name("fileListDidCut")
    static let fileListDidPaste = Notification.Name("fileListDidPaste")
    static let fileListDidCopyToOther = Notification.Name("fileListDidCopyToOther")
    static let fileListDidMoveToOther = Notification.Name("fileListDidMoveToOther")
    static let fileListDidOpenInOther = Notification.Name("fileListDidOpenInOther")
    static let fileListRequestQuickLook = Notification.Name("fileListRequestQuickLook")
    static let fileListDidAddFavorite = Notification.Name("fileListDidAddFavorite")
}
