import Foundation

public struct Tag: Identifiable, Equatable, Hashable, Codable {
    public let id: String
    public var name: String
    public var color: String  // hex color, e.g. "#FF0000"

    public init(id: String = UUID().uuidString, name: String, color: String = "#007AFF") {
        self.id = id
        self.name = name
        self.color = color
    }
}
