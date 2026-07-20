import Foundation

// MARK: - SidebarSection

enum SidebarSection: Int, CaseIterable {
    case favorites = 0
    case tags = 1
    case devices = 2

    var title: String {
        switch self {
        case .favorites: return "收藏夹"
        case .tags: return "标签"
        case .devices: return "存储设备"
        }
    }
}

// MARK: - SidebarItem

enum SidebarItem {
    case favorite(FavoriteItem)
    case tag(Tag)
    case device(DeviceItem)

    var name: String {
        switch self {
        case .favorite(let fav): return fav.name
        case .tag(let tag): return tag.name
        case .device(let dev): return dev.name
        }
    }

    var path: String? {
        switch self {
        case .favorite(let fav): return fav.path
        case .tag: return nil
        case .device(let dev): return dev.path
        }
    }
}

// MARK: - FavoriteItem

struct FavoriteItem: Codable, Equatable {
    let id: String
    var name: String
    var path: String

    init(id: String = UUID().uuidString, name: String, path: String) {
        self.id = id
        self.name = name
        self.path = path
    }
}

// MARK: - DeviceItem

struct DeviceItem {
    let name: String
    let path: String
    let isRemovable: Bool
    let isNetwork: Bool
    let totalSize: UInt64
    let freeSize: UInt64
}
