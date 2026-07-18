import Cocoa
import QuickLook

// MARK: - Search Bar View

/// Search bar with filter options for the main window toolbar
public class SearchBarView: NSView {

    private var searchField: NSSearchField!
    private var filterButton: NSButton!

    public var onSearch: ((String) -> Void)?
    public var onFilterChanged: ((SearchFilters) -> Void)?

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupUI()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupUI()
    }

    private func setupUI() {
        // Search field
        searchField = NSSearchField()
        searchField.placeholderString = "Search files..."
        searchField.target = self
        searchField.action = #selector(searchFieldChanged)
        searchField.translatesAutoresizingMaskIntoConstraints = false

        // Filter button
        filterButton = NSButton(title: "", target: self, action: #selector(showFilterPopover))
        filterButton.image = NSImage(systemSymbolName: "line.3.horizontal.decrease.circle", accessibilityDescription: "Filter")
        filterButton.bezelStyle = .texturedRounded
        filterButton.translatesAutoresizingMaskIntoConstraints = false

        addSubview(searchField)
        addSubview(filterButton)

        NSLayoutConstraint.activate([
            searchField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            searchField.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            searchField.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            searchField.trailingAnchor.constraint(equalTo: filterButton.leadingAnchor, constant: -8),

            filterButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            filterButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            filterButton.widthAnchor.constraint(equalToConstant: 28),
            filterButton.heightAnchor.constraint(equalToConstant: 28)
        ])
    }

    @objc private func searchFieldChanged() {
        onSearch?(searchField.stringValue)
    }

    @objc private func showFilterPopover() {
        // Filter popover disabled in AppKit-only build
        onFilterChanged?(SearchFilters())
    }
}

// MARK: - Search Filters

/// Search filter criteria
public struct SearchFilters {
    public var fileTypes: String?
    public var minSize: UInt64?
    public var maxSize: UInt64?
    public var modifiedAfter: Date?
    public var modifiedBefore: Date?

    public init(fileTypes: String? = nil, minSize: UInt64? = nil, maxSize: UInt64? = nil,
                modifiedAfter: Date? = nil, modifiedBefore: Date? = nil) {
        self.fileTypes = fileTypes
        self.minSize = minSize
        self.maxSize = maxSize
        self.modifiedAfter = modifiedAfter
        self.modifiedBefore = modifiedBefore
    }
}

// MARK: - Search Results View

/// View for displaying search results with highlighted text
public class SearchResultsView: NSView, NSTableViewDataSource, NSTableViewDelegate {

    private var tableView: NSTableView!
    private var scrollView: NSScrollView!

    public var searchResults: [FFSearchResult] = [] {
        didSet {
            tableView?.reloadData()
        }
    }

    public var searchQuery: String = "" {
        didSet {
            tableView?.reloadData()
        }
    }

    public var onSelectResult: ((FFSearchResult) -> Void)?

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupUI()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupUI()
    }

    private func setupUI() {
        scrollView = NSScrollView(frame: bounds)
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true

        tableView = NSTableView()
        tableView.allowsMultipleSelection = false
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.usesAlternatingRowBackgroundColors = true

        let nameColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Name"))
        nameColumn.title = "Name"
        nameColumn.width = 300
        tableView.addTableColumn(nameColumn)

        let pathColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Path"))
        pathColumn.title = "Path"
        pathColumn.width = 400
        tableView.addTableColumn(pathColumn)

        let sizeColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Size"))
        sizeColumn.title = "Size"
        sizeColumn.width = 100
        tableView.addTableColumn(sizeColumn)

        tableView.dataSource = self
        tableView.delegate = self

        scrollView.documentView = tableView
        addSubview(scrollView)
    }

    public func numberOfRows(in tableView: NSTableView) -> Int {
        return searchResults.count
    }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < searchResults.count else { return nil }

        let result = searchResults[row]
        let cellView = NSTableCellView()
        let textField = NSTextField(labelWithString: "")
        textField.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        cellView.textField = textField

        switch tableColumn?.identifier.rawValue {
        case "Name":
            textField.attributedStringValue = highlightMatches(text: result.name, query: searchQuery)
        case "Path":
            textField.stringValue = result.path
        case "Size":
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            textField.stringValue = formatter.string(fromByteCount: Int64(result.size))
        default:
            break
        }

        return cellView
    }

    private func highlightMatches(text: String, query: String) -> NSAttributedString {
        let attributedString = NSMutableAttributedString(string: text)

        if query.isEmpty {
            return attributedString
        }

        let lowerText = text.lowercased()
        let lowerQuery = query.lowercased()

        var searchIndex = lowerText.startIndex
        while let range = lowerText[searchIndex...].range(of: lowerQuery) {
            let startIndex = lowerText.distance(from: lowerText.startIndex, to: range.lowerBound)
            let endIndex = lowerText.distance(from: lowerText.startIndex, to: range.upperBound)

            let nsRange = NSRange(location: startIndex, length: endIndex - startIndex)
            attributedString.addAttribute(.backgroundColor, value: NSColor.yellow, range: nsRange)

            searchIndex = range.upperBound
        }

        return attributedString
    }
}
