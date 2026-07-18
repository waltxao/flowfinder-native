import Cocoa
import Combine

// MARK: - File List View

/// NSTableView-based file list view with icon, name, size, and modified date columns
public class FileListView: NSView {
    private var tableView: NSTableView!
    private var scrollView: NSScrollView!

    public var viewModel: FileEntryViewModel?
    public var onDoubleClick: ((FileEntry) -> Void)?

    // Reuse identifiers
    private let nameCellIdentifier = NSUserInterfaceItemIdentifier("NameCell")
    private let sizeCellIdentifier = NSUserInterfaceItemIdentifier("SizeCell")
    private let modifiedCellIdentifier = NSUserInterfaceItemIdentifier("ModifiedCell")

    // Icons
    private lazy var folderIcon: NSImage? = {
        NSImage(systemSymbolName: "folder", accessibilityDescription: "Folder")
            ?? NSImage(named: NSImage.folderName)
    }()

    private lazy var fileIcon: NSImage? = {
        NSImage(systemSymbolName: "doc", accessibilityDescription: "File")
            ?? NSImage(named: NSImage.multipleDocumentsName)
    }()

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupUI()
        setupContextMenu()
        setupKeyboardShortcuts()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupUI()
        setupContextMenu()
        setupKeyboardShortcuts()
    }

    private func setupUI() {
        // Scroll view setup
        scrollView = NSScrollView(frame: bounds)
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true

        // Table view setup
        tableView = NSTableView()
        tableView.allowsMultipleSelection = false
        tableView.allowsEmptySelection = true
        tableView.allowsColumnReordering = true
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.rowHeight = 24

        // Set up data source and delegate
        tableView.dataSource = self
        tableView.delegate = self

        // Name column (with icon)
        let nameColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Name"))
        nameColumn.title = "Name"
        nameColumn.width = 400
        nameColumn.minWidth = 150
        nameColumn.maxWidth = 800
        nameColumn.sortDescriptorPrototype = NSSortDescriptor(key: "name", ascending: true)
        tableView.addTableColumn(nameColumn)

        // Size column
        let sizeColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Size"))
        sizeColumn.title = "Size"
        sizeColumn.width = 120
        sizeColumn.minWidth = 80
        sizeColumn.maxWidth = 200
        sizeColumn.sortDescriptorPrototype = NSSortDescriptor(key: "size", ascending: true)
        tableView.addTableColumn(sizeColumn)

        // Modified date column
        let modifiedColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Modified"))
        modifiedColumn.title = "Modified"
        modifiedColumn.width = 180
        modifiedColumn.minWidth = 120
        modifiedColumn.maxWidth = 300
        modifiedColumn.sortDescriptorPrototype = NSSortDescriptor(key: "modificationDate", ascending: true)
        tableView.addTableColumn(modifiedColumn)

        // Double-click handler
        tableView.target = self
        tableView.doubleAction = #selector(handleDoubleClick)

        scrollView.documentView = tableView
        addSubview(scrollView)

        // Register cell reuse identifiers
        // NSTableView.register() with class types is not available in Swift;
        // cell creation is handled in the delegate's tableView(_:viewFor:row:) method
        // using makeView(withIdentifier:owner:) for reuse.
    }

    // MARK: - Context Menu

    private func setupContextMenu() {
        let menu = NSMenu()

        // Copy
        let copyItem = NSMenuItem(
            title: "Copy",
            action: #selector(copySelectedFile(_:)),
            keyEquivalent: "c"
        )
        copyItem.keyEquivalentModifierMask = .command
        copyItem.target = self
        menu.addItem(copyItem)

        // Move
        let moveItem = NSMenuItem(
            title: "Move",
            action: #selector(moveSelectedFile(_:)),
            keyEquivalent: "x"
        )
        moveItem.keyEquivalentModifierMask = .command
        moveItem.target = self
        menu.addItem(moveItem)

        // Rename
        let renameItem = NSMenuItem(
            title: "Rename",
            action: #selector(renameSelectedFile(_:)),
            keyEquivalent: "r"
        )
        renameItem.keyEquivalentModifierMask = .command
        renameItem.target = self
        menu.addItem(renameItem)

        menu.addItem(NSMenuItem.separator())

        // Delete
        let deleteItem = NSMenuItem(
            title: "Delete",
            action: #selector(deleteSelectedFile(_:)),
            keyEquivalent: "\u{7F}"
        )
        deleteItem.keyEquivalentModifierMask = .command
        deleteItem.target = self
        menu.addItem(deleteItem)

        // Create Directory
        let createDirItem = NSMenuItem(
            title: "New Folder",
            action: #selector(createDirectory(_:)),
            keyEquivalent: "n"
        )
        createDirItem.keyEquivalentModifierMask = [.command, .shift]
        createDirItem.target = self
        menu.addItem(createDirItem)

        tableView.menu = menu
    }

    // MARK: - Keyboard Shortcuts

    private func setupKeyboardShortcuts() {
        // Keyboard shortcuts are handled by the menu items above
        // Additional shortcuts can be registered via NSResponder
    }

    public override func keyDown(with event: NSEvent) {
        guard let characters = event.charactersIgnoringModifiers else {
            super.keyDown(with: event)
            return
        }

        if characters == " " {
            handleQuickLook()
            return
        }

        super.keyDown(with: event)
    }

    private func handleQuickLook() {
        guard let entry = selectedEntry else { return }

        let path = entry.path
        if QuickLookBridge.shared.canPreview(path: path) {
            QuickLookBridge.shared.show(paths: [path])
        }
    }

    // MARK: - Context Menu Actions

    @objc private func copySelectedFile(_ sender: Any?) {
        guard let entry = selectedEntry else { return }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = entry.name
        panel.canCreateDirectories = true

        panel.beginSheetModal(for: window!) { [weak self] result in
            guard result == .OK, let url = panel.url else { return }

            self?.showProgressIndicator(title: "Copying...") { progress in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        try CoreBridge.shared.copyFile(src: entry.path, dst: url.path)
                        DispatchQueue.main.async {
                            progress.stopAnimation(nil)
                            self?.viewModel?.refresh()
                        }
                    } catch {
                        DispatchQueue.main.async {
                            progress.stopAnimation(nil)
                            self?.showErrorAlert(error: error)
                        }
                    }
                }
            }
        }
    }

    @objc private func moveSelectedFile(_ sender: Any?) {
        guard let entry = selectedEntry else { return }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = entry.name
        panel.canCreateDirectories = true

        panel.beginSheetModal(for: window!) { [weak self] result in
            guard result == .OK, let url = panel.url else { return }

            self?.showProgressIndicator(title: "Moving...") { progress in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        try CoreBridge.shared.moveFile(src: entry.path, dst: url.path)
                        DispatchQueue.main.async {
                            progress.stopAnimation(nil)
                            self?.viewModel?.refresh()
                        }
                    } catch {
                        DispatchQueue.main.async {
                            progress.stopAnimation(nil)
                            self?.showErrorAlert(error: error)
                        }
                    }
                }
            }
        }
    }

    @objc private func renameSelectedFile(_ sender: Any?) {
        guard let entry = selectedEntry else { return }

        let alert = NSAlert()
        alert.messageText = "Rename \(entry.name)"
        alert.informativeText = "Enter a new name:"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        textField.stringValue = entry.name
        alert.accessoryView = textField

        alert.beginSheetModal(for: window!) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }

            let newName = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !newName.isEmpty, newName != entry.name else { return }

            let parentPath = (entry.path as NSString).deletingLastPathComponent
            let newPath = (parentPath as NSString).appendingPathComponent(newName)

            self?.showProgressIndicator(title: "Renaming...") { progress in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        try CoreBridge.shared.renameFile(src: entry.path, dst: newPath)
                        DispatchQueue.main.async {
                            progress.stopAnimation(nil)
                            self?.viewModel?.refresh()
                        }
                    } catch {
                        DispatchQueue.main.async {
                            progress.stopAnimation(nil)
                            self?.showErrorAlert(error: error)
                        }
                    }
                }
            }
        }
    }

    @objc private func deleteSelectedFile(_ sender: Any?) {
        guard let entry = selectedEntry else { return }

        let alert = NSAlert()
        alert.messageText = entry.isDirectory ? "Delete Folder?" : "Delete File?"
        alert.informativeText = "Are you sure you want to delete \"\(entry.name)\"?\nThis action cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")

        alert.beginSheetModal(for: window!) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }

            self?.showProgressIndicator(title: "Deleting...") { progress in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        if entry.isDirectory {
                            try CoreBridge.shared.deleteDirectory(path: entry.path)
                        } else {
                            try CoreBridge.shared.deleteFile(path: entry.path)
                        }
                        DispatchQueue.main.async {
                            progress.stopAnimation(nil)
                            self?.viewModel?.refresh()
                        }
                    } catch {
                        DispatchQueue.main.async {
                            progress.stopAnimation(nil)
                            self?.showErrorAlert(error: error)
                        }
                    }
                }
            }
        }
    }

    @objc private func createDirectory(_ sender: Any?) {
        guard let currentPath = viewModel?.currentPath else { return }

        let alert = NSAlert()
        alert.messageText = "New Folder"
        alert.informativeText = "Enter a name for the new folder:"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        textField.stringValue = "New Folder"
        textField.selectText(nil)
        alert.accessoryView = textField

        alert.beginSheetModal(for: window!) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }

            let folderName = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !folderName.isEmpty else { return }

            let newPath = (currentPath as NSString).appendingPathComponent(folderName)

            self?.showProgressIndicator(title: "Creating...") { progress in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        try CoreBridge.shared.createDirectory(path: newPath)
                        DispatchQueue.main.async {
                            progress.stopAnimation(nil)
                            self?.viewModel?.refresh()
                        }
                    } catch {
                        DispatchQueue.main.async {
                            progress.stopAnimation(nil)
                            self?.showErrorAlert(error: error)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Helper Methods

    private var selectedEntry: FileEntry? {
        guard let viewModel = viewModel,
              let clickedRow = tableView?.clickedRow,
              clickedRow >= 0,
              clickedRow < viewModel.entries.count else { return nil }
        return viewModel.entries[clickedRow]
    }

    private func showProgressIndicator(title: String, action: (NSProgressIndicator) -> Void) {
        let progress = NSProgressIndicator()
        progress.style = .bar
        progress.isIndeterminate = true
        progress.startAnimation(nil)

        let alert = NSAlert()
        alert.messageText = title
        alert.accessoryView = progress
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.isHidden = true

        if let window = window {
            alert.beginSheetModal(for: window) { _ in }
        }

        action(progress)
    }

    private func showErrorAlert(error: Error) {
        let alert = NSAlert()
        alert.messageText = "Error"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .critical
        alert.addButton(withTitle: "OK")

        if let window = window {
            alert.beginSheetModal(for: window) { _ in }
        }
    }

    public override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        scrollView.frame = bounds
    }

    /// Reload table view data
    public func reloadData() {
        tableView?.reloadData()
    }

    // MARK: - Actions

    @objc private func handleDoubleClick() {
        guard let viewModel = viewModel,
              let clickedRow = tableView?.clickedRow,
              clickedRow >= 0,
              clickedRow < viewModel.entries.count else { return }

        let entry = viewModel.entries[clickedRow]
        onDoubleClick?(entry)
    }
}

// MARK: - NSTableViewDataSource

extension FileListView: NSTableViewDataSource {
    public func numberOfRows(in tableView: NSTableView) -> Int {
        return viewModel?.entries.count ?? 0
    }
}

// MARK: - NSTableViewDelegate

extension FileListView: NSTableViewDelegate {
    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let viewModel = viewModel,
              row < viewModel.entries.count else { return nil }

        let entry = viewModel.entries[row]

        switch tableColumn?.identifier.rawValue {
        case "Name":
            let cellView = tableView.makeView(withIdentifier: nameCellIdentifier, owner: self) as? FileNameTableCellView
                ?? FileNameTableCellView()
            cellView.identifier = nameCellIdentifier
            cellView.imageView?.image = entry.isDirectory ? folderIcon : fileIcon
            cellView.textField?.stringValue = entry.name
            return cellView

        case "Size":
            let cellView = tableView.makeView(withIdentifier: sizeCellIdentifier, owner: self) as? NSTableCellView
                ?? NSTableCellView()
            cellView.identifier = sizeCellIdentifier
            if cellView.textField == nil {
                let textField = NSTextField(labelWithString: "")
                textField.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
                cellView.textField = textField
            }
            cellView.textField?.stringValue = entry.isDirectory ? "--" : entry.formattedSize
            return cellView

        case "Modified":
            let cellView = tableView.makeView(withIdentifier: modifiedCellIdentifier, owner: self) as? NSTableCellView
                ?? NSTableCellView()
            cellView.identifier = modifiedCellIdentifier
            if cellView.textField == nil {
                let textField = NSTextField(labelWithString: "")
                textField.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
                cellView.textField = textField
            }
            cellView.textField?.stringValue = entry.formattedModificationDate
            return cellView

        default:
            return nil
        }
    }

    public func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        return 24
    }

    public func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        return true
    }
}

// MARK: - File Name Table Cell View

/// Custom table cell view for file names with icon
public class FileNameTableCellView: NSTableCellView {
    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupUI()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupUI()
    }

    private func setupUI() {
        // Image view
        let imageView = NSImageView()
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)
        self.imageView = imageView

        // Text field
        let textField = NSTextField(labelWithString: "")
        textField.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        textField.lineBreakMode = .byTruncatingTail
        textField.translatesAutoresizingMaskIntoConstraints = false
        addSubview(textField)
        self.textField = textField

        // Layout constraints
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 16),
            imageView.heightAnchor.constraint(equalToConstant: 16),

            textField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 6),
            textField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            textField.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }
}
