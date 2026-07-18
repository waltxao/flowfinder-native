import Foundation

/// Represents a mounted volume/drive
public struct VolumeInfo: Identifiable, Equatable, Hashable {
    public let id: String
    public let name: String
    public let path: String
    public let fsType: String
    public let totalSize: UInt64
    public let freeSize: UInt64
    public let usedSize: UInt64
    public let isRemovable: Bool
    public let isEjectable: Bool
    public let isWritable: Bool

    /// Initialize from FFI reference
    /// - Parameter ref: FFVolumeInfo structure from Rust core
    public init(from ref: FFVolumeInfo) {
        self.name = String(cString: ref.name!)
        self.path = String(cString: ref.path!)
        self.fsType = String(cString: ref.fs_type!)
        self.totalSize = ref.total_size
        self.freeSize = ref.free_size
        self.usedSize = ref.used_size
        self.isRemovable = ref.is_removable
        self.isEjectable = ref.is_ejectable
        self.isWritable = ref.is_writable
        self.id = self.path
    }

    /// Convenience initializer with all fields
    public init(name: String, path: String, fsType: String, totalSize: UInt64,
                freeSize: UInt64, usedSize: UInt64, isRemovable: Bool,
                isEjectable: Bool, isWritable: Bool) {
        self.name = name
        self.path = path
        self.fsType = fsType
        self.totalSize = totalSize
        self.freeSize = freeSize
        self.usedSize = usedSize
        self.isRemovable = isRemovable
        self.isEjectable = isEjectable
        self.isWritable = isWritable
        self.id = path
    }

    /// Formatted total size
    public var formattedTotalSize: String {
        return formatBytes(totalSize)
    }

    /// Formatted free size
    public var formattedFreeSize: String {
        return formatBytes(freeSize)
    }

    /// Formatted used size
    public var formattedUsedSize: String {
        return formatBytes(usedSize)
    }

    /// Usage percentage (0.0 to 1.0)
    public var usagePercentage: Double {
        guard totalSize > 0 else { return 0.0 }
        return Double(usedSize) / Double(totalSize)
    }

    /// Usage percentage string (e.g., "75%")
    public var usagePercentageString: String {
        return String(format: "%.1f%%", usagePercentage * 100)
    }

    /// Whether the volume is low on space (< 10% free)
    public var isLowSpace: Bool {
        guard totalSize > 0 else { return false }
        return Double(freeSize) / Double(totalSize) < 0.1
    }

    /// Volume type description
    public var volumeTypeDescription: String {
        if isRemovable {
            return isEjectable ? "External Drive" : "Removable Media"
        }
        return "Internal Drive"
    }

    /// Icon name based on volume type
    public var iconName: String {
        if isRemovable {
            return isEjectable ? "externaldrive" : "opticaldisc"
        }
        return "internaldrive"
    }

    /// Volume health status based on free space
    public var healthStatus: VolumeHealthStatus {
        let freeRatio = Double(freeSize) / Double(totalSize)
        if freeRatio < 0.05 {
            return .critical
        } else if freeRatio < 0.1 {
            return .warning
        } else {
            return .healthy
        }
    }

    /// Volume health status enum
    public enum VolumeHealthStatus: Equatable, Hashable {
        case healthy
        case warning
        case critical

        public var description: String {
            switch self {
            case .healthy: return "Healthy"
            case .warning: return "Low Space"
            case .critical: return "Critical"
            }
        }

        public var colorName: String {
            switch self {
            case .healthy: return "green"
            case .warning: return "yellow"
            case .critical: return "red"
            }
        }
    }

    // MARK: - Private Helpers

    private func formatBytes(_ bytes: UInt64) -> String {
        let byteCountFormatter = ByteCountFormatter()
        byteCountFormatter.allowedUnits = [.useBytes, .useKB, .useMB, .useGB, .useTB]
        byteCountFormatter.countStyle = .file
        byteCountFormatter.includesUnit = true
        byteCountFormatter.includesCount = true
        return byteCountFormatter.string(fromByteCount: Int64(bytes))
    }
}
