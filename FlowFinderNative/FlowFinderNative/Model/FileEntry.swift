import Foundation

/// 文件或目录条目模型
public struct FileEntry: Identifiable, Equatable {
    public let id = UUID()
    public let path: String
    public let name: String
    public let isDirectory: Bool
    public let size: UInt64
    public let modificationDate: Date

    /// 从 FFI 引用初始化
    /// - Parameter ref: FFEntryRef 结构体
    public init(from ref: FFEntryRef) {
        self.path = String(cString: ref.path)
        self.name = String(cString: ref.name)
        self.isDirectory = ref.isDir
        self.size = ref.size
        self.modificationDate = Date(timeIntervalSince1970: TimeInterval(ref.modified))
    }

    /// 便捷初始化方法
    public init(path: String, name: String, isDirectory: Bool, size: UInt64, modificationDate: Date) {
        self.path = path
        self.name = name
        self.isDirectory = isDirectory
        self.size = size
        self.modificationDate = modificationDate
    }

    /// 格式化后的文件大小字符串
    public var formattedSize: String {
        let byteCountFormatter = ByteCountFormatter()
        byteCountFormatter.allowedUnits = [.useBytes, .useKB, .useMB, .useGB]
        byteCountFormatter.countStyle = .file
        return byteCountFormatter.string(fromByteCount: Int64(size))
    }

    /// 格式化后的修改日期字符串
    public var formattedModificationDate: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: modificationDate)
    }
}
