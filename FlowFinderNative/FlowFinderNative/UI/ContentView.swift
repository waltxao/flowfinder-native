import Cocoa
import SwiftUI

// MARK: - NSSplitView Representable

/// NSSplitView wrapper for SwiftUI integration
public struct SplitViewRepresentable: NSViewRepresentable {
    let leftView: AnyView
    let rightView: AnyView
    var sidebarWidth: CGFloat = 220

    public func makeNSView(context: Context) -> NSSplitView {
        let splitView = NSSplitView()
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.autosaveName = "MainSplitView"

        // Left sidebar container
        let leftContainer = NSView()
        leftContainer.translatesAutoresizingMaskIntoConstraints = false

        // Right content container
        let rightContainer = NSView()
        rightContainer.translatesAutoresizingMaskIntoConstraints = false

        splitView.addArrangedSubview(leftContainer)
        splitView.addArrangedSubview(rightContainer)

        // Set sidebar width constraints
        leftContainer.widthAnchor.constraint(greaterThanOrEqualToConstant: 150).isActive = true
        leftContainer.widthAnchor.constraint(lessThanOrEqualToConstant: 400).isActive = true

        // Set holding priorities to prevent unwanted resizing
        splitView.setHoldingPriority(.defaultLow, forSubviewAt: 0)
        splitView.setHoldingPriority(.defaultHigh, forSubviewAt: 1)

        // Embed SwiftUI views
        let leftHostingView = NSHostingView(rootView: leftView)
        leftHostingView.translatesAutoresizingMaskIntoConstraints = false
        leftContainer.addSubview(leftHostingView)

        let rightHostingView = NSHostingView(rootView: rightView)
        rightHostingView.translatesAutoresizingMaskIntoConstraints = false
        rightContainer.addSubview(rightHostingView)

        // Layout constraints for hosting views
        NSLayoutConstraint.activate([
            leftHostingView.topAnchor.constraint(equalTo: leftContainer.topAnchor),
            leftHostingView.leadingAnchor.constraint(equalTo: leftContainer.leadingAnchor),
            leftHostingView.trailingAnchor.constraint(equalTo: leftContainer.trailingAnchor),
            leftHostingView.bottomAnchor.constraint(equalTo: leftContainer.bottomAnchor),

            rightHostingView.topAnchor.constraint(equalTo: rightContainer.topAnchor),
            rightHostingView.leadingAnchor.constraint(equalTo: rightContainer.leadingAnchor),
            rightHostingView.trailingAnchor.constraint(equalTo: rightContainer.trailingAnchor),
            rightHostingView.bottomAnchor.constraint(equalTo: rightContainer.bottomAnchor)
        ])

        return splitView
    }

    public func updateNSView(_ nsView: NSSplitView, context: Context) {
        // Update if needed
    }
}

// MARK: - Content View

/// Main content view with split view layout (sidebar + file list)
public class ContentView: NSView {
    private var splitView: NSSplitView!
    private var sidebarView: NSView!
    private var fileListView: FileListView!
    private var viewModel: FileEntryViewModel?

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
            splitView.topAnchor.constraint(equalTo: topAnchor),
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

// MARK: - Content View Representable

/// SwiftUI representable wrapper for ContentView
public struct ContentViewRepresentable: NSViewRepresentable {
    @ObservedObject var viewModel: FileEntryViewModel

    public func makeNSView(context: Context) -> ContentView {
        let view = ContentView()
        view.setViewModel(viewModel)
        view.onNavigate = { entry in
            viewModel.navigateToEntry(entry)
        }
        return view
    }

    public func updateNSView(_ nsView: ContentView, context: Context) {
        nsView.setViewModel(viewModel)
        nsView.onNavigate = { entry in
            viewModel.navigateToEntry(entry)
        }
        nsView.reloadFileList()
    }
}
