import Cocoa

class FileListView: NSView {
    private var tableView: NSTableView!
    private var scrollView: NSScrollView!

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

        tableView = NSTableView()
        tableView.allowsMultipleSelection = true
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("FileName"))
        column.title = "Name"
        column.width = 300
        tableView.addTableColumn(column)

        scrollView.documentView = tableView
        addSubview(scrollView)
    }
}
