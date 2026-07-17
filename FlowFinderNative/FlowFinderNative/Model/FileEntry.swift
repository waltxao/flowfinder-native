import Foundation

/// Represents a file or directory entry in the file system
public struct FileEntry: Identifiable, Equatable, Hashable {
    public let id = UUID()
    public let path: String
    public let name: String
    public let isDirectory: Bool
    public let size: UInt64
    public let modificationDate: Date

    /// File extension derived from the name (if any)
    public var fileExtension: String {
        let url = URL(fileURLWithPath: name)
        return url.pathExtension.lowercased()
    }

    /// Display name (name without extension for files)
    public var displayName: String {
        if isDirectory {
            return name
        }
        let url = URL(fileURLWithPath: name)
        return url.deletingPathExtension().lastPathComponent
    }

    /// MIME type based on file extension (basic mapping)
    public var mimeType: String {
        let ext = fileExtension
        let mimeTypes: [String: String] = [
            "jpg": "image/jpeg",
            "jpeg": "image/jpeg",
            "png": "image/png",
            "gif": "image/gif",
            "bmp": "image/bmp",
            "svg": "image/svg+xml",
            "pdf": "application/pdf",
            "txt": "text/plain",
            "md": "text/markdown",
            "html": "text/html",
            "htm": "text/html",
            "css": "text/css",
            "js": "application/javascript",
            "json": "application/json",
            "xml": "application/xml",
            "zip": "application/zip",
            "tar": "application/x-tar",
            "gz": "application/gzip",
            "mp3": "audio/mpeg",
            "mp4": "video/mp4",
            "mov": "video/quicktime",
            "avi": "video/x-msvideo",
            "doc": "application/msword",
            "docx": "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
            "xls": "application/vnd.ms-excel",
            "xlsx": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
            "ppt": "application/vnd.ms-powerpoint",
            "pptx": "application/vnd.openxmlformats-officedocument.presentationml.presentation"
        ]
        return mimeTypes[ext] ?? "application/octet-stream"
    }

    /// Human-readable file kind description
    public var kindDescription: String {
        if isDirectory {
            return "Folder"
        }
        let ext = fileExtension
        let kinds: [String: String] = [
            "jpg": "JPEG Image",
            "jpeg": "JPEG Image",
            "png": "PNG Image",
            "gif": "GIF Image",
            "pdf": "PDF Document",
            "txt": "Plain Text",
            "md": "Markdown",
            "html": "HTML",
            "css": "CSS",
            "js": "JavaScript",
            "json": "JSON",
            "xml": "XML",
            "zip": "ZIP Archive",
            "mp3": "MP3 Audio",
            "mp4": "MP4 Video",
            "doc": "Word Document",
            "docx": "Word Document",
            "xls": "Excel Spreadsheet",
            "xlsx": "Excel Spreadsheet",
            "ppt": "PowerPoint Presentation",
            "pptx": "PowerPoint Presentation"
        ]
        return kinds[ext] ?? "\(ext.uppercased()) File"
    }

    /// Initialize from FFI reference
    /// - Parameter ref: FFEntryRef structure from Rust core
    public init(from ref: FFEntryRef) {
        self.path = String(cString: ref.path)
        self.name = String(cString: ref.name)
        self.isDirectory = ref.isDir
        self.size = ref.size
        self.modificationDate = Date(timeIntervalSince1970: TimeInterval(ref.modified))
    }

    /// Convenience initializer with all fields
    public init(path: String, name: String, isDirectory: Bool, size: UInt64, modificationDate: Date) {
        self.path = path
        self.name = name
        self.isDirectory = isDirectory
        self.size = size
        self.modificationDate = modificationDate
    }

    /// Formatted file size string (e.g., "1.5 MB", "4 KB", "0 bytes")
    public var formattedSize: String {
        guard !isDirectory else { return "--" }
        let byteCountFormatter = ByteCountFormatter()
        byteCountFormatter.allowedUnits = [.useBytes, .useKB, .useMB, .useGB, .useTB]
        byteCountFormatter.countStyle = .file
        byteCountFormatter.includesUnit = true
        byteCountFormatter.includesCount = true
        return byteCountFormatter.string(fromByteCount: Int64(size))
    }

    /// Formatted modification date string (e.g., "Jan 15, 2024 at 3:30 PM")
    public var formattedModificationDate: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: modificationDate)
    }

    /// Relative modification date (e.g., "Today", "Yesterday", "2 days ago")
    public var relativeModificationDate: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: modificationDate, relativeTo: Date())
    }

    /// Sort-friendly name (directories first, then alphabetically)
    public var sortName: String {
        return isDirectory ? "0_\(name)" : "1_\(name)"
    }
}
