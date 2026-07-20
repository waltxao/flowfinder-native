import Foundation
import QuickLookThumbnailing
import AppKit

/// QLThumbnailGenerator 缩略图桥接
public final class ThumbnailBridge {
    public static let shared = ThumbnailBridge()

    private let generator = QLThumbnailGenerator.shared
    private var activeRequests: [String: QLThumbnailGenerator.Request] = [:]
    private let cache = NSCache<NSString, NSImage>()

    private init() {
        cache.countLimit = 200  // 最多缓存 200 个缩略图
    }

    /// 异步生成缩略图
    public func generateThumbnail(
        path: String,
        size: CGSize = CGSize(width: 64, height: 64),
        completion: @escaping (NSImage?) -> Void
    ) {
        let cacheKey = "\(path)_\(Int(size.width))x\(Int(size.height))" as NSString

        // 先查缓存
        if let cached = cache.object(forKey: cacheKey) {
            completion(cached)
            return
        }

        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
        let request = QLThumbnailGenerator.Request(
            fileAt: URL(fileURLWithPath: path),
            size: size,
            scale: scale,
            representationTypes: .thumbnail
        )

        let requestRef = generator.generateBestRepresentation(for: request) { [weak self] thumbnail, error in
            if let error = error {
                print("ThumbnailBridge: 生成缩略图失败: \(error.localizedDescription)")
                DispatchQueue.main.async { completion(nil) }
                return
            }

            guard let thumbnail = thumbnail else {
                DispatchQueue.main.async { completion(nil) }
                return
            }

            let image = NSImage(
                cgImage: thumbnail.cgImage,
                size: thumbnail.actualSize
            )

            self?.cache.setObject(image, forKey: cacheKey)
            DispatchQueue.main.async { completion(image) }
        }

        activeRequests[path] = requestRef
    }

    /// 取消所有请求
    public func cancelAll() {
        for (_, request) in activeRequests {
            generator.cancel(request)
        }
        activeRequests.removeAll()
    }

    /// 清除缓存
    public func clearCache() {
        cache.removeAllObjects()
    }
}
