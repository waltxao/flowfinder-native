import Cocoa

class ContentView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupUI()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupUI()
    }

    private func setupUI() {
        let fileListView = FileListView()
        addSubview(fileListView)
        fileListView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            fileListView.topAnchor.constraint(equalTo: topAnchor),
            fileListView.leadingAnchor.constraint(equalTo: leadingAnchor),
            fileListView.trailingAnchor.constraint(equalTo: trailingAnchor),
            fileListView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }
}
