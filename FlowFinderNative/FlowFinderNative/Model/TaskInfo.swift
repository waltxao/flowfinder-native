import Foundation

/// Represents a task in the task scheduler
public struct TaskInfo: Identifiable, Equatable, Hashable {
    public let id: String
    public let name: String
    public let description: String
    public let priority: TaskPriority
    public let status: TaskStatus
    public let progress: Double
    public let createdAt: Date
    public let startedAt: Date?
    public let completedAt: Date?

    /// Task priority levels
    public enum TaskPriority: Int32, Equatable, Hashable {
        case low = 0
        case normal = 1
        case high = 2
    }

    /// Task status states
    public enum TaskStatus: Int32, Equatable, Hashable {
        case pending = 0
        case running = 1
        case completed = 2
        case failed = 3
        case cancelled = 4
    }

    /// Initialize from FFI reference
    /// - Parameter ref: FFTaskInfo structure from Rust core
    public init(from ref: FFTaskInfo) {
        self.id = String(cString: ref.id)
        self.name = String(cString: ref.name)
        self.description = String(cString: ref.description)
        self.priority = TaskPriority(rawValue: ref.priority) ?? .normal
        self.status = TaskStatus(rawValue: ref.status) ?? .pending
        self.progress = ref.progress
        self.createdAt = Date(timeIntervalSince1970: TimeInterval(ref.created_at))
        self.startedAt = ref.started_at > 0 ? Date(timeIntervalSince1970: TimeInterval(ref.started_at)) : nil
        self.completedAt = ref.completed_at > 0 ? Date(timeIntervalSince1970: TimeInterval(ref.completed_at)) : nil
    }

    /// Convenience initializer with all fields
    public init(id: String, name: String, description: String, priority: TaskPriority,
                status: TaskStatus, progress: Double, createdAt: Date,
                startedAt: Date? = nil, completedAt: Date? = nil) {
        self.id = id
        self.name = name
        self.description = description
        self.priority = priority
        self.status = status
        self.progress = progress
        self.createdAt = createdAt
        self.startedAt = startedAt
        self.completedAt = completedAt
    }

    /// Human-readable priority description
    public var priorityDescription: String {
        switch priority {
        case .low: return "Low"
        case .normal: return "Normal"
        case .high: return "High"
        }
    }

    /// Human-readable status description
    public var statusDescription: String {
        switch status {
        case .pending: return "Pending"
        case .running: return "Running"
        case .completed: return "Completed"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        }
    }

    /// Progress percentage string (e.g., "75%")
    public var progressPercentage: String {
        return String(format: "%.0f%%", progress * 100)
    }

    /// Whether the task is active (pending or running)
    public var isActive: Bool {
        return status == .pending || status == .running
    }

    /// Whether the task is completed (successfully or failed)
    public var isCompleted: Bool {
        return status == .completed || status == .failed || status == .cancelled
    }

    /// Formatted creation date
    public var formattedCreatedAt: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: createdAt)
    }

    /// Duration string if task has started
    public var duration: String? {
        guard let started = startedAt else { return nil }
        let endDate = completedAt ?? Date()
        let interval = endDate.timeIntervalSince(started)
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: interval)
    }
}
