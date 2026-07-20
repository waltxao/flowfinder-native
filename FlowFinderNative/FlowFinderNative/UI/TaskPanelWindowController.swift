import Cocoa
import Combine

/// ⌘0 独立任务面板窗口：显示所有任务列表
public class TaskPanelWindowController: NSWindowController {

    public static let shared = TaskPanelWindowController()

    private var tableView: NSTableView!
    private var scrollView: NSScrollView!
    private var refreshButton: NSButton!
    private var cancelButton: NSButton!
    private var clearButton: NSButton!
    private var statusLabel: NSTextField!

    private var cancellables = Set<AnyCancellable>()

    private override init(window: NSWindow?) {
        super.init(window: window)
    }

    private convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 450),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "任务面板"
        window.minSize = NSSize(width: 500, height: 300)
        window.center()
        window.setFrameAutosaveName("TaskPanelWindow")
        self.init(window: window)
        setupUI()
        setupBindings()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - UI Setup

    private func setupUI() {
        guard let window = window else { return }
        let contentView = window.contentView!

        // 工具栏
        let toolbar = NSView()
        toolbar.translatesAutoresizingMaskIntoConstraints = false

        refreshButton = NSButton(title: "刷新", target: self, action: #selector(refreshClicked))
        refreshButton.bezelStyle = .rounded
        refreshButton.translatesAutoresizingMaskIntoConstraints = false

        cancelButton = NSButton(title: "取消任务", target: self, action: #selector(cancelClicked))
        cancelButton.bezelStyle = .rounded
        cancelButton.translatesAutoresizingMaskIntoConstraints = false

        clearButton = NSButton(title: "清除已完成", target: self, action: #selector(clearClicked))
        clearButton.bezelStyle = .rounded
        clearButton.translatesAutoresizingMaskIntoConstraints = false

        statusLabel = NSTextField(labelWithString: "")
        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.textColor = NSColor.secondaryLabelColor
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        toolbar.addSubview(refreshButton)
        toolbar.addSubview(cancelButton)
        toolbar.addSubview(clearButton)
        toolbar.addSubview(statusLabel)

        // 表格
        scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        tableView = NSTableView()
        tableView.allowsMultipleSelection = false
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.rowHeight = 24

        let nameCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        nameCol.title = "任务名称"
        nameCol.width = 200
        tableView.addTableColumn(nameCol)

        let statusCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("status"))
        statusCol.title = "状态"
        statusCol.width = 100
        tableView.addTableColumn(statusCol)

        let progressCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("progress"))
        progressCol.title = "进度"
        progressCol.width = 120
        tableView.addTableColumn(progressCol)

        let createdCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("created"))
        createdCol.title = "创建时间"
        createdCol.width = 150
        tableView.addTableColumn(createdCol)

        tableView.dataSource = self
        tableView.delegate = self

        scrollView.documentView = tableView
        contentView.addSubview(toolbar)
        contentView.addSubview(scrollView)

        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            toolbar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            toolbar.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            toolbar.heightAnchor.constraint(equalToConstant: 28),

            refreshButton.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor),
            refreshButton.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),

            cancelButton.leadingAnchor.constraint(equalTo: refreshButton.trailingAnchor, constant: 8),
            cancelButton.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),

            clearButton.leadingAnchor.constraint(equalTo: cancelButton.trailingAnchor, constant: 8),
            clearButton.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),

            statusLabel.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor),
            statusLabel.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),

            scrollView.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
    }

    // MARK: - Bindings

    private func setupBindings() {
        TaskSchedulerManager.shared.$allTasks
            .receive(on: DispatchQueue.main)
            .sink { [weak self] tasks in
                self?.tableView.reloadData()
                let active = tasks.filter { $0.isActive }.count
                let completed = tasks.filter { $0.isCompleted }.count
                self?.statusLabel.stringValue = "共 \(tasks.count) 个任务（\(active) 进行中，\(completed) 已完成）"
            }
            .store(in: &cancellables)
    }

    // MARK: - Public API

    public func showWindow() {
        TaskSchedulerManager.shared.refreshTasks()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Actions

    @objc private func refreshClicked() {
        TaskSchedulerManager.shared.refreshTasks()
    }

    @objc private func cancelClicked() {
        guard tableView.selectedRow >= 0,
              tableView.selectedRow < TaskSchedulerManager.shared.allTasks.count else { return }
        let task = TaskSchedulerManager.shared.allTasks[tableView.selectedRow]
        guard let taskId = Int32(task.id) else { return }
        TaskSchedulerManager.shared.cancelTask(taskId: taskId)
    }

    @objc private func clearClicked() {
        // 清除已完成的任务（仅刷新显示，Rust 端保留历史）
        TaskSchedulerManager.shared.refreshTasks()
    }
}

// MARK: - NSTableViewDataSource

extension TaskPanelWindowController: NSTableViewDataSource {
    public func numberOfRows(in tableView: NSTableView) -> Int {
        return TaskSchedulerManager.shared.allTasks.count
    }
}

// MARK: - NSTableViewDelegate

extension TaskPanelWindowController: NSTableViewDelegate {
    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let tasks = TaskSchedulerManager.shared.allTasks
        guard row < tasks.count else { return nil }
        let task = tasks[row]

        let cellID = NSUserInterfaceItemIdentifier(tableColumn?.identifier.rawValue ?? "")
        let cellView = tableView.makeView(withIdentifier: cellID, owner: self) as? NSTableCellView
            ?? NSTableCellView()
        cellView.identifier = cellID

        if cellView.textField == nil {
            let tf = NSTextField(labelWithString: "")
            tf.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
            tf.lineBreakMode = .byTruncatingTail
            cellView.addSubview(tf)
            cellView.textField = tf
            tf.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                tf.leadingAnchor.constraint(equalTo: cellView.leadingAnchor, constant: 4),
                tf.trailingAnchor.constraint(equalTo: cellView.trailingAnchor, constant: -4),
                tf.centerYAnchor.constraint(equalTo: cellView.centerYAnchor),
            ])
        }

        switch tableColumn?.identifier.rawValue {
        case "name":
            cellView.textField?.stringValue = task.name
        case "status":
            cellView.textField?.stringValue = task.statusDescription
            switch task.status {
            case .running: cellView.textField?.textColor = NSColor.systemBlue
            case .completed: cellView.textField?.textColor = NSColor.systemGreen
            case .failed: cellView.textField?.textColor = NSColor.systemRed
            case .cancelled: cellView.textField?.textColor = NSColor.systemGray
            default: cellView.textField?.textColor = NSColor.labelColor
            }
        case "progress":
            cellView.textField?.stringValue = task.progressPercentage
        case "created":
            cellView.textField?.stringValue = task.formattedCreatedAt
        default:
            break
        }

        return cellView
    }
}
