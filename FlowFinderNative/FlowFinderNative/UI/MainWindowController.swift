import Cocoa

class MainWindowController: NSWindowController {
    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "FlowFinder"
        window.center()
        super.init(window: window)
        setupSplitView()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupSplitView() {
        let splitView = NSSplitView()
        splitView.isVertical = true
        splitView.dividerStyle = .thin

        let sidebarView = SidebarView()
        let contentView = ContentView()

        splitView.addArrangedSubview(sidebarView)
        splitView.addArrangedSubview(contentView)

        // 设置侧边栏宽度
        sidebarView.widthAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
        sidebarView.widthAnchor.constraint(lessThanOrEqualToConstant: 400).isActive = true

        window?.contentView = splitView
    }
}
