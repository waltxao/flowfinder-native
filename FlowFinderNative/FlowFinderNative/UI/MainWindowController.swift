import Cocoa
import SwiftUI
import Combine

/// Main window controller managing the primary application window
public class MainWindowController: NSWindowController {

    // MARK: - Properties

    private var viewModel = FileEntryViewModel()
    private var cancellables = Set<AnyCancellable>()

    // Window configuration constants
    private let minWindowWidth: CGFloat = 800
    private let minWindowHeight: CGFloat = 600
    private let defaultWindowWidth: CGFloat = 1200
    private let defaultWindowHeight: CGFloat = 800

    // MARK: - Initialization

    public init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: defaultWindowWidth, height: defaultWindowHeight),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        window.title = "FlowFinder"
        window.subtitle = viewModel.currentPath
        window.minSize = NSSize(width: minWindowWidth, height: minWindowHeight)
        window.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        window.center()
        window.setFrameAutosaveName("MainWindow")
        window.isRestorable = true
        window.restorationClass = MainWindowController.self

        super.init(window: window)

        setupContentView()
        setupBindings()
        loadInitialDirectory()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Setup

    private func setupContentView() {
        guard let window = window else { return }

        let contentView = ContentView()
        contentView.setViewModel(viewModel)
        contentView.onNavigate = { [weak self] entry in
            self?.viewModel.navigateToEntry(entry)
        }

        window.contentView = contentView
    }

    private func setupBindings() {
        viewModel.$currentPath
            .receive(on: DispatchQueue.main)
            .sink { [weak self] path in
                self?.window?.subtitle = path
            }
            .store(in: &cancellables)

        viewModel.$errorMessage
            .receive(on: DispatchQueue.main)
            .compactMap { $0 }
            .sink { [weak self] errorMessage in
                self?.showError(message: errorMessage)
            }
            .store(in: &cancellables)
    }

    private func loadInitialDirectory() {
        viewModel.loadDirectory()
    }

    // MARK: - Error Handling

    private func showError(message: String) {
        let alert = NSAlert()
        alert.messageText = "Error"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: - Window Lifecycle

    public override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
    }

    public override func windowWillLoad() {
        super.windowWillLoad()
    }

    public override func windowDidLoad() {
        super.windowDidLoad()
    }
}

// MARK: - NSWindowRestoration

extension MainWindowController: NSWindowRestoration {
    public static func restoreWindow(withIdentifier identifier: NSUserInterfaceItemIdentifier,
                                      state: NSCoder,
                                      completionHandler: @escaping (NSWindow?, Error?) -> Void) {
        let controller = MainWindowController()
        completionHandler(controller.window, nil)
    }
}
