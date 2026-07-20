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
    private var leftFileGridView: FileGridView!
    private var rightFileGridView: FileGridView!

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
        window.makeKeyAndOrderFront(nil)
        window.setFrameAutosaveName("MainWindow")
        window.isRestorable = true

        super.init(window: window)

        // 确保窗口可以接收键盘事件
        window.acceptsMouseMovedEvents = true

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

        // Left Grid View（初始隐藏）
        leftFileGridView = FileGridView()
        leftFileGridView.identifier = NSUserInterfaceItemIdentifier("left")
        leftFileGridView.translatesAutoresizingMaskIntoConstraints = false
        leftFileGridView.isHidden = true
        leftFileGridView.onDoubleClick = { [weak self] entry in
            self?.handleDoubleClick(entry, side: .left)
        }
        leftFileGridView.onSelectionChanged = { [weak self] files in
            self?.handleSelectionChanged(side: .left, files: files)
        }
        leftPaneContainer.addSubview(leftFileGridView)

        NSLayoutConstraint.activate([
            leftFileGridView.topAnchor.constraint(equalTo: leftPaneToolbar.bottomAnchor),
            leftFileGridView.leadingAnchor.constraint(equalTo: leftPaneContainer.leadingAnchor),
            leftFileGridView.trailingAnchor.constraint(equalTo: leftPaneContainer.trailingAnchor),
            leftFileGridView.bottomAnchor.constraint(equalTo: leftPaneContainer.bottomAnchor),
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

        // Right Grid View（初始隐藏）
        rightFileGridView = FileGridView()
        rightFileGridView.identifier = NSUserInterfaceItemIdentifier("right")
        rightFileGridView.translatesAutoresizingMaskIntoConstraints = false
        rightFileGridView.isHidden = true
        rightFileGridView.onDoubleClick = { [weak self] entry in
            self?.handleDoubleClick(entry, side: .right)
        }
        rightFileGridView.onSelectionChanged = { [weak self] files in
            self?.handleSelectionChanged(side: .right, files: files)
        }
        rightPaneContainer.addSubview(rightFileGridView)

        NSLayoutConstraint.activate([
            rightFileGridView.topAnchor.constraint(equalTo: rightPaneToolbar.bottomAnchor),
            rightFileGridView.leadingAnchor.constraint(equalTo: rightPaneContainer.leadingAnchor),
            rightFileGridView.trailingAnchor.constraint(equalTo: rightPaneContainer.trailingAnchor),
            rightFileGridView.bottomAnchor.constraint(equalTo: rightPaneContainer.bottomAnchor),
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

    // MARK: - Keyboard Events

    public override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags

        // Space: QuickLook 预览
        if event.keyCode == 49 && modifiers.isEmpty {
            handleQuickLook()
            return
        }

        // Enter: 打开/重命名
        if event.keyCode == 36 && modifiers.isEmpty {
            handleEnterKey()
            return
        }

        // ⌘1: 列表视图
        if event.keyCode == 18 && modifiers.contains(.command) {
            activePaneViewModel.setViewMode(.list)
            updateViewMode(side: activePane, mode: .list)
            return
        }

        // ⌘2: 网格视图
        if event.keyCode == 19 && modifiers.contains(.command) {
            activePaneViewModel.setViewMode(.grid)
            updateViewMode(side: activePane, mode: .grid)
            return
        }

        // ⌘D: 复制选中项
        if event.keyCode == 2 && modifiers.contains(.command) {
            duplicateSelected()
            return
        }

        super.keyDown(with: event)
    }

    // MARK: - Quick Look

    private func handleQuickLook() {
        let selected = activePaneViewModel.selectedFiles
        guard !selected.isEmpty else { return }

        // 获取当前面板所有可预览的文件（排除文件夹）
        let previewableFiles = activePaneViewModel.files.filter { !$0.isDirectory }
        let paths = previewableFiles.map { $0.path }

        // 找到当前选中文件的索引
        let currentPath = selected.first?.path
        let currentIndex = paths.firstIndex(of: currentPath ?? "") ?? 0

        QuickLookPreviewPanel.shared.togglePreview(files: paths, currentIndex: currentIndex)
    }

    // MARK: - Enter Key

    private func handleEnterKey() {
        guard let entry = activePaneViewModel.selectedFiles.first else { return }
        if entry.isDirectory {
            activePaneViewModel.navigate(to: entry.path)
        } else {
            NSWorkspace.shared.openFile(entry.path)
        }
    }

    // MARK: - Duplicate

    private func duplicateSelected() {
        let selected = activePaneViewModel.selectedFiles
        guard !selected.isEmpty else { return }

        let destPath = activePaneViewModel.currentPath

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            for entry in selected {
                let fileName = entry.name
                let ext = (fileName as NSString).pathExtension
                let baseName = (fileName as NSString).deletingPathExtension
                let copyName = ext.isEmpty ? "\(baseName) 副本" : "\(baseName) 副本.\(ext)"
                let dstPath = (destPath as NSString).appendingPathComponent(copyName)

                do {
                    try CoreBridge.shared.copyFile(src: entry.path, dst: dstPath)
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

        // 更新网格视图
        let grid = side == .left ? leftFileGridView : rightFileGridView
        grid?.viewModel = side == .left ? leftPaneViewModel : rightPaneViewModel
        grid?.reloadData()

        // 视图模式切换
        updateViewMode(side: side, mode: state.viewMode)
    }

    private func updateActivePaneVisual() {
        leftPaneContainer.layer?.borderWidth = activePane == .left ? 2 : 0
        leftPaneContainer.layer?.borderColor = NSColor.controlAccentColor.cgColor
        rightPaneContainer.layer?.borderWidth = activePane == .right ? 2 : 0
        rightPaneContainer.layer?.borderColor = NSColor.controlAccentColor.cgColor
    }

    private func updateViewMode(side: PaneSide, mode: ViewMode) {
        let listView = side == .left ? leftFileListView : rightFileListView
        let gridView = side == .left ? leftFileGridView : rightFileGridView

        switch mode {
        case .list:
            listView?.isHidden = false
            gridView?.isHidden = true
        case .grid:
            listView?.isHidden = true
            gridView?.isHidden = false
        }
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
        let vm = toolbar == leftPaneToolbar ? leftPaneViewModel : rightPaneViewModel
        _ = vm.goBack()
    }

    func paneToolbarDidClickForward(_ toolbar: PaneToolbar) {
        let vm = toolbar == leftPaneToolbar ? leftPaneViewModel : rightPaneViewModel
        _ = vm.goForward()
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
        // Phase 4 实现
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

// MARK: - PaneSide

enum PaneSide {
    case left
    case right
}
