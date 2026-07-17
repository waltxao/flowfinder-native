import Cocoa
import SwiftUI
import Combine

// MARK: - NSViewRepresentable Wrapper

/// SwiftUI  Representable wrapper for the file list NSTableView
public struct FileListViewRepresentable: NSViewRepresentable {
    @ObservedObject var viewModel: FileEntryViewModel
    var onDoubleClick: ((FileEntry) -> Void)?

    public func makeNSView(context: Context) -> FileListView {
        let view = FileListView()
        view.viewModel = viewModel
        view.onDoubleClick = onDoubleClick
        return view
    }

    public func updateNSView(_ nsView: FileListView, context: Context) {
        nsView.viewModel = viewModel
        nsView.onDoubleClick = onDoubleClick
        nsView.reloadData()
    }
}

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
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupUI()
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
