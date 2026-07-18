import Cocoa
import Combine

// MARK: - Breadcrumb View

public class BreadcrumbView: NSView {
    private var pathComponents: [String] = []
    private var onNavigate: ((String) -> Void)?

    public var path: String = "" {
        didSet {
            updateComponents()
            needsDisplay = true
        }
    }

    public var onNavigateToPath: ((String) -> Void)? {
        didSet {
            self.onNavigate = onNavigateToPath
        }
    }

    private func updateComponents() {
        pathComponents = path.split(separator: "/").map(String.init)
        if path.hasPrefix("/") {
            pathComponents.insert("/", at: 0)
        }
    }

    public override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        var x: CGFloat = 8
        let y: CGFloat = 4
        let height = bounds.height - 8

        for (index, component) in pathComponents.enumerated() {
            let isLast = index == pathComponents.count - 1

            let text = component.isEmpty ? "/" : component
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
                .foregroundColor: isLast ? NSColor.controlTextColor : NSColor.systemBlue
            ]

            let size = text.size(withAttributes: attributes)
            let rect = NSRect(x: x, y: y, width: size.width, height: height)

            text.draw(in: rect, withAttributes: attributes)

            x += size.width + 4

            if !isLast {
                let separator = "/"
                let sepSize = separator.size(withAttributes: attributes)
                let sepRect = NSRect(x: x, y: y, width: sepSize.width, height: height)
                separator.draw(in: sepRect, withAttributes: attributes)
                x += sepSize.width + 4
            }
        }
    }

    public override func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        var x: CGFloat = 8
        let y: CGFloat = 4
        let height = bounds.height - 8

        for (index, component) in pathComponents.enumerated() {
            let isLast = index == pathComponents.count - 1
            let text = component.isEmpty ? "/" : component
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
                .foregroundColor: isLast ? NSColor.controlTextColor : NSColor.systemBlue
            ]

            let size = text.size(withAttributes: attributes)

            if location.x >= x && location.x <= x + size.width {
                let targetPath = "/" + pathComponents[1...index].joined(separator: "/")
                onNavigate?(targetPath)
                return
            }

            x += size.width + 4

            if !isLast {
                let separator = "/"
                let sepSize = separator.size(withAttributes: attributes)
                x += sepSize.width + 4
            }
        }
    }
}

// MARK: - Content View

/// Main content view with split view layout (sidebar + file list)
public class ContentView: NSView {
    private var splitView: NSSplitView!
    private var sidebarView: NSView!
    private var fileListView: FileListView!
    private var breadcrumbView: BreadcrumbView!
    private var viewModel: FileEntryViewModel?
    private var cancellables = Set<AnyCancellable>()

    public var onNavigate: ((FileEntry) -> Void)?

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupUI()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupUI()
    }

    private func setupUI() {
        // Breadcrumb view
        breadcrumbView = BreadcrumbView(frame: NSRect(x: 0, y: 0, width: frame.width, height: 24))
        breadcrumbView.autoresizingMask = [.width, .minYMargin]
        addSubview(breadcrumbView)

        // Split view setup
        splitView = NSSplitView()
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.autosaveName = "MainSplitView"
        splitView.translatesAutoresizingMaskIntoConstraints = false

        // Sidebar view
        sidebarView = SidebarView()
        sidebarView.translatesAutoresizingMaskIntoConstraints = false

        // File list view
        fileListView = FileListView()
        fileListView.translatesAutoresizingMaskIntoConstraints = false
        fileListView.onDoubleClick = { [weak self] entry in
            self?.onNavigate?(entry)
        }

        // Add to split view
        splitView.addArrangedSubview(sidebarView)
        splitView.addArrangedSubview(fileListView)

        // Set holding priorities
        splitView.setHoldingPriority(.defaultLow, forSubviewAt: 0)
        splitView.setHoldingPriority(.defaultHigh, forSubviewAt: 1)

        // Sidebar width constraints
        sidebarView.widthAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
        sidebarView.widthAnchor.constraint(lessThanOrEqualToConstant: 400).isActive = true

        addSubview(splitView)

        // Main layout constraints
        NSLayoutConstraint.activate([
            breadcrumbView.topAnchor.constraint(equalTo: topAnchor),
            breadcrumbView.leadingAnchor.constraint(equalTo: leadingAnchor),
            breadcrumbView.trailingAnchor.constraint(equalTo: trailingAnchor),
            breadcrumbView.heightAnchor.constraint(equalToConstant: 24),

            splitView.topAnchor.constraint(equalTo: breadcrumbView.bottomAnchor),
            splitView.leadingAnchor.constraint(equalTo: leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: trailingAnchor),
            splitView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    /// Set the view model and bind to file list
    public func setViewModel(_ viewModel: FileEntryViewModel) {
        self.viewModel = viewModel
        fileListView.viewModel = viewModel
        fileListView.reloadData()

        viewModel.$currentPath
            .receive(on: DispatchQueue.main)
            .sink { [weak self] path in
                self?.breadcrumbView.path = path ?? ""
            }
            .store(in: &cancellables)

        breadcrumbView.onNavigateToPath = { [weak self] path in
            self?.viewModel?.navigateToPath(path)
        }
    }

    /// Reload file list data
    public func reloadFileList() {
        fileListView.reloadData()
    }

    public override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        splitView.frame = bounds
    }
}
