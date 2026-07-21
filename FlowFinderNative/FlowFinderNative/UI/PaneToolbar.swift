import Cocoa
import Combine

// MARK: - PaneToolbarDelegate

protocol PaneToolbarDelegate: AnyObject {
    func paneToolbarDidClickBack(_ toolbar: PaneToolbar)
    func paneToolbarDidClickForward(_ toolbar: PaneToolbar)
    func paneToolbarDidClickUp(_ toolbar: PaneToolbar)
    func paneToolbarDidClickRefresh(_ toolbar: PaneToolbar)
    func paneToolbar(_ toolbar: PaneToolbar, didChangeSearchQuery query: String)
    func paneToolbar(_ toolbar: PaneToolbar, didChangeSortField field: SortField, ascending: Bool)
    func paneToolbar(_ toolbar: PaneToolbar, didChangeGroupBy groupBy: String)
    func paneToolbar(_ toolbar: PaneToolbar, didChangeViewMode mode: ViewMode)
    func paneToolbar(_ toolbar: PaneToolbar, didClickPath path: String)
}

// MARK: - PaneToolbar

class PaneToolbar: NSView {
    weak var delegate: PaneToolbarDelegate?

    private var path: String = ""

    // Row 1: Navigation + Breadcrumb
    private var backButton: NSButton!
    private var forwardButton: NSButton!
    private var upButton: NSButton!
    private var refreshButton: NSButton!
    private var breadcrumbScrollView: NSScrollView!
    private var breadcrumbStack: NSStackView!

    // Row 2: Search + Sort + Group + View
    private var searchField: NSSearchField!
    private var sortPopup: NSPopUpButton!
    private var sortDirectionButton: NSButton!
    private var groupPopup: NSPopUpButton!
    private var listViewButton: NSButton!
    private var gridViewButton: NSButton!

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupUI()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupUI()
    }

    private func setupUI() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.masksToBounds = true

        // 固定双行高度 72pt（每行 32 + 间距 4 + 边距 4）
        heightAnchor.constraint(equalToConstant: 72).isActive = true

        setupRow1()
        setupRow2()
    }

    // MARK: - Row 1: Navigation + Breadcrumb

    private func setupRow1() {
        backButton = createNavButton(systemSymbol: "chevron.backward", action: #selector(backClicked))
        forwardButton = createNavButton(systemSymbol: "chevron.forward", action: #selector(forwardClicked))
        upButton = createNavButton(systemSymbol: "chevron.up", action: #selector(upClicked))
        refreshButton = createNavButton(systemSymbol: "arrow.clockwise", action: #selector(refreshClicked))

        breadcrumbStack = NSStackView()
        breadcrumbStack.orientation = .horizontal
        breadcrumbStack.alignment = .centerY
        breadcrumbStack.spacing = 2
        breadcrumbStack.detachesHiddenViews = false
        breadcrumbStack.translatesAutoresizingMaskIntoConstraints = false
        breadcrumbStack.edgeInsets = NSEdgeInsets(top: 0, left: 4, bottom: 0, right: 4)

        breadcrumbScrollView = NSScrollView()
        breadcrumbScrollView.translatesAutoresizingMaskIntoConstraints = false
        breadcrumbScrollView.hasHorizontalScroller = false
        breadcrumbScrollView.hasVerticalScroller = false
        breadcrumbScrollView.autohidesScrollers = true
        breadcrumbScrollView.drawsBackground = false
        breadcrumbScrollView.backgroundColor = .clear
        breadcrumbScrollView.contentView.drawsBackground = false
        breadcrumbScrollView.contentView.backgroundColor = .clear
        breadcrumbScrollView.documentView = breadcrumbStack

        let row1 = NSStackView(views: [backButton, forwardButton, upButton, refreshButton, breadcrumbScrollView])
        row1.orientation = .horizontal
        row1.alignment = .centerY
        row1.spacing = 4
        row1.detachesHiddenViews = false
        row1.translatesAutoresizingMaskIntoConstraints = false
        row1.setContentHuggingPriority(.defaultHigh, for: .vertical)
        addSubview(row1)

        NSLayoutConstraint.activate([
            row1.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            row1.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            row1.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            row1.heightAnchor.constraint(equalToConstant: 32),

            breadcrumbScrollView.heightAnchor.constraint(equalToConstant: 28),
        ])
    }

    // MARK: - Row 2: Search + Sort + Group + View

    private func setupRow2() {
        searchField = NSSearchField()
        searchField.placeholderString = "搜索当前目录"
        searchField.target = self
        searchField.action = #selector(searchChanged)
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        searchField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        sortPopup = NSPopUpButton()
        sortPopup.addItems(withTitles: SortField.allCases.map { $0.rawValue })
        sortPopup.target = self
        sortPopup.action = #selector(sortSelected(_:))
        sortPopup.translatesAutoresizingMaskIntoConstraints = false

        sortDirectionButton = NSButton()
        sortDirectionButton.image = NSImage(systemSymbolName: "chevron.up", accessibilityDescription: "升序")
        sortDirectionButton.bezelStyle = .texturedRounded
        sortDirectionButton.target = self
        sortDirectionButton.action = #selector(sortDirectionToggled)
        sortDirectionButton.translatesAutoresizingMaskIntoConstraints = false

        groupPopup = NSPopUpButton()
        groupPopup.addItems(withTitles: ["无分组", "按种类", "按日期", "按大小"])
        groupPopup.target = self
        groupPopup.action = #selector(groupSelected(_:))
        groupPopup.translatesAutoresizingMaskIntoConstraints = false

        listViewButton = createViewButton(systemSymbol: "list.bullet", action: #selector(listViewClicked))
        gridViewButton = createViewButton(systemSymbol: "square.grid.2x2", action: #selector(gridViewClicked))

        updateViewModeHighlight(.list)

        let row2 = NSStackView(views: [
            searchField,
            sortPopup, sortDirectionButton,
            groupPopup,
            listViewButton, gridViewButton,
        ])
        row2.orientation = .horizontal
        row2.alignment = .centerY
        row2.spacing = 4
        row2.detachesHiddenViews = false
        row2.translatesAutoresizingMaskIntoConstraints = false
        row2.setContentHuggingPriority(.defaultHigh, for: .vertical)
        addSubview(row2)

        NSLayoutConstraint.activate([
            row2.topAnchor.constraint(equalTo: breadcrumbScrollView.bottomAnchor, constant: 4),
            row2.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            row2.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            row2.heightAnchor.constraint(equalToConstant: 32),
        ])
    }

    // MARK: - Button Factory

    private func createNavButton(systemSymbol: String, action: Selector) -> NSButton {
        let button = NSButton()
        button.image = NSImage(systemSymbolName: systemSymbol, accessibilityDescription: nil)
        button.bezelStyle = .texturedRounded
        button.imagePosition = .imageOnly
        button.target = self
        button.action = action
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 28).isActive = true
        button.heightAnchor.constraint(equalToConstant: 24).isActive = true
        return button
    }

    private func createViewButton(systemSymbol: String, action: Selector) -> NSButton {
        let button = NSButton()
        button.image = NSImage(systemSymbolName: systemSymbol, accessibilityDescription: nil)
        button.bezelStyle = .texturedRounded
        button.imagePosition = .imageOnly
        button.target = self
        button.action = action
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 28).isActive = true
        button.heightAnchor.constraint(equalToConstant: 24).isActive = true
        return button
    }

    // MARK: - Public API

    func setPath(_ path: String) {
        self.path = path
        breadcrumbStack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        let segments = path.split(separator: "/").map(String.init)
        var accumulatedPath = ""

        let rootButton = createBreadcrumbButton(title: "Macintosh HD", path: "/")
        breadcrumbStack.addArrangedSubview(rootButton)

        for segment in segments {
            accumulatedPath += "/" + segment
            let sep = NSTextField(labelWithString: "›")
            sep.textColor = NSColor.secondaryLabelColor
            sep.translatesAutoresizingMaskIntoConstraints = false
            breadcrumbStack.addArrangedSubview(sep)

            let btn = createBreadcrumbButton(title: segment, path: accumulatedPath)
            breadcrumbStack.addArrangedSubview(btn)
        }
    }

    private func createBreadcrumbButton(title: String, path: String) -> NSButton {
        let button = NSButton()
        button.title = title
        button.isBordered = false
        button.bezelStyle = .inline
        button.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        button.target = self
        button.action = #selector(breadcrumbClicked(_:))
        button.translatesAutoresizingMaskIntoConstraints = false
        button.identifier = NSUserInterfaceItemIdentifier(path)
        return button
    }

    func setCanGoBack(_ canGoBack: Bool) { backButton.isEnabled = canGoBack }
    func setCanGoForward(_ canGoForward: Bool) { forwardButton.isEnabled = canGoForward }
    func setViewMode(_ mode: ViewMode) { updateViewModeHighlight(mode) }

    private func updateViewModeHighlight(_ mode: ViewMode) {
        listViewButton.highlight(mode == .list)
        gridViewButton.highlight(mode == .grid)
    }

    // MARK: - Actions

    @objc private func backClicked() { delegate?.paneToolbarDidClickBack(self) }
    @objc private func forwardClicked() { delegate?.paneToolbarDidClickForward(self) }
    @objc private func upClicked() { delegate?.paneToolbarDidClickUp(self) }
    @objc private func refreshClicked() { delegate?.paneToolbarDidClickRefresh(self) }
    @objc private func searchChanged() {
        delegate?.paneToolbar(self, didChangeSearchQuery: searchField.stringValue)
    }

    @objc private func sortSelected(_ sender: NSPopUpButton) {
        guard let title = sender.titleOfSelectedItem,
              let field = SortField(rawValue: title) else { return }
        let isAscending = sortDirectionButton.image == NSImage(systemSymbolName: "chevron.up", accessibilityDescription: nil)
        delegate?.paneToolbar(self, didChangeSortField: field, ascending: isAscending)
    }

    @objc private func sortDirectionToggled() {
        let isAscending = sortDirectionButton.image == NSImage(systemSymbolName: "chevron.up", accessibilityDescription: nil)
        sortDirectionButton.image = NSImage(systemSymbolName: isAscending ? "chevron.down" : "chevron.up", accessibilityDescription: isAscending ? "降序" : "升序")
        guard let title = sortPopup.titleOfSelectedItem,
              let field = SortField(rawValue: title) else { return }
        delegate?.paneToolbar(self, didChangeSortField: field, ascending: !isAscending)
    }

    @objc private func groupSelected(_ sender: NSPopUpButton) {
        let groupBy: String
        switch sender.titleOfSelectedItem {
        case "无分组": groupBy = "none"
        case "按种类": groupBy = "kind"
        case "按日期": groupBy = "date"
        case "按大小": groupBy = "size"
        default: groupBy = "none"
        }
        delegate?.paneToolbar(self, didChangeGroupBy: groupBy)
    }

    @objc private func listViewClicked() {
        updateViewModeHighlight(.list)
        delegate?.paneToolbar(self, didChangeViewMode: .list)
    }

    @objc private func gridViewClicked() {
        updateViewModeHighlight(.grid)
        delegate?.paneToolbar(self, didChangeViewMode: .grid)
    }

    @objc private func breadcrumbClicked(_ sender: NSButton) {
        guard let path = sender.identifier?.rawValue else { return }
        delegate?.paneToolbar(self, didClickPath: path)
    }
}
