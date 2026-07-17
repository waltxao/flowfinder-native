import Foundation

/// CoreBridge 错误类型
public enum CoreBridgeError: Error, LocalizedError {
    case ffiError(String)
    case invalidPath(String)
    case unknownError

    public var errorDescription: String? {
        switch self {
        case .ffiError(let message):
            return "FFI Error: \(message)"
        case .invalidPath(let path):
            return "Invalid path: \(path)"
        case .unknownError:
            return "Unknown error occurred"
        }
    }
}

/// 负责与 Rust Core 进行 FFI 通信的桥接类
public final class CoreBridge {
    public static let shared = CoreBridge()

    private init() {}

    /// 列出指定目录的条目
    /// - Parameter path: 目标目录路径
    /// - Returns: 目录条目数组
    /// - Throws: CoreBridgeError
    public func listDirectory(path: String) throws -> [FileEntry] {
        guard !path.isEmpty else {
            throw CoreBridgeError.invalidPath(path)
        }

        var entries: [FileEntry] = []
        let context = EntryCollectorContext(entries: &entries)

        let result = path.withCString { cPath in
            withUnsafeMutablePointer(to: &context) { contextPtr in
                ff_list_dir(cPath, entryCallback, contextPtr)
            }
        }

        guard result == 0 else {
            let errorMessage = getLastError()
            throw CoreBridgeError.ffiError(errorMessage)
        }

        return entries
    }

    /// 获取最后一次 FFI 错误信息
    private func getLastError() -> String {
        guard let cString = ff_last_error() else {
            return "Unknown error"
        }
        let message = String(cString: cString)
        ff_free_string(UnsafeMutablePointer(mutating: cString))
        return message
    }
}

// MARK: - 回调上下文与回调函数

private struct EntryCollectorContext {
    var entries: [FileEntry]
}

private func entryCallback(
    _ entryRef: UnsafePointer<FFEntryRef>?,
    _ userData: UnsafeMutableRawPointer?
) {
    guard let entryRef = entryRef,
          let userData = userData else { return }

    let context = userData.withMemoryRebound(to: EntryCollectorContext.self, capacity: 1) { $0 }
    let entry = FileEntry(from: entryRef.pointee)
    context.pointee.entries.append(entry)
}
