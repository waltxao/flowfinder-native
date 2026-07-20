import Foundation

/// xattr 标签读写桥接
/// 标签存储在扩展属性 com.flowfinder.tags 中，格式为 JSON 数组
public final class TagBridge {
    public static let shared = TagBridge()

    private let xattrName = "com.flowfinder.tags"

    private init() {}

    /// 获取文件的标签
    public func getTags(path: String) -> [Tag] {
        let buffer = getExtendedAttribute(path: path, name: xattrName)
        guard let data = buffer,
              let tags = try? JSONDecoder().decode([Tag].self, from: data) else {
            return []
        }
        return tags
    }

    /// 设置文件的标签（覆盖）
    public func setTags(_ tags: [Tag], path: String) -> Bool {
        guard let data = try? JSONEncoder().encode(tags) else { return false }
        return setExtendedAttribute(path: path, name: xattrName, data: data)
    }

    /// 添加标签
    public func addTag(_ tag: Tag, path: String) -> Bool {
        var tags = getTags(path: path)
        if tags.contains(where: { $0.id == tag.id }) { return true }
        tags.append(tag)
        return setTags(tags, path: path)
    }

    /// 移除标签
    public func removeTag(_ tagId: String, path: String) -> Bool {
        var tags = getTags(path: path)
        tags.removeAll(where: { $0.id == tagId })
        return setTags(tags, path: path)
    }

    // MARK: - xattr helpers

    private func getExtendedAttribute(path: String, name: String) -> Data? {
        let length = getxattr(path, name, nil, 0, 0, 0)
        guard length > 0 else { return nil }

        var buffer = [UInt8](repeating: 0, count: length)
        let result = getxattr(path, name, &buffer, length, 0, 0)
        guard result > 0 else { return nil }

        return Data(buffer)
    }

    private func setExtendedAttribute(path: String, name: String, data: Data) -> Bool {
        let result = data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) -> Int32 in
            guard let baseAddress = buffer.baseAddress else { return -1 }
            return setxattr(path, name, baseAddress, data.count, 0, 0)
        }
        return result == 0
    }

    private func removeExtendedAttribute(path: String, name: String) -> Bool {
        let result = removexattr(path, name, 0)
        return result == 0
    }
}
