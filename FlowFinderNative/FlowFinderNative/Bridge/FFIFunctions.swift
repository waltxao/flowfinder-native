import Foundation

/// FFI 入口引用结构体，对应 Rust 侧的 ff_entry_t
public struct FFEntryRef {
    public let path: UnsafePointer<CChar>
    public let name: UnsafePointer<CChar>
    public let isDir: Bool
    public let size: UInt64
    public let modified: UInt64
}

/// 目录扫描回调类型
public typealias FFEntryCallback = @convention(c) (UnsafePointer<FFEntryRef>?, UnsafeMutableRawPointer?) -> Void

// MARK: - FFI 函数声明

/// 列出指定目录的内容
/// - Parameters:
///   - path: 目标目录路径（C 字符串）
///   - callback: 每发现一个条目时调用的回调函数
///   - userData: 传递给回调的用户数据指针
/// - Returns: 成功返回 0，失败返回非零错误码
@_silgen_name("ff_list_dir")
public func ff_list_dir(
    _ path: UnsafePointer<CChar>,
    _ callback: FFEntryCallback,
    _ userData: UnsafeMutableRawPointer?
) -> Int32

/// 获取最后一次错误信息
/// - Returns: 指向错误描述 C 字符串的指针（调用方需使用 ff_free_string 释放）
@_silgen_name("ff_last_error")
public func ff_last_error() -> UnsafePointer<CChar>?

/// 释放由 Rust 侧分配的字符串
/// - Parameter string: 要释放的 C 字符串指针
@_silgen_name("ff_free_string")
public func ff_free_string(_ string: UnsafeMutablePointer<CChar>?)
