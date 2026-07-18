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
        scrollView = NSScrollView(frame: bounds)
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false

        outlineView = NSOutlineView(frame: scrollView.bounds)
        outlineView.autoresizingMask = [.width, .height]
        outlineView.allowsMultipleSelection = false
        outlineView.dataSource = dataSource
        outlineView.delegate = dataSource

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("SidebarItem"))
        column.title = ""
        column.width = bounds.width
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.rowHeight = 22

        scrollView.documentView = outlineView
        addSubview(scrollView)
    }
}

// MARK: - SidebarDataSource

private class SidebarDataSource: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
    private var rootItems: [FileEntry] = []
    private var expandedItems: [URL: [FileEntry]] = [:]

    override init() {
        super.init()
        loadRootItems()
    }

    private func loadRootItems() {
        let fileManager = FileManager.default
        let homeURL = fileManager.homeDirectoryForCurrentUser

        rootItems = [
            FileEntry(path: "/", name: "Root", isDirectory: true, size: 0, modificationDate: Date()),
            FileEntry(path: homeURL.path, name: "Home", isDirectory: true, size: 0, modificationDate: Date()),
        ]

        // Add common user directories
        let commonDirectories: [FileManager.SearchPathDirectory] = [
            .desktopDirectory,
            .documentDirectory,
            .downloadsDirectory,
            .moviesDirectory,
            .musicDirectory,
            .picturesDirectory,
        ]

        for directory in commonDirectories {
            if let url = fileManager.urls(for: directory, in: .userDomainMask).first {
                let name = url.lastPathComponent
                let entry = FileEntry(path: url.path, name: name, isDirectory: true, size: 0, modificationDate: Date())
                rootItems.append(entry)
            }
        }
    }

    private func children(for item: Any?) -> [FileEntry] {
        guard let entry = item as? FileEntry else { return rootItems }
        guard entry.isDirectory else { return [] }

        let entryURL = URL(fileURLWithPath: entry.path)
        if let cached = expandedItems[entryURL] {
            return cached
        }

        var children: [FileEntry] = []
        let semaphore = DispatchSemaphore(value: 0)

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                children = try CoreBridge.shared.listDirectory(path: entry.path)
                    .filter { $0.isDirectory }
            } catch {
                print("Failed to load children for \(entry.path): \(error)")
            }
            semaphore.signal()
        }
        semaphore.wait()

        expandedItems[entryURL] = children
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
        return entry.isDirectory
    }

    // MARK: - NSOutlineViewDelegate

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let entry = item as? FileEntry else { return nil }

        let identifier = NSUserInterfaceItemIdentifier("SidebarCell")
        let cell = outlineView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView
            ?? NSTableCellView()
        cell.identifier = identifier

        let textField = NSTextField(labelWithString: entry.name)
        textField.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        textField.textColor = NSColor.labelColor
        cell.textField = textField

        let imageView = NSImageView()
        if let folderImage = NSImage(systemSymbolName: "folder", accessibilityDescription: nil) {
            imageView.image = folderImage
        }
        imageView.imageScaling = .scaleProportionallyDown
        cell.imageView = imageView

        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard let outlineView = notification.object as? NSOutlineView else { return }
        let selectedRow = outlineView.selectedRow
        guard selectedRow >= 0 else { return }

        let item = outlineView.item(atRow: selectedRow)
        guard let entry = item as? FileEntry else { return }

        NotificationCenter.default.post(
            name: .sidebarDidSelectDirectory,
            object: entry
        )
    }
}
