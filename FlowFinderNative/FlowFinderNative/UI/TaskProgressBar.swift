import Cocoa
import Combine

/// 底部固定进度条：显示当前任务进度 + 取消按钮
public class TaskProgressBar: NSView {

    private var progressIndicator: NSProgressIndicator!
    private var taskLabel: NSTextField!
    private var cancelButton: NSButton!
    private var containerView: NSView!

    private var cancellables = Set<AnyCancellable>()
    private var currentTaskId: Int32?

    /// 进度条高度
    public static let height: CGFloat = 28

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupUI()
        setupBindings()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupUI()
        setupBindings()
    }

    // MARK: - UI Setup

    private func setupUI() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        // 容器视图
        containerView = NSView()
        containerView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(containerView)

        // 进度条
        progressIndicator = NSProgressIndicator()
        progressIndicator.style = .bar
        progressIndicator.isIndeterminate = false
        progressIndicator.minValue = 0
        progressIndicator.maxValue = 100
        progressIndicator.doubleValue = 0
        progressIndicator.controlSize = .small
        progressIndicator.translatesAutoresizingMaskIntoConstraints = false

        // 任务标签
        taskLabel = NSTextField(labelWithString: "")
        taskLabel.font = NSFont.systemFont(ofSize: 11)
        taskLabel.textColor = NSColor.secondaryLabelColor
        taskLabel.lineBreakMode = .byTruncatingTail
        taskLabel.translatesAutoresizingMaskIntoConstraints = false

        // 取消按钮
        cancelButton = NSButton(image: NSImage(systemSymbolName: "xmark.circle", accessibilityDescription: "取消")!, target: self, action: #selector(cancelClicked))
        cancelButton.bezelStyle = .inline
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        cancelButton.toolTip = "取消任务"

        containerView.addSubview(progressIndicator)
        containerView.addSubview(taskLabel)
        containerView.addSubview(cancelButton)

        NSLayoutConstraint.activate([
            containerView.topAnchor.constraint(equalTo: topAnchor),
            containerView.leadingAnchor.constraint(equalTo: leadingAnchor),
            containerView.trailingAnchor.constraint(equalTo: trailingAnchor),
            containerView.bottomAnchor.constraint(equalTo: bottomAnchor),

            taskLabel.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 12),
            taskLabel.centerYAnchor.constraint(equalTo: containerView.centerYAnchor),
            taskLabel.widthAnchor.constraint(equalToConstant: 200),

            progressIndicator.leadingAnchor.constraint(equalTo: taskLabel.trailingAnchor, constant: 8),
            progressIndicator.centerYAnchor.constraint(equalTo: containerView.centerYAnchor),
            progressIndicator.heightAnchor.constraint(equalToConstant: 10),

            cancelButton.leadingAnchor.constraint(equalTo: progressIndicator.trailingAnchor, constant: 8),
            cancelButton.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -12),
            cancelButton.centerYAnchor.constraint(equalTo: containerView.centerYAnchor),
            cancelButton.widthAnchor.constraint(equalToConstant: 20),
            cancelButton.heightAnchor.constraint(equalToConstant: 20),
        ])

        // 初始隐藏
        isHidden = true
    }

    // MARK: - Bindings

    private func setupBindings() {
        TaskSchedulerManager.shared.$activeTask
            .receive(on: DispatchQueue.main)
            .sink { [weak self] task in
                if let task = task {
                    self?.show(task: task)
                } else {
                    self?.hide()
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Public API

    /// 显示任务进度
    /// - Parameter task: 任务信息
    public func show(task: TaskInfo) {
        isHidden = false
        taskLabel.stringValue = "\(task.name) - \(task.statusDescription)"
        progressIndicator.doubleValue = task.progress * 100
        currentTaskId = Int32(task.id) ?? nil
    }

    /// 隐藏进度条
    public func hide() {
        isHidden = true
        progressIndicator.doubleValue = 0
        taskLabel.stringValue = ""
        currentTaskId = nil
    }

    // MARK: - Actions

    @objc private func cancelClicked() {
        guard let taskId = currentTaskId else { return }
        TaskSchedulerManager.shared.cancelTask(taskId: taskId)
    }
}
