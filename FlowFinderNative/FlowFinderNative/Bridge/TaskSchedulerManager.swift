import Foundation
import Combine

/// 任务调度管理器：单例轮询 CoreBridge.listTasks() 更新进度
public final class TaskSchedulerManager: ObservableObject {

    public static let shared = TaskSchedulerManager()

    @Published public private(set) var activeTask: TaskInfo?
    @Published public private(set) var allTasks: [TaskInfo] = []

    /// 任务更新回调（主线程）
    public var onTaskUpdated: ((TaskInfo?) -> Void)?
    public var onTasksChanged: (([TaskInfo]) -> Void)?

    private var pollingTimer: DispatchSourceTimer?
    private let pollingQueue = DispatchQueue(label: "com.flowfinder.taskpolling", qos: .utility)
    private var pollingInterval: TimeInterval = 0.5

    private init() {}

    // MARK: - Polling

    /// 启动任务轮询
    /// - Parameter interval: 轮询间隔（默认 0.5 秒）
    public func startPolling(interval: TimeInterval = 0.5) {
        pollingInterval = interval
        stopPolling()

        let timer = DispatchSource.makeTimerSource(queue: pollingQueue)
        timer.schedule(deadline: .now(), repeating: pollingInterval)
        timer.setEventHandler { [weak self] in
            self?.refreshTasks()
        }
        timer.resume()
        pollingTimer = timer
    }

    /// 停止任务轮询
    public func stopPolling() {
        pollingTimer?.cancel()
        pollingTimer = nil
    }

    /// 立即刷新任务列表
    public func refreshTasks() {
        let tasks = CoreBridge.shared.listTasks()

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            self.allTasks = tasks
            self.activeTask = tasks.first(where: { $0.isActive })

            self.onTaskUpdated?(self.activeTask)
            self.onTasksChanged?(tasks)
        }
    }

    // MARK: - Task Operations

    /// 取消指定任务
    /// - Parameter taskId: 任务 ID
    public func cancelTask(taskId: Int32) {
        do {
            try CoreBridge.shared.cancelTask(taskId: taskId)
            refreshTasks()
        } catch {
            print("TaskSchedulerManager: 取消任务失败: \(error.localizedDescription)")
        }
    }

    /// 获取任务进度（0.0-1.0）
    public var currentProgress: Double? {
        return activeTask?.progress
    }

    /// 是否有活跃任务
    public var hasActiveTask: Bool {
        return activeTask != nil
    }
}
