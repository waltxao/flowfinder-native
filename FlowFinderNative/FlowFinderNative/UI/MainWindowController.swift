import Cocoa
import SwiftUI
import Combine
import QuickLook

// MARK: - FSEventStream Helper

/// Simple FSEvents wrapper for monitoring directory changes
private class DirectoryMonitor {
    private var stream: FSEventStreamRef?
    private var callback: (() -> Void)?
    private var monitoredPaths: [String] = []

    func startMonitoring(paths: [String], callback: @escaping () -> Void) {
        self.callback = callback
        self.monitoredPaths = paths

        var context = FSEventStreamContext()
        context.info = Unmanaged.passUnretained(self).toOpaque()

        let pathsToWatch = paths as CFArray

        stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            { _, info, _, _, _, _ in
                guard let info = info else { return }
                let monitor = Unmanaged<DirectoryMonitor>.fromOpaque(info).takeUnretainedValue()
                monitor.callback?()
            },
            &context,
            pathsToWatch,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.5,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents)
        )

        if let stream = stream {
            FSEventStreamScheduleWithRunLoop(stream, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
            FSEventStreamStart(stream)
        }
    }

    func stopMonitoring() {
        if let stream = stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        stream = nil
    }

    deinit {
        stopMonitoring()
    }
}

/// Main window controller managing the primary application window
public class MainWindowController: NSWindowController {

    // MARK: - Properties

    private var viewModel = FileEntryViewModel()
    private var cancellables = Set<AnyCancellable>()
    private var searchBarView: SearchBarView!
    private var quickLookSidebar: QuickLookPreviewSidebar!
    private var isQuickLookVisible = false
    private var directoryMonitor = DirectoryMonitor()

    // Window configuration constants
    private let minWindowWidth: CGFloat = 800
    private let minWindowHeight: CGFloat = 600
    private let defaultWindowWidth: CGFloat = 1200
    private let defaultWindowHeight: CGFloat = 800

    // MARK: - Initialization

    public init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: defaultWindowWidth, height: defaultWindowHeight),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        window.title = "FlowFinder"
        window.subtitle = viewModel.currentPath
        window.minSize = NSSize(width: minWindowWidth, height: minWindowHeight)
        window.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        window.center()
        window.setFrameAutosaveName("MainWindow")
        window.isRestorable = true
        window.restorationClass = MainWindowController.self

        super.init(window: window)

        setupMenus()
        setupToolbar()
        setupContentView()
        setupBindings()
        loadInitialDirectory()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Menu Setup

    private func setupMenus() {
        guard let mainMenu = NSApp.mainMenu else { return }

        // Tools menu
        let toolsMenuItem = NSMenuItem(title: "Tools", action: nil, keyEquivalent: "")
        let toolsMenu = NSMenu(title: "Tools")
        toolsMenuItem.submenu = toolsMenu

        let scanDuplicatesItem = NSMenuItem(
            title: "Scan Duplicates",
            action: #selector(showDuplicateScan),
            keyEquivalent: "d"
        )
        scanDuplicatesItem.keyEquivalentModifierMask = [.command, .shift]
        scanDuplicatesItem.target = self
        toolsMenu.addItem(scanDuplicatesItem)

        toolsMenu.addItem(NSMenuItem.separator())

        // Clear Cache
        let clearCacheItem = NSMenuItem(
            title: "Clear Cache",
            action: #selector(clearCache),
            keyEquivalent: "k"
        )
        clearCacheItem.keyEquivalentModifierMask = [.command, .shift]
        clearCacheItem.target = self
        toolsMenu.addItem(clearCacheItem)

        mainMenu.addItem(toolsMenuItem)

        // File menu - QuickLook
        if let fileMenu = mainMenu.item(withTitle: "File")?.submenu {
            let quickLookItem = NSMenuItem(
                title: "QuickLook Preview",
                action: #selector(toggleQuickLook),
                keyEquivalent: " "
            )
            quickLookItem.target = self
            fileMenu.addItem(quickLookItem)

            let previewSidebarItem = NSMenuItem(
                title: "Toggle Preview Sidebar",
                action: #selector(togglePreviewSidebar),
                keyEquivalent: "p"
            )
            previewSidebarItem.keyEquivalentModifierMask = [.command, .option]
            previewSidebarItem.target = self
            fileMenu.addItem(previewSidebarItem)
        }
    }

    // MARK: - Toolbar Setup

    private func setupToolbar() {
        guard let window = window else { return }

        let toolbar = NSToolbar(identifier: "MainToolbar")
        toolbar.delegate = self
        toolbar.allowsUserCustomization = true
        toolbar.displayMode = .iconAndLabel
        window.toolbar = toolbar
    }

    // MARK: - Content View Setup

    private func setupContentView() {
        guard let window = window else { return }

        let contentView = ContentView()
        contentView.setViewModel(viewModel)
        contentView.onNavigate = { [weak self] entry in
            self?.viewModel.navigateToEntry(entry)
        }

        window.contentView = contentView
    }

    private func setupBindings() {
        viewModel.$currentPath
            .receive(on: DispatchQueue.main)
            .sink { [weak self] path in
                self?.window?.subtitle = path
                self?.setupDirectoryMonitor(path: path)
            }
            .store(in: &cancellables)

        viewModel.$errorMessage
            .receive(on: DispatchQueue.main)
            .compactMap { $0 }
            .sink { [weak self] errorMessage in
                self?.showError(message: errorMessage)
            }
            .store(in: &cancellables)

        NotificationCenter.default.addObserver(
            forName: .sidebarDidSelectDirectory,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let entry = notification.object as? FileEntry else { return }
            self?.viewModel.navigateToEntry(entry)
        }
    }

    private func loadInitialDirectory() {
        viewModel.loadDirectory()
    }

    // MARK: - Menu Actions

    @objc private func showDuplicateScan() {
        let scanView = DuplicateScanView()
        scanView.onDeleteDuplicates = { [weak self] groups in
            self?.showDeleteDuplicatesConfirmation(groups: groups)
        }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 500),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Scan Duplicates"
        panel.contentView = scanView
        panel.center()
        panel.makeKeyAndOrderFront(nil)
    }

    @objc private func clearCache() {
        do {
            try CoreBridge.shared.clearAllCache()
            // Refresh the current directory to show updated content
            viewModel.refresh()
        } catch {
            showError(message: "Failed to clear cache: \(error.localizedDescription)")
        }
    }

    @objc private func toggleQuickLook() {
        guard let selectedEntry = viewModel.entries.first else { return }
        QuickLookPreviewPanel.shared.togglePreview(for: selectedEntry.path)
    }

    @objc private func togglePreviewSidebar() {
        isQuickLookVisible.toggle()
        // Update content view layout based on sidebar visibility
        if let contentView = window?.contentView as? ContentView {
            contentView.needsLayout = true
        }
    }

    private func showDeleteDuplicatesConfirmation(groups: [FFDuplicateGroup]) {
        let alert = NSAlert()
        alert.messageText = "Delete Duplicates"
        alert.informativeText = "Are you sure you want to delete \(groups.count) duplicate groups? This action cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")

        alert.beginSheetModal(for: window!) { response in
            if response == .alertFirstButtonReturn {
                // Delete duplicates (keep first file in each group)
                for group in groups {
                    if group.files.count > 1 {
                        for file in group.files.dropFirst() {
                            try? CoreBridge.shared.deleteFile(path: file.path)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Directory Monitoring

    private func setupDirectoryMonitor(path: String) {
        directoryMonitor.stopMonitoring()
        directoryMonitor.startMonitoring(paths: [path]) { [weak self] in
            DispatchQueue.main.async {
                self?.viewModel.refresh()
            }
        }
    }

    // MARK: - Error Handling

    private func showError(message: String) {
        let alert = NSAlert()
        alert.messageText = "Error"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: - Window Lifecycle

    public override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
    }

    public override func windowWillLoad() {
        super.windowWillLoad()
    }

    public override func windowDidLoad() {
        super.windowDidLoad()
    }
}

// MARK: - NSToolbarDelegate

extension MainWindowController: NSToolbarDelegate {

    public func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch itemIdentifier.rawValue {
        case "SearchBar":
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            searchBarView = SearchBarView(frame: NSRect(x: 0, y: 0, width: 300, height: 32))
            searchBarView.onSearch = { [weak self] query in
                self?.performSearch(query: query)
            }
            searchBarView.onFilterChanged = { [weak self] filters in
                self?.performSearchWithFilters(filters: filters)
            }
            item.view = searchBarView
            item.minSize = NSSize(width: 200, height: 32)
            item.maxSize = NSSize(width: 400, height: 32)
            return item

        case "QuickLookToggle":
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Preview"
            item.image = NSImage(systemSymbolName: "eye", accessibilityDescription: "Preview")
            item.target = self
            item.action = #selector(toggleQuickLook)
            return item

        default:
            return nil
        }
    }

    public func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        return [
            NSToolbarItem.Identifier("SearchBar"),
            .flexibleSpace,
            NSToolbarItem.Identifier("QuickLookToggle")
        ]
    }

    public func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        return [
            NSToolbarItem.Identifier("SearchBar"),
            NSToolbarItem.Identifier("QuickLookToggle"),
            .flexibleSpace,
            .space
        ]
    }

    // MARK: - Search

    private func performSearch(query: String) {
        guard !query.isEmpty else {
            viewModel.loadDirectory()
            return
        }

        SearchBridge.shared.search(
            path: viewModel.currentPath,
            query: query,
            resultHandler: { [weak self] result in
                // Results are collected and displayed
            },
            completion: { [weak self] error in
                if let error = error {
                    self?.showError(message: error.localizedDescription)
                }
            }
        )
    }

    private func performSearchWithFilters(filters: SearchFilters) {
        // Convert to FFSearchFilters and perform filtered search
        let ffFilters = FFSearchFilters(
            fileTypes: filters.fileTypes,
            minSize: filters.minSize,
            maxSize: filters.maxSize
        )

        SearchBridge.shared.searchWithFilters(
            path: viewModel.currentPath,
            query: "",
            filters: ffFilters,
            resultHandler: { [weak self] result in
                // Results are collected and displayed
            },
            completion: { [weak self] error in
                if let error = error {
                    self?.showError(message: error.localizedDescription)
                }
            }
        )
    }
}

// MARK: - NSWindowRestoration

extension MainWindowController: NSWindowRestoration {
    public static func restoreWindow(withIdentifier identifier: NSUserInterfaceItemIdentifier,
                                      state: NSCoder,
                                      completionHandler: @escaping (NSWindow?, Error?) -> Void) {
        let controller = MainWindowController()
        completionHandler(controller.window, nil)
    }
}
