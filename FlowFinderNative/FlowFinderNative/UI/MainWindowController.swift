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
    private var leftDetailsBar: ExpandableDetailsBar!
    private var rightDetailsBar: ExpandableDetailsBar!
    private var taskProgressBar: TaskProgressBar!
    private var mainSplitView: NSSplitView!
    private var paneSplitView: NSSplitView!
    /// macOS 26+: NSGlassEffectView（液态玻璃）；旧版 macOS 回退到 NSVisualEffectView
    private var glassEffectView: NSView!

    private var leftPaneToolbar: PaneToolbar!
    private var rightPaneToolbar: PaneToolbar!
    private var leftBreadcrumbBar: BreadcrumbBar!
    private var rightBreadcrumbBar: BreadcrumbBar!
    private var leftFileListView: FileListView!
    private var rightFileListView: FileListView!
    private var leftFileGridView: FileGridView!
    private var rightFileGridView: FileGridView!

    // Clipboard support (must be in main class, not extension)
    private var clipboardItems: [String] = []
    private var clipboardOperation: ClipboardOperation?

    private enum ClipboardOperation {
        case copy
        case cut
    }

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
        // 注意：不要在这里 makeKeyAndOrderFront！
        // 必须先完成 setupUI（设置 isOpaque=false, backgroundColor=.clear, NSVisualEffectView），
        // 然后再显示窗口，否则窗口会以不透明状态先渲染一次
        // window.makeKeyAndOrderFront(nil)
        // 不使用 autosave，避免加载之前保存的小窗口尺寸
        // window.setFrameAutosaveName("MainWindow")
        // window.isRestorable = true

        super.init(window: window)

        // 确保窗口可以接收键盘事件
        window.acceptsMouseMovedEvents = true

        setupUI()

        // 窗口距顶部保留 8pt 间距
        var frame = window.frame
        let screenHeight = NSScreen.main?.frame.height ?? 900
        let topGap: CGFloat = 8
        frame.origin.y = screenHeight - frame.size.height - topGap
        window.setFrame(frame, display: true)

        setupBindings()
        setupNotifications()
        loadInitialDirectories()

        // setupUI 完成后再显示窗口（此时透明设置已就绪）
        window.makeKeyAndOrderFront(nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - UI Setup

    private func setupUI() {
        guard let window = window else { return }

        // 窗口必须透明，否则玻璃效果无法模糊窗口背后的内容
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.titlebarAppearsTransparent = true

        // Sidebar
        sidebarView = SidebarView()
        sidebarView.translatesAutoresizingMaskIntoConstraints = false

        // 左面板（工具栏 + 文件列表 + DetailsBar）
        leftPaneContainer = createPaneContainer(side: .left)
        // 右面板
        rightPaneContainer = createPaneContainer(side: .right)

        // Pane Split View
        paneSplitView = NSSplitView()
        paneSplitView.isVertical = true
        paneSplitView.dividerStyle = .thin
        paneSplitView.translatesAutoresizingMaskIntoConstraints = false
        paneSplitView.delegate = self
        paneSplitView.wantsLayer = true
        paneSplitView.layer?.backgroundColor = NSColor.clear.cgColor
        paneSplitView.addArrangedSubview(leftPaneContainer)
        paneSplitView.addArrangedSubview(rightPaneContainer)

        // Main Split View
        mainSplitView = NSSplitView()
        mainSplitView.isVertical = true
        mainSplitView.dividerStyle = .thin
        mainSplitView.translatesAutoresizingMaskIntoConstraints = false
        mainSplitView.delegate = self
        mainSplitView.wantsLayer = true
        mainSplitView.layer?.backgroundColor = NSColor.clear.cgColor
        mainSplitView.addArrangedSubview(sidebarView)
        mainSplitView.addArrangedSubview(paneSplitView)

        // Task Progress Bar
        taskProgressBar = TaskProgressBar()
        taskProgressBar.translatesAutoresizingMaskIntoConstraints = false

        // Main container（透明背景以透出玻璃效果）
        let mainContainer = NSView()
        mainContainer.translatesAutoresizingMaskIntoConstraints = false
        mainContainer.wantsLayer = true
        mainContainer.layer?.backgroundColor = NSColor.clear.cgColor
        mainContainer.addSubview(mainSplitView)
        mainContainer.addSubview(taskProgressBar)
        NSLayoutConstraint.activate([
            mainSplitView.topAnchor.constraint(equalTo: mainContainer.topAnchor),
            mainSplitView.leadingAnchor.constraint(equalTo: mainContainer.leadingAnchor),
            mainSplitView.trailingAnchor.constraint(equalTo: mainContainer.trailingAnchor),
            mainSplitView.bottomAnchor.constraint(equalTo: taskProgressBar.topAnchor),

            taskProgressBar.leadingAnchor.constraint(equalTo: mainContainer.leadingAnchor),
            taskProgressBar.trailingAnchor.constraint(equalTo: mainContainer.trailingAnchor),
            taskProgressBar.bottomAnchor.constraint(equalTo: mainContainer.bottomAnchor),
            taskProgressBar.heightAnchor.constraint(equalToConstant: TaskProgressBar.height),
        ])

        // macOS 26+: NSGlassEffectView 作为窗口 contentView
        // .clear 样式：透明液态玻璃效果，模糊桌面壁纸
        // .regular 样式会变成灰色不透明，失去玻璃效果
        // 窗口透明（isOpaque=false, backgroundColor=.clear）让玻璃模糊桌面壁纸
        let glassView = NSGlassEffectView()
        glassView.style = .clear
        glassView.cornerRadius = 0
        if #available(macOS 27.0, *) {
            glassView.effectIsInteractive = true
        }
        glassView.contentView = mainContainer
        glassEffectView = glassView
        window.contentView = glassView

        // 确保玻璃效果不被 ThemeManager 覆盖
        // ThemeManager 在 AppDelegate 启动时设置 window.appearance，会破坏玻璃效果
        // 延迟到下一个 runloop 确保在 ThemeManager 之后执行
        DispatchQueue.main.async { [weak self] in
            self?.window?.appearance = nil
        }

        // Holding priorities
        mainSplitView.setHoldingPriority(.defaultLow, forSubviewAt: 0)
        mainSplitView.setHoldingPriority(.defaultHigh, forSubviewAt: 1)
        paneSplitView.setHoldingPriority(.defaultHigh, forSubviewAt: 0)
        paneSplitView.setHoldingPriority(.defaultHigh, forSubviewAt: 1)

        updateActivePaneVisual()

        // 初始 divider 位置
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.mainSplitView.setPosition(220, ofDividerAt: 0)
            let totalWidth = self.paneSplitView.bounds.width
            if totalWidth > 0 {
                self.paneSplitView.setPosition(totalWidth / 2, ofDividerAt: 0)
            }
        }

        TaskSchedulerManager.shared.startPolling()
    }

    /// 创建面板容器（工具栏 + 文件列表/网格 + DetailsBar）
    private func createPaneContainer(side: PaneSide) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.99).cgColor
        container.layer?.cornerRadius = 12
        container.layer?.masksToBounds = true

        // 面包屑导航栏
        let breadcrumbBar = BreadcrumbBar()
        breadcrumbBar.delegate = self
        breadcrumbBar.translatesAutoresizingMaskIntoConstraints = false

        // 工具栏
        let toolbar = PaneToolbar()
        toolbar.delegate = self
        toolbar.translatesAutoresizingMaskIntoConstraints = false

        // 文件列表
        let listView = FileListView()
        listView.identifier = NSUserInterfaceItemIdentifier(side == .left ? "left" : "right")
        listView.translatesAutoresizingMaskIntoConstraints = false
        listView.onDoubleClick = { [weak self] entry in
            self?.handleDoubleClick(entry, side: side)
        }
        listView.onSelectionChanged = { [weak self] files in
            self?.handleSelectionChanged(side: side, files: files)
        }
        listView.onActivatePane = { [weak self] in
            self?.activatePane(side)
        }

        // 网格视图（初始隐藏）
        let gridView = FileGridView()
        gridView.identifier = NSUserInterfaceItemIdentifier(side == .left ? "left" : "right")
        gridView.translatesAutoresizingMaskIntoConstraints = false
        gridView.isHidden = true
        gridView.onDoubleClick = { [weak self] entry in
            self?.handleDoubleClick(entry, side: side)
        }
        gridView.onSelectionChanged = { [weak self] files in
            self?.handleSelectionChanged(side: side, files: files)
        }

        // DetailsBar（每面板一个，可展开/收起）
        let detailsBar = ExpandableDetailsBar()
        detailsBar.translatesAutoresizingMaskIntoConstraints = false

        // 添加到容器
        container.addSubview(breadcrumbBar)
        container.addSubview(toolbar)
        container.addSubview(listView)
        container.addSubview(gridView)
        container.addSubview(detailsBar)

        NSLayoutConstraint.activate([
            breadcrumbBar.topAnchor.constraint(equalTo: container.topAnchor),
            breadcrumbBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            breadcrumbBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            breadcrumbBar.heightAnchor.constraint(equalToConstant: 24),

            toolbar.topAnchor.constraint(equalTo: breadcrumbBar.bottomAnchor),
            toolbar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            listView.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            listView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            listView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            listView.bottomAnchor.constraint(equalTo: detailsBar.topAnchor),

            gridView.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            gridView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            gridView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            gridView.bottomAnchor.constraint(equalTo: detailsBar.topAnchor),

            detailsBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            detailsBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            detailsBar.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            // 高度由 ExpandableDetailsBar 内部 heightConstraint 控制（收起 28 / 展开 120）
        ])

        // 保存引用
        switch side {
        case .left:
            leftPaneToolbar = toolbar
            leftBreadcrumbBar = breadcrumbBar
            leftFileListView = listView
            leftFileGridView = gridView
            leftDetailsBar = detailsBar
        case .right:
            rightPaneToolbar = toolbar
            rightBreadcrumbBar = breadcrumbBar
            rightFileListView = listView
            rightFileGridView = gridView
            rightDetailsBar = detailsBar
        }

        return container
    }

    deinit {
        TaskSchedulerManager.shared.stopPolling()
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
        // 订阅 FileListView 右键菜单通知
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleFileListCopy(_:)),
            name: .fileListDidCopy, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleFileListCut(_:)),
            name: .fileListDidCut, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleFileListPaste(_:)),
            name: .fileListDidPaste, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleFileListCopyToOther(_:)),
            name: .fileListDidCopyToOther, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleFileListMoveToOther(_:)),
            name: .fileListDidMoveToOther, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleFileListOpenInOther(_:)),
            name: .fileListDidOpenInOther, object: nil
        )
        // 订阅 QuickLook 请求
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleQuickLookRequest(_:)),
            name: .fileListRequestQuickLook, object: nil
        )
        // 订阅「添加到收藏夹」请求
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleFileListAddFavorite(_:)),
            name: .fileListDidAddFavorite, object: nil
        )
    }

    @objc private func handleQuickLookRequest(_ notification: Notification) {
        // 切换到请求的面板
        if let side = notification.userInfo?["side"] as? String {
            if side == "left" { activePane = .left } else { activePane = .right }
        }
        // 调用已有的 QuickLook 逻辑
        handleQuickLook()
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
        let breadcrumbBar = side == .left ? leftBreadcrumbBar : rightBreadcrumbBar
        let fileListView = side == .left ? leftFileListView : rightFileListView

        breadcrumbBar?.setPath(state.path)
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
            listView?.reloadData()
        case .grid:
            listView?.isHidden = true
            gridView?.isHidden = false
            gridView?.reloadData()
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
        guard let detailsBar = side == .left ? leftDetailsBar : rightDetailsBar else { return }
        if let first = files.first {
            detailsBar.update(with: first)
            detailsBar.setSelectedCount(files.count)
        } else {
            detailsBar.update(with: nil)
            detailsBar.setSelectedCount(0)
        }
    }

    func activatePane(_ side: PaneSide) {
        activePane = side
        updateActivePaneVisual()
        NotificationCenter.default.post(name: .paneDidActivate, object: nil, userInfo: ["side": side == .left ? "left" : "right"])
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

// MARK: - BreadcrumbBarDelegate

extension MainWindowController: BreadcrumbBarDelegate {
    func breadcrumbBar(_ bar: BreadcrumbBar, didSelectPath path: String) {
        let vm = bar == leftBreadcrumbBar ? leftPaneViewModel : rightPaneViewModel
        // BreadcrumbBar 按路径分隔符拆分后重组路径会丢失前导 "/"，
        // 此处补回前导斜杠以确保绝对路径正确
        let absolutePath = path.hasPrefix("/") ? path : "/" + path
        vm.navigate(to: absolutePath)
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
        let srcs = clipboardItems

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let total = srcs.count
                let success: Int
                let isMove: Bool
                switch operation {
                case .copy:
                    isMove = false
                    success = try CoreBridge.shared.parallelCopy(srcs: srcs, dstDir: destPath)
                case .cut:
                    isMove = true
                    success = try CoreBridge.shared.parallelMove(srcs: srcs, dstDir: destPath)
                }

                // I2: invalidate cache so the refresh sees the new state.
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
                // (getLastError is read-once) before the async UI refresh —
                // refresh → listDirectory would otherwise consume it on its
                // own failure path. Appended to the user-facing alert.
                let partialDetail = (success < total) ? CoreBridge.shared.getLastError() : ""

                DispatchQueue.main.async {
                    self?.activePaneViewModel.refresh()
                    if success < total {
                        self?.showError(error: NSError(
                            domain: "FlowFinder", code: -1,
                            userInfo: [NSLocalizedDescriptionKey: "\(total - success) 个项目粘贴失败：\(partialDetail)"])
                        )
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self?.showError(error: error)
                }
            }
        }
    }

    // MARK: - FileListView 右键菜单通知处理

    @objc private func handleFileListCopy(_ notification: Notification) {
        guard let side = notification.userInfo?["side"] as? String else { return }
        let vm = side == "left" ? leftPaneViewModel : rightPaneViewModel
        clipboardItems = vm.selectedFiles.map { $0.path }
        clipboardOperation = .copy
        activatePane(side == "left" ? .left : .right)
    }

    @objc private func handleFileListCut(_ notification: Notification) {
        guard let side = notification.userInfo?["side"] as? String else { return }
        let vm = side == "left" ? leftPaneViewModel : rightPaneViewModel
        clipboardItems = vm.selectedFiles.map { $0.path }
        clipboardOperation = .cut
        activatePane(side == "left" ? .left : .right)
    }

    @objc private func handleFileListPaste(_ notification: Notification) {
        guard let side = notification.userInfo?["side"] as? String else { return }
        activatePane(side == "left" ? .left : .right)
        menuPaste(self)
    }

    @objc private func handleFileListAddFavorite(_ notification: Notification) {
        guard let name = notification.userInfo?["name"] as? String,
              let path = notification.userInfo?["path"] as? String else { return }
        sidebarView.addFavorite(name: name, path: path)
    }

    // MARK: - Cross-Pane Operations

    @objc private func handleFileListCopyToOther(_ notification: Notification) {
        guard let side = notification.userInfo?["side"] as? String else { return }
        performCrossPaneOperation(side: side, isMove: false)
    }

    @objc private func handleFileListMoveToOther(_ notification: Notification) {
        guard let side = notification.userInfo?["side"] as? String else { return }
        performCrossPaneOperation(side: side, isMove: true)
    }

    @objc private func handleFileListOpenInOther(_ notification: Notification) {
        guard let side = notification.userInfo?["side"] as? String,
              let path = notification.userInfo?["path"] as? String else { return }
        let destVM: PaneViewModel = side == "left" ? rightPaneViewModel : leftPaneViewModel
        destVM.navigate(to: path)
        let destSide: PaneSide = side == "left" ? .right : .left
        activatePane(destSide)
    }

    /// 执行跨面板复制/移动操作
    private func performCrossPaneOperation(side: String, isMove: Bool) {
        let sourceVM: PaneViewModel = side == "left" ? leftPaneViewModel : rightPaneViewModel
        let destVM: PaneViewModel = side == "left" ? rightPaneViewModel : leftPaneViewModel
        let destPath = destVM.currentPath

        let selectedFiles = sourceVM.selectedFiles
        guard !selectedFiles.isEmpty else { return }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var successCount = 0
            var failedFiles: [(String, Error)] = []

            for entry in selectedFiles {
                let srcPath = entry.path
                let fileName = entry.name
                var dstPath = (destPath as NSString).appendingPathComponent(fileName)

                // 重名冲突检测 - 添加 "副本" 后缀
                if FileManager.default.fileExists(atPath: dstPath) {
                    let ext = (fileName as NSString).pathExtension
                    let nameWithoutExt = (fileName as NSString).deletingPathExtension
                    var counter = 1
                    repeat {
                        let suffixName = ext.isEmpty ? "\(nameWithoutExt) 副本 \(counter)" : "\(nameWithoutExt) 副本 \(counter).\(ext)"
                        dstPath = (destPath as NSString).appendingPathComponent(suffixName)
                        counter += 1
                    } while FileManager.default.fileExists(atPath: dstPath)
                }

                do {
                    if isMove {
                        try CoreBridge.shared.moveFile(src: srcPath, dst: dstPath)
                    } else {
                        try CoreBridge.shared.copyFile(src: srcPath, dst: dstPath)
                    }
                    successCount += 1
                } catch {
                    failedFiles.append((fileName, error))
                }
            }

            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                // 刷新双方面板
                sourceVM.refresh()
                destVM.refresh()

                // 显示错误（如果有）
                if !failedFiles.isEmpty {
                    let fileNames = failedFiles.map { $0.0 }.joined(separator: ", ")
                    self.showError(error: NSError(domain: "FlowFinder", code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "\(failedFiles.count) 个文件操作失败: \(fileNames)"]))
                }
            }
        }
    }

    // MARK: - Menu Bar Cross-Pane Actions

    @objc func menuCopyToOther(_ sender: Any?) {
        let side = activePane == .left ? "left" : "right"
        performCrossPaneOperation(side: side, isMove: false)
    }

    @objc func menuMoveToOther(_ sender: Any?) {
        let side = activePane == .left ? "left" : "right"
        performCrossPaneOperation(side: side, isMove: true)
    }

    @objc func menuOpenInOther(_ sender: Any?) {
        guard let entry = activePaneViewModel.selectedFiles.first,
              entry.isDirectory else { return }
        let destVM: PaneViewModel = activePane == .left ? rightPaneViewModel : leftPaneViewModel
        destVM.navigate(to: entry.path)
        activatePane(activePane == .left ? .right : .left)
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
        updateViewMode(side: activePane, mode: .list)
    }

    @objc func menuGridView(_ sender: Any?) {
        activePaneViewModel.setViewMode(.grid)
        updateViewMode(side: activePane, mode: .grid)
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

    @objc func menuSearch(_ sender: Any?) {
        let path = activePaneViewModel.currentPath
        SearchPanelController.shared.onNavigateToPath = { [weak self] resultPath in
            self?.activePaneViewModel.navigate(to: (resultPath as NSString).deletingLastPathComponent)
        }
        SearchPanelController.shared.showPanel(initialQuery: "", searchPath: path)
    }

    @objc func menuDuplicateScan(_ sender: Any?) {
        DuplicateScanWindowController.shared.showWindow()
    }

    @objc func menuTaskPanel(_ sender: Any?) {
        TaskPanelWindowController.shared.showWindow()
    }

    @objc func menuSettings(_ sender: Any?) {
        SettingsWindowController.shared.showWindow()
    }

    // MARK: - Helpers

    private var activePaneViewModel: PaneViewModel {
        activePane == .left ? leftPaneViewModel : rightPaneViewModel
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

// MARK: - NSSplitViewDelegate

extension MainWindowController: NSSplitViewDelegate {
    /// 限制每个面板的最小坐标，防止工具栏元素重叠
    public func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        // 主 split view（sidebar + panes）：sidebar 最小 180
        if splitView === mainSplitView {
            return 180
        }
        // pane split view（left + right panes）：每个面板最小 450
        if splitView === paneSplitView {
            return 450
        }
        return proposedMinimumPosition
    }

    /// 限制每个面板的最大坐标，防止一个面板占据过多空间
    public func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        // 主 split view：sidebar 最大 280
        if splitView === mainSplitView {
            return 280
        }
        // pane split view：留出至少 450 给另一个面板
        if splitView === paneSplitView {
            let totalWidth = splitView.bounds.width
            return max(totalWidth - 450, 450)
        }
        return proposedMaximumPosition
    }

    /// 拖动时实时更新布局
    public func splitViewDidResizeSubviews(_ notification: Notification) {
        // 触发布局更新
        if let splitView = notification.object as? NSSplitView {
            splitView.window?.layoutIfNeeded()
        }
    }
}

// MARK: - PaneSide

enum PaneSide {
    case left
    case right
}
