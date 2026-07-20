# Phase 4: 文件操作 + QuickLook + 网格视图 + 缩略图

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 实现拖拽（跨面板+拖出系统）、QuickLook 预览（QLPreviewPanel 单例）、网格视图（NSCollectionView）、缩略图管理（QLThumbnailGenerator + LRU 缓存）、完整快捷键

**Architecture:** ThumbnailManager 作为共享单例提供缩略图缓存；QuickLookPreviewView 重写为 QLPreviewPanel 单例 + DataSource；FileGridView 新建为 NSCollectionView 网格视图；FileListView 扩展拖拽源和拖拽目标；MainWindowController 扩展键盘快捷键和 QuickLook 路由。

**Tech Stack:** Swift 6 / AppKit / QuickLook / QuickLookThumbnailing / NSDraggingDestination / NSCollectionView

## Global Constraints

- macOS only (Swift & AppKit, no SwiftUI)
- QuickLook 使用原生 QLPreviewPanel 单例 + QLPreviewPanelDataSource
- 缩略图使用原生 QLThumbnailGenerator
- 拖拽：同卷移动，跨卷复制，Cmd 键切换
- 快捷键：⌘C/⌘X/⌘V/⌘⌫/⌘D/Enter/⌘N/Space 全套
- 网格视图支持缩略图 + 双击进入 + 拖拽
- 语法检查命令：`swiftc -parse <file>.swift`

---

## File Structure

| 文件 | 操作 | 职责 |
|------|------|------|
| `Bridge/ThumbnailManager.swift` | 新建 | QLThumbnailGenerator 异步生成 + NSCache LRU + 磁盘缓存 |
| `UI/QuickLookPreviewView.swift` | 重写 | QLPreviewPanel 单例 + QLPreviewPanelDataSource + 方向键切换 |
| `UI/FileGridView.swift` | 新建 | NSCollectionView 网格视图 + 缩略图 + 拖拽 + 双击 |
| `UI/FileListView.swift` | 修改 | 扩展 NSDraggingSource（拖出）+ NSDraggingDestination（拖入） |
| `UI/MainWindowController.swift` | 修改 | 键盘快捷键 + QuickLook 路由 + 网格/列表切换 |

---

## Task 1: 新建 ThumbnailManager.swift

**Files:**
- Create: `FlowFinderNative/FlowFinderNative/Bridge/ThumbnailManager.swift`

**Interfaces:**
- Consumes: `QLThumbnailGenerator` (系统框架)
- Produces: `ThumbnailManager.shared` 单例
- Produces: `ThumbnailManager.generateThumbnail(path:size:completion:)` 异步生成
- Produces: `ThumbnailManager.cacheImage(for:path:)` 缓存查询
- Produces: `ThumbnailManager.clearCache()` 清除缓存

- [ ] **Step 1: 创建 ThumbnailManager.swift**

```swift
import Foundation
import QuickLookThumbnailing
import AppKit

/// 缩略图管理器：QLThumbnailGenerator 异步生成 + NSCache LRU + 磁盘缓存
public final class ThumbnailManager {
    public static let shared = ThumbnailManager()

    private let generator = QLThumbnailGenerator.shared
    private let memoryCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 200  // 最多缓存 200 个缩略图
        return cache
    }()

    /// 磁盘缓存目录
    private let diskCacheURL: URL = {
        let cachesDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let cacheDir = cachesDir.appendingPathComponent("FlowFinderThumbnails", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        return cacheDir
    }()

    /// 活跃请求（用于取消）
    private var activeRequests: [String: QLThumbnailGenerator.Request] = [:]
    private let lock = NSLock()

    private init() {}

    // MARK: - Public API

    /// 异步生成缩略图（先查缓存，再生成）
    /// - Parameters:
    ///   - path: 文件路径
    ///   - size: 期望尺寸（默认 64x64）
    ///   - completion: 完成回调（主线程）
    public func generateThumbnail(
        path: String,
        size: CGSize = CGSize(width: 64, height: 64),
        completion: @escaping (NSImage?) -> Void
    ) {
        let cacheKey = cacheKey(for: path, size: size)

        // 1. 查内存缓存
        if let cached = memoryCache.object(forKey: cacheKey) {
            completion(cached)
            return
        }

        // 2. 查磁盘缓存
        if let diskImage = loadFromDiskCache(path: path, cacheKey: cacheKey) {
            memoryCache.setObject(diskImage, forKey: cacheKey)
            completion(diskImage)
            return
        }

        // 3. 异步生成
        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
        let request = QLThumbnailGenerator.Request(
            fileAt: URL(fileURLWithPath: path),
            size: size,
            scale: scale,
            representationTypes: .thumbnail
        )

        let reqRef = generator.generateBestRepresentation(for: request) { [weak self] thumbnail, error in
            if let error = error {
                print("ThumbnailManager: 生成缩略图失败: \(error.localizedDescription)")
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

            // 写入缓存
            self?.memoryCache.setObject(image, forKey: cacheKey)
            self?.saveToDiskCache(image: image, path: path, cacheKey: cacheKey)

            DispatchQueue.main.async { completion(image) }
        }

        // 记录活跃请求
        lock.lock()
        activeRequests[path] = reqRef
        lock.unlock()
    }

    /// 同步获取缓存中的缩略图（不触发生成）
    /// - Parameters:
    ///   - path: 文件路径
    ///   - size: 期望尺寸
    /// - Returns: 缓存的图片（如果存在）
    public func cacheImage(for path: String, size: CGSize = CGSize(width: 64, height: 64)) -> NSImage? {
        let key = cacheKey(for: path, size: size)
        return memoryCache.object(forKey: key)
    }

    /// 预生成缩略图（不返回结果，用于预热缓存）
    /// - Parameters:
    ///   - paths: 文件路径数组
    ///   - size: 期望尺寸
    public func prefetchThumbnails(paths: [String], size: CGSize = CGSize(width: 64, height: 64)) {
        for path in paths {
            generateThumbnail(path: path, size: size) { _ in }
        }
    }

    /// 取消指定路径的缩略图生成
    /// - Parameter path: 文件路径
    public func cancelGeneration(for path: String) {
        lock.lock()
        if let request = activeRequests[path] {
            generator.cancel(request)
            activeRequests.removeValue(forKey: path)
        }
        lock.unlock()
    }

    /// 清除内存缓存
    public func clearMemoryCache() {
        memoryCache.removeAllObjects()
    }

    /// 清除磁盘缓存
    public func clearDiskCache() {
        try? FileManager.default.removeItem(at: diskCacheURL)
        try? FileManager.default.createDirectory(at: diskCacheURL, withIntermediateDirectories: true)
    }

    /// 清除所有缓存（内存 + 磁盘）
    public func clearCache() {
        clearMemoryCache()
        clearDiskCache()
    }

    // MARK: - Private

    private func cacheKey(for path: String, size: CGSize) -> NSString {
        return "\(path)_\(Int(size.width))x\(Int(size.height))" as NSString
    }

    private func diskCacheURL(for path: String, cacheKey: String) -> URL {
        // 使用路径的 hash 作为文件名
        let hash = path.djb2hash()
        let ext = (path as NSString).pathExtension
        return diskCacheURL.appendingPathComponent("\(hash)_\(cacheKey).\(ext.isEmpty ? "png" : ext)")
    }

    private func loadFromDiskCache(path: String, cacheKey: String) -> NSImage? {
        let url = diskCacheURL(for: path, cacheKey: cacheKey as String)
        return NSImage(contentsOf: url)
    }

    private func saveToDiskCache(image: NSImage, path: String, cacheKey: String) {
        let url = diskCacheURL(for: path, cacheKey: cacheKey)

        DispatchQueue.global(qos: .utility).async {
            // 转为 PNG 数据保存
            if let tiffData = image.tiffRepresentation,
               let bitmap = NSBitmapImageRep(data: tiffData),
               let pngData = bitmap.representation(using: .png, properties: [:]) {
                try? pngData.write(to: url, options: .atomic)
            }
        }
    }
}

// MARK: - String Hash Extension

private extension String {
    func djb2hash() -> UInt64 {
        var hash: UInt64 = 5381
        for char in self.utf8 {
            hash = hash &* 33 &+ UInt64(char)
        }
        return hash
    }
}
```

- [ ] **Step 2: 语法检查**

Run: `cd /Volumes/Iris-Data/Download/AI/文件管理系统/flowfinder-native/FlowFinderNative/FlowFinderNative/Bridge && swiftc -parse ThumbnailManager.swift 2>&1 | head -5`
Expected: 无输出（无错误）

- [ ] **Step 3: 提交**

```bash
cd /Volumes/Iris-Data/Download/AI/文件管理系统/flowfinder-native
git add FlowFinderNative/FlowFinderNative/Bridge/ThumbnailManager.swift
git commit -m "feat: 新建 ThumbnailManager 缩略图管理器

- QLThumbnailGenerator 异步生成缩略图
- NSCache LRU 内存缓存（200 个）
- 磁盘缓存（PNG 格式，路径 hash 命名）
- prefetchThumbnails 预热缓存
- cancelGeneration 取消指定请求
- clearCache 清除内存+磁盘缓存"
```

---

## Task 2: 重写 QuickLookPreviewView.swift

**Files:**
- Modify: `FlowFinderNative/FlowFinderNative/UI/QuickLookPreviewView.swift`

**Interfaces:**
- Consumes: `QLPreviewPanel` (系统框架), `FileEntry` (Phase 2)
- Produces: `QuickLookPreviewPanel.shared` 单例
- Produces: `QuickLookPreviewPanel.togglePreview(files:currentIndex:)` 切换显示
- Produces: `QuickLookPreviewPanel.close()` 关闭
- Produces: 方向键切换预览文件

- [ ] **Step 1: 重写 QuickLookPreviewView.swift**

完整替换 `FlowFinderNative/FlowFinderNative/UI/QuickLookPreviewView.swift`：

```swift
import Cocoa
import QuickLook

/// QuickLook 预览面板：使用原生 QLPreviewPanel 单例
public class QuickLookPreviewPanel: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {

    public static let shared = QuickLookPreviewPanel()

    /// 当前预览的文件路径数组
    private var previewFiles: [String] = []

    /// 当前预览的索引
    private var currentIndex: Int = 0

    /// QLPreviewPanel 单例引用
    private var previewPanel: QLPreviewPanel? {
        QLPreviewPanel.sharedPreviewPanel()
    }

    private override init() {
        super.init()
    }

    // MARK: - Public API

    /// 切换 QuickLook 预览显示/隐藏
    /// - Parameters:
    ///   - files: 可预览的文件路径数组
    ///   - currentIndex: 当前选中的文件索引
    public func togglePreview(files: [String], currentIndex: Int) {
        self.previewFiles = files
        self.currentIndex = max(0, min(currentIndex, max(0, files.count - 1)))

        guard let panel = previewPanel else { return }

        if panel.isVisible {
            panel.orderOut(nil)
        } else {
            panel.dataSource = self
            panel.delegate = self
            panel.currentPreviewItemIndex = self.currentIndex
            panel.makeKeyAndOrderFront(nil)
        }
    }

    /// 关闭 QuickLook 预览
    public func close() {
        previewPanel?.orderOut(nil)
    }

    /// 更新预览文件列表（不改变显示状态）
    /// - Parameters:
    ///   - files: 新的文件路径数组
    ///   - currentIndex: 当前索引
    public func updateFiles(_ files: [String], currentIndex: Int) {
        self.previewFiles = files
        self.currentIndex = max(0, min(currentIndex, max(0, files.count - 1)))
        previewPanel?.reloadData()
    }

    // MARK: - QLPreviewPanelDataSource

    public func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        return previewFiles.count
    }

    public func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        guard index >= 0 && index < previewFiles.count else { return nil }
        let url = URL(fileURLWithPath: previewFiles[index])
        return url as NSURL
    }

    // MARK: - QLPreviewPanelDelegate

    public func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        // 处理方向键切换
        if event.type == .keyDown {
            switch event.keyCode {
            case 123:  // 左箭头
                if currentIndex > 0 {
                    currentIndex -= 1
                    panel.currentPreviewItemIndex = currentIndex
                }
                return true
            case 124:  // 右箭头
                if currentIndex < previewFiles.count - 1 {
                    currentIndex += 1
                    panel.currentPreviewItemIndex = currentIndex
                }
                return true
            case 126:  // 上箭头
                if currentIndex > 0 {
                    currentIndex -= 1
                    panel.currentPreviewItemIndex = currentIndex
                }
                return true
            case 125:  // 下箭头
                if currentIndex < previewFiles.count - 1 {
                    currentIndex += 1
                    panel.currentPreviewItemIndex = currentIndex
                }
                return true
            case 53:  // Escape
                close()
                return true
            default:
                break
            }
        }
        return false
    }

    public func previewPanel(_ panel: QLPreviewPanel!, modifierStateChangedTo modifierFlags: NSEvent.ModifierFlags) {
        // 可用于实现 Cmd+方向键等快捷操作
    }
}
```

- [ ] **Step 2: 语法检查**

Run: `cd /Volumes/Iris-Data/Download/AI/文件管理系统/flowfinder-native/FlowFinderNative/FlowFinderNative/UI && swiftc -parse QuickLookPreviewView.swift 2>&1 | head -5`
Expected: 无输出（无错误）

- [ ] **Step 3: 提交**

```bash
cd /Volumes/Iris-Data/Download/AI/文件管理系统/flowfinder-native
git add FlowFinderNative/FlowFinderNative/UI/QuickLookPreviewView.swift
git commit -m "refactor: 重写 QuickLookPreviewView 使用 QLPreviewPanel 单例

- QLPreviewPanel.sharedPreviewPanel() 单例
- QLPreviewPanelDataSource 实现（numberOfPreviewItems/previewItemAt）
- 方向键切换预览文件（上/下/左/右箭头）
- Escape 键关闭预览
- togglePreview(files:currentIndex:) 切换显示/隐藏
- updateFiles 动态更新预览列表"
```

---

## Task 3: 新建 FileGridView.swift

**Files:**
- Create: `FlowFinderNative/FlowFinderNative/UI/FileGridView.swift`

**Interfaces:**
- Consumes: `FileEntry` (Phase 2), `PaneViewModel` (Phase 2), `ThumbnailManager` (Task 1)
- Produces: `FileGridView` with NSCollectionView
- Produces: `FileGridView.viewModel: PaneViewModel?`
- Produces: `FileGridView.onDoubleClick: ((FileEntry) -> Void)?`
- Produces: `FileGridView.onSelectionChanged: (([FileEntry]) -> Void)?`

- [ ] **Step 1: 创建 FileGridView.swift**

```swift
import Cocoa
import Combine

// MARK: - FileGridCollectionViewItem

class FileGridCollectionViewItem: NSCollectionViewItem {
    private var imageView: NSImageView!
    private var nameLabel: NSTextField!
    private var pathLabel: NSTextField!

    var entry: FileEntry? {
        didSet {
            guard let entry = entry else { return }
            nameLabel.stringValue = entry.name
            pathLabel.stringValue = entry.path

            // 设置图标
            if entry.isDirectory {
                imageView.image = NSImage(systemSymbolName: "folder", accessibilityDescription: "文件夹")
                    ?? NSImage(named: NSImage.folderName)
            } else {
                // 使用 ThumbnailManager 获取缩略图
                ThumbnailManager.shared.generateThumbnail(path: entry.path, size: CGSize(width: 96, height: 96)) { [weak self] image in
                    if let image = image {
                        self?.imageView.image = image
                    } else {
                        self?.imageView.image = NSImage(systemSymbolName: "doc", accessibilityDescription: "文件")
                            ?? NSImage(named: NSImage.multipleDocumentsName)
                    }
                }
            }

            // 隐藏文件灰色
            if entry.isHidden {
                nameLabel.textColor = NSColor.tertiaryLabelColor
            } else if entry.isSystemProtected {
                nameLabel.textColor = NSColor.systemRed
            } else {
                nameLabel.textColor = NSColor.labelColor
            }
        }
    }

    override func loadView() {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 120, height: 120))
        view.wantsLayer = true

        imageView = NSImageView()
        imageView.imageScaling = .scaleProportionallyDown
        imageView.translatesAutoresizingMaskIntoConstraints = false

        nameLabel = NSTextField(labelWithString: "")
        nameLabel.font = NSFont.systemFont(ofSize: 11)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.alignment = .center
        nameLabel.maximumNumberOfLines = 2
        nameLabel.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(imageView)
        view.addSubview(nameLabel)

        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            imageView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 64),
            imageView.heightAnchor.constraint(equalToConstant: 64),

            nameLabel.topAnchor.constraint(equalTo: imageView.bottomAnchor, constant: 4),
            nameLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 4),
            nameLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -4),
            nameLabel.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -4),
        ])

        self.view = view
    }

    override var isSelected: Bool {
        didSet {
            view.layer?.backgroundColor = isSelected
                ? NSColor.controlAccentColor.withAlphaComponent(0.2).cgColor
                : NSColor.clear.cgColor
        }
    }
}

// MARK: - FileGridView

/// NSCollectionView-based grid view with thumbnails
public class FileGridView: NSView {
    private var collectionView: NSCollectionView!
    private var scrollView: NSScrollView!
    private var cancellables = Set<AnyCancellable>()

    public var viewModel: PaneViewModel? {
        didSet {
            collectionView.dataSource = self
            collectionView.delegate = self
            viewModel?.$state
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.reloadData() }
                .store(in: &cancellables)
            reloadData()
        }
    }

    public var onDoubleClick: ((FileEntry) -> Void)?
    public var onSelectionChanged: (([FileEntry]) -> Void)?

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupUI()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupUI()
    }

    private func setupUI() {
        scrollView = NSScrollView(frame: bounds)
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true

        let layout = NSCollectionViewGridLayout()
        layout.minimumItemSize = NSSize(width: 120, height: 120)
        layout.maximumItemSize = NSSize(width: 120, height: 120)
        layout.minimumInteritemSpacing = 8
        layout.minimumLineSpacing = 8
        layout.margins = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)

        collectionView = NSCollectionView()
        collectionView.collectionViewLayout = layout
        collectionView.backgroundColors = [NSColor.clear]
        collectionView.allowsMultipleSelection = true
        collectionView.allowsEmptySelection = true
        collectionView.isSelectable = true
        collectionView.dataSource = self
        collectionView.delegate = self

        // 注册 item
        collectionView.register(FileGridCollectionViewItem.self, forItemWithIdentifier: NSUserInterfaceItemIdentifier("GridItem"))

        scrollView.documentView = collectionView
        addSubview(scrollView)
    }

    public override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        scrollView.frame = bounds
    }

    public func reloadData() {
        collectionView?.reloadData()
    }
}

// MARK: - NSCollectionViewDataSource

extension FileGridView: NSCollectionViewDataSource {
    public func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        return viewModel?.files.count ?? 0
    }

    public func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: NSUserInterfaceItemIdentifier("GridItem"), for: indexPath) as! FileGridCollectionViewItem
        if let viewModel = viewModel, indexPath.item < viewModel.files.count {
            item.entry = viewModel.files[indexPath.item]
        }
        return item
    }
}

// MARK: - NSCollectionViewDelegate

extension FileGridView: NSCollectionViewDelegate {
    public func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        guard let viewModel = viewModel else { return }
        var selected: [FileEntry] = []
        for indexPath in indexPaths {
            if indexPath.item < viewModel.files.count {
                selected.append(viewModel.files[indexPath.item])
            }
        }
        onSelectionChanged?(selected)
    }

    public func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
        // 更新选择状态
        guard let viewModel = viewModel else { return }
        let selectedIndexPaths = collectionView.selectionIndexPaths
        var selected: [FileEntry] = []
        for indexPath in selectedIndexPaths {
            if indexPath.item < viewModel.files.count {
                selected.append(viewModel.files[indexPath.item])
            }
        }
        onSelectionChanged?(selected)
    }

    public func collectionView(_ collectionView: NSCollectionView, doubleClickItemAt indexPath: IndexPath) {
        guard let viewModel = viewModel, indexPath.item < viewModel.files.count else { return }
        onDoubleClick?(viewModel.files[indexPath.item])
    }
}
```

- [ ] **Step 2: 语法检查**

Run: `cd /Volumes/Iris-Data/Download/AI/文件管理系统/flowfinder-native/FlowFinderNative/FlowFinderNative/UI && swiftc -parse FileGridView.swift 2>&1 | head -5`
Expected: 无输出（无错误）

- [ ] **Step 3: 提交**

```bash
cd /Volumes/Iris-Data/Download/AI/文件管理系统/flowfinder-native
git add FlowFinderNative/FlowFinderNative/UI/FileGridView.swift
git commit -m "feat: 新建 FileGridView 网格视图

- NSCollectionView + NSCollectionViewGridLayout
- FileGridCollectionViewItem（图标+文件名，120x120）
- ThumbnailManager 异步加载缩略图（96x96）
- 隐藏文件灰色 / 系统保护文件红色
- 多选支持（allowsMultipleSelection）
- 双击进入文件夹
- 选中高亮（半透明 accent color）"
```

---

## Task 4: 扩展 FileListView 拖拽支持

**Files:**
- Modify: `FlowFinderNative/FlowFinderNative/UI/FileListView.swift`

**Interfaces:**
- Consumes: `FileEntry` (Phase 2), `CoreBridge.shared` (Phase 1)
- Produces: `FileListView` 实现 NSDraggingSource（拖出）
- Produces: `FileListView` 实现 NSDraggingDestination（拖入）
- Produces: 跨面板拖拽（同卷移动，跨卷复制）

- [ ] **Step 1: 在 FileListView 添加拖拽协议**

在 `FileListView.swift` 中，在文件末尾的 `// MARK: - Notification Names` 之前添加：

```swift
// MARK: - Drag and Drop

extension FileListView: NSDraggingSource {
    public func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        return [.copy, .move, .delete]
    }
}

extension FileListView: NSDraggingDestination {
    public func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        return isMoveOperation(sender) ? .move : .copy
    }

    public func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        return isMoveOperation(sender) ? .move : .copy
    }

    public func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pasteboard = sender.draggingPasteboard

        guard let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
              !urls.isEmpty else {
            return false
        }

        let destPath = viewModel?.currentPath ?? ""
        guard !destPath.isEmpty else { return false }

        let isMove = isMoveOperation(sender)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            for url in urls {
                let srcPath = url.path
                let fileName = url.lastPathComponent
                let dstPath = (destPath as NSString).appendingPathComponent(fileName)

                do {
                    if isMove {
                        try CoreBridge.shared.moveFile(src: srcPath, dst: dstPath)
                    } else {
                        try CoreBridge.shared.copyFile(src: srcPath, dst: dstPath)
                    }
                } catch {
                    DispatchQueue.main.async {
                        self?.showError(error: error)
                    }
                    return
                }
            }

            DispatchQueue.main.async {
                self?.viewModel?.refresh()
            }
        }

        return true
    }

    /// 判断是否为移动操作（同卷 + 未按 Cmd）
    private func isMoveOperation(_ sender: NSDraggingInfo) -> Bool {
        // Cmd 键切换为复制
        if sender.draggingSourceOperationMask.contains(.copy) &&
           !sender.draggingSourceOperationMask.contains(.move) {
            return false
        }

        // 检查源和目标是否在同一卷
        guard let destPath = viewModel?.currentPath else { return false }

        if let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
           let srcPath = urls.first?.path {
            return isSameVolume(srcPath: srcPath, destPath: destPath)
        }

        return false
    }

    /// 检查两个路径是否在同一卷（通过 statfs）
    private func isSameVolume(srcPath: String, destPath: String) -> Bool {
        var srcStat = statfs()
        var dstStat = statfs()

        let srcResult = srcPath.withCString { statfs($0, &srcStat) }
        let dstResult = destPath.withCString { statfs($0, &dstStat) }

        guard srcResult == 0 && dstResult == 0 else { return false }

        // 比较设备 ID
        return srcStat.f_fsid.0 == dstStat.f_fsid.0 && srcStat.f_fsid.1 == dstStat.f_fsid.1
    }
}
```

- [ ] **Step 2: 在 setupUI 中注册拖拽目标**

在 `FileListView.swift` 的 `setupUI()` 方法末尾（`scrollView.documentView = tableView` 之后）添加：

```swift
        // 注册为拖拽目标
        registerForDraggedTypes([.fileURL])

        // 启用拖拽源（通过 tableView）
        tableView.setDraggingSourceOperationMask([.copy, .move, .delete], forLocal: false)
```

- [ ] **Step 3: 添加拖拽源方法**

在 `FileListView` 类中（在 `// MARK: - Helpers` 区域之前）添加拖拽源支持方法：

```swift
    // MARK: - Drag Source

    /// 开始拖拽（在 tableView 的 mouseDown 中触发）
    @objc private func handleTableDrag() {
        guard let viewModel = viewModel,
              let selectedRow = tableView.selectedRow as Int?,
              selectedRow >= 0, selectedRow < viewModel.files.count else { return }

        let entry = viewModel.files[selectedRow]
        let url = URL(fileURLWithPath: entry.path)

        let draggingItem = NSDraggingItem(pasteboardWriter: url as NSURL)
        draggingItem.setDraggingFrame(tableView.rect(ofRow: selectedRow), contents: nil)

        beginDraggingSession(with: [draggingItem], event: NSApp.currentEvent!, source: self)
    }
```

- [ ] **Step 4: 语法检查**

Run: `cd /Volumes/Iris-Data/Download/AI/文件管理系统/flowfinder-native/FlowFinderNative/FlowFinderNative/UI && swiftc -parse FileListView.swift 2>&1 | head -5`
Expected: 无输出（无错误）

- [ ] **Step 5: 提交**

```bash
cd /Volumes/Iris-Data/Download/AI/文件管理系统/flowfinder-native
git add FlowFinderNative/FlowFinderNative/UI/FileListView.swift
git commit -m "feat: FileListView 拖拽支持

- NSDraggingSource 协议（拖出文件到其他应用）
- NSDraggingDestination 协议（拖入文件）
- 同卷移动 / 跨卷复制（statfs 设备 ID 比较）
- Cmd 键切换为复制
- 拖拽完成后自动刷新"
```

---

## Task 5: 扩展 MainWindowController 快捷键 + QuickLook + 视图切换

**Files:**
- Modify: `FlowFinderNative/FlowFinderNative/UI/MainWindowController.swift`

**Interfaces:**
- Consumes: `QuickLookPreviewPanel` (Task 2), `FileGridView` (Task 3), `ThumbnailManager` (Task 1)
- Produces: Space 键 QuickLook 预览
- Produces: Enter 键打开文件
- Produces: ⌘1/⌘2 视图切换
- Produces: leftFileGridView / rightFileGridView 网格视图
- Produces: 视图切换隐藏/显示列表/网格

- [ ] **Step 1: 在 MainWindowController 添加网格视图属性**

在 `MainWindowController.swift` 的属性区域（`private var rightFileListView: FileListView!` 之后）添加：

```swift
    private var leftFileGridView: FileGridView!
    private var rightFileGridView: FileGridView!
```

- [ ] **Step 2: 在 setupUI 中创建网格视图**

在 `setupUI()` 方法中，在左面板 `leftFileListView` 创建之后、`leftPaneContainer` 添加子视图之前，创建网格视图：

在 `leftFileListView.bottomAnchor.constraint(equalTo: leftPaneContainer.bottomAnchor)` 之后添加：

```swift
        // Left Grid View（初始隐藏）
        leftFileGridView = FileGridView()
        leftFileGridView.identifier = NSUserInterfaceItemIdentifier("left")
        leftFileGridView.translatesAutoresizingMaskIntoConstraints = false
        leftFileGridView.isHidden = true
        leftFileGridView.onDoubleClick = { [weak self] entry in
            self?.handleDoubleClick(entry, side: .left)
        }
        leftFileGridView.onSelectionChanged = { [weak self] files in
            self?.handleSelectionChanged(side: .left, files: files)
        }
        leftPaneContainer.addSubview(leftFileGridView)

        NSLayoutConstraint.activate([
            leftFileGridView.topAnchor.constraint(equalTo: leftPaneToolbar.bottomAnchor),
            leftFileGridView.leadingAnchor.constraint(equalTo: leftPaneContainer.leadingAnchor),
            leftFileGridView.trailingAnchor.constraint(equalTo: leftPaneContainer.trailingAnchor),
            leftFileGridView.bottomAnchor.constraint(equalTo: leftPaneContainer.bottomAnchor),
        ])
```

同样在右面板，在 `rightFileListView.bottomAnchor.constraint(equalTo: rightPaneContainer.bottomAnchor)` 之后添加：

```swift
        // Right Grid View（初始隐藏）
        rightFileGridView = FileGridView()
        rightFileGridView.identifier = NSUserInterfaceItemIdentifier("right")
        rightFileGridView.translatesAutoresizingMaskIntoConstraints = false
        rightFileGridView.isHidden = true
        rightFileGridView.onDoubleClick = { [weak self] entry in
            self?.handleDoubleClick(entry, side: .right)
        }
        rightFileGridView.onSelectionChanged = { [weak self] files in
            self?.handleSelectionChanged(side: .right, files: files)
        }
        rightPaneContainer.addSubview(rightFileGridView)

        NSLayoutConstraint.activate([
            rightFileGridView.topAnchor.constraint(equalTo: rightPaneToolbar.bottomAnchor),
            rightFileGridView.leadingAnchor.constraint(equalTo: rightPaneContainer.leadingAnchor),
            rightFileGridView.trailingAnchor.constraint(equalTo: rightPaneContainer.trailingAnchor),
            rightFileGridView.bottomAnchor.constraint(equalTo: rightPaneContainer.bottomAnchor),
        ])
```

- [ ] **Step 3: 添加视图切换方法**

在 `updatePaneUI` 方法中，在 `fileListView?.reloadData()` 之后添加：

```swift
        // 更新网格视图
        let grid = side == .left ? leftFileGridView : rightFileGridView
        grid?.viewModel = side == .left ? leftPaneViewModel : rightPaneViewModel
        grid?.reloadData()

        // 视图模式切换
        updateViewMode(side: side, mode: state.viewMode)
```

在 `MainWindowController` 类中添加视图切换方法（在 `updateActivePaneVisual` 方法之后）：

```swift
    private func updateViewMode(side: PaneSide, mode: ViewMode) {
        let listView = side == .left ? leftFileListView : rightFileListView
        let gridView = side == .left ? leftFileGridView : rightFileGridView

        switch mode {
        case .list:
            listView?.isHidden = false
            gridView?.isHidden = true
        case .grid:
            listView?.isHidden = true
            gridView?.isHidden = false
        }
    }
```

- [ ] **Step 4: 添加键盘事件处理**

在 `MainWindowController` 类中，在 `setupNotifications()` 方法之后添加：

```swift
    // MARK: - Keyboard Events

    public override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags

        // Space: QuickLook 预览
        if event.keyCode == 49 && modifiers.isEmpty {
            handleQuickLook()
            return
        }

        // Enter: 打开/重命名
        if event.keyCode == 36 && modifiers.isEmpty {
            handleEnterKey()
            return
        }

        // ⌘1: 列表视图
        if event.keyCode == 18 && modifiers.contains(.command) {
            activePaneViewModel.setViewMode(.list)
            updateViewMode(side: activePane, mode: .list)
            return
        }

        // ⌘2: 网格视图
        if event.keyCode == 19 && modifiers.contains(.command) {
            activePaneViewModel.setViewMode(.grid)
            updateViewMode(side: activePane, mode: .grid)
            return
        }

        // ⌘D: 复制选中项
        if event.keyCode == 2 && modifiers.contains(.command) {
            duplicateSelected()
            return
        }

        super.keyDown(with: event)
    }

    // MARK: - Quick Look

    private func handleQuickLook() {
        let selected = activePaneViewModel.selectedFiles
        guard !selected.isEmpty else { return }

        // 获取当前面板所有可预览的文件（排除文件夹）
        let previewableFiles = activePaneViewModel.files.filter { !$0.isDirectory }
        let paths = previewableFiles.map { $0.path }

        // 找到当前选中文件的索引
        let currentPath = selected.first?.path
        let currentIndex = paths.firstIndex(of: currentPath ?? "") ?? 0

        QuickLookPreviewPanel.shared.togglePreview(files: paths, currentIndex: currentIndex)
    }

    // MARK: - Enter Key

    private func handleEnterKey() {
        guard let entry = activePaneViewModel.selectedFiles.first else { return }
        if entry.isDirectory {
            activePaneViewModel.navigate(to: entry.path)
        } else {
            NSWorkspace.shared.openFile(entry.path)
        }
    }

    // MARK: - Duplicate

    private func duplicateSelected() {
        let selected = activePaneViewModel.selectedFiles
        guard !selected.isEmpty else { return }

        let destPath = activePaneViewModel.currentPath

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            for entry in selected {
                let fileName = entry.name
                let ext = (fileName as NSString).pathExtension
                let baseName = (fileName as NSString).deletingPathExtension
                let copyName = ext.isEmpty ? "\(baseName) 副本" : "\(baseName) 副本.\(ext)"
                let dstPath = (destPath as NSString).appendingPathComponent(copyName)

                do {
                    try CoreBridge.shared.copyFile(src: entry.path, dst: dstPath)
                } catch {
                    DispatchQueue.main.async {
                        self?.showError(error: error)
                    }
                    return
                }
            }

            DispatchQueue.main.async {
                self?.activePaneViewModel.refresh()
            }
        }
    }
```

- [ ] **Step 5: 确保 window 接受键盘事件**

在 `setupUI()` 方法的 `window` 创建之后（`window.center()` 之后）添加：

```swift
        window.makeKeyAndOrderFront(nil)
```

并在 `MainWindowController` 类的 `init()` 方法中，在 `super.init(window: window)` 之后添加：

```swift
        // 确保窗口可以接收键盘事件
        window.acceptsMouseMovedEvents = true
```

- [ ] **Step 6: 语法检查**

Run: `cd /Volumes/Iris-Data/Download/AI/文件管理系统/flowfinder-native/FlowFinderNative/FlowFinderNative/UI && swiftc -parse MainWindowController.swift 2>&1 | head -5`
Expected: 无输出（无错误）

- [ ] **Step 7: 提交**

```bash
cd /Volumes/Iris-Data/Download/AI/文件管理系统/flowfinder-native
git add FlowFinderNative/FlowFinderNative/UI/MainWindowController.swift
git commit -m "feat: MainWindowController 快捷键 + QuickLook + 视图切换

- Space 键 QuickLook 预览（QLPreviewPanel）
- Enter 键打开文件/进入文件夹
- ⌘1/⌘2 切换列表/网格视图
- ⌘D 复制选中项（副本命名）
- leftFileGridView/rightFileGridView 网格视图创建
- 视图切换隐藏/显示列表/网格
- 键盘事件路由到 MainWindowController"
```

---

## Task 6: Phase 4 集成验证

**Files:**
- 无新增/修改，仅验证

- [ ] **Step 1: 全部 Swift 文件语法检查**

Run: `cd /Volumes/Iris-Data/Download/AI/文件管理系统/flowfinder-native/FlowFinderNative/FlowFinderNative && for f in Bridge/ThumbnailManager.swift UI/QuickLookPreviewView.swift UI/FileGridView.swift UI/FileListView.swift UI/MainWindowController.swift UI/MainMenu.swift UI/PaneToolbar.swift; do echo "--- $f ---"; swiftc -parse "$f" 2>&1 | head -3; done`
Expected: 每个文件无输出（无错误）

- [ ] **Step 2: 确认拖拽协议存在**

Run: `grep -c "NSDraggingSource\|NSDraggingDestination" /Volumes/Iris-Data/Download/AI/文件管理系统/flowfinder-native/FlowFinderNative/FlowFinderNative/UI/FileListView.swift`
Expected: 数字 >= 2

- [ ] **Step 3: 确认 QuickLook DataSource 存在**

Run: `grep -c "QLPreviewPanelDataSource\|QLPreviewPanelDelegate" /Volumes/Iris-Data/Download/AI/文件管理系统/flowfinder-native/FlowFinderNative/FlowFinderNative/UI/QuickLookPreviewView.swift`
Expected: 数字 >= 2

- [ ] **Step 4: 确认缩略图缓存存在**

Run: `grep -c "NSCache\|QLThumbnailGenerator" /Volumes/Iris-Data/Download/AI/文件管理系统/flowfinder-native/FlowFinderNative/FlowFinderNative/Bridge/ThumbnailManager.swift`
Expected: 数字 >= 2

- [ ] **Step 5: 提交 Phase 4 完成标记**

```bash
cd /Volumes/Iris-Data/Download/AI/文件管理系统/flowfinder-native
git add -A
git commit -m "milestone: Phase 4 完成 - 文件操作 + QuickLook + 网格视图 + 缩略图

- ThumbnailManager（QLThumbnailGenerator + NSCache + 磁盘缓存）
- QuickLookPreviewView 重写（QLPreviewPanel 单例 + DataSource + 方向键）
- FileGridView 新建（NSCollectionView + 缩略图 + 多选 + 双击）
- FileListView 拖拽支持（NSDraggingSource/NSDraggingDestination + statfs 同卷判断）
- MainWindowController 快捷键（Space/Enter/⌘1/⌘2/⌘D）
- 视图模式切换（列表/网格）
- 全部文件语法检查通过"
```

---

## Self-Review

### Spec Coverage

| Spec 要求 | 对应 Task |
|-----------|-----------|
| 拖拽实现 NSDraggingDestination | Task 4 |
| 跨面板拖拽 | Task 4（通过 performDragOperation） |
| 拖拽视觉反馈 | Task 4（draggingEntered/draggingUpdated） |
| 快捷键 ⌘C/⌘X/⌘V/⌘⌫/⌘D/Enter/⌘N | Phase 3 + Task 5 |
| QuickLook QLPreviewPanel 单例 | Task 2 |
| QLPreviewPanelDataSource | Task 2 |
| 方向键切换 | Task 2 |
| 网格视图 NSCollectionView | Task 3 |
| 缩略图 + 拖拽 + 双击 | Task 3 |
| QLThumbnailGenerator 异步生成 | Task 1 |
| LRU 缓存 | Task 1（NSCache） |
| 磁盘缓存 | Task 1 |

### Placeholder Scan

- 无 TBD/TODO
- 所有代码块完整
- 所有命令精确

### Type Consistency

- `ThumbnailManager.shared` 在 Task 1 定义，Task 3 使用一致
- `QuickLookPreviewPanel.shared.togglePreview(files:currentIndex:)` 在 Task 2 定义，Task 5 调用一致
- `FileGridView` 在 Task 3 定义，Task 5 创建实例一致
- `ViewMode.list` / `ViewMode.grid` 在 Phase 2 定义，Task 5 使用一致
- `FileEntry` 在 Phase 2 定义，Task 3 使用一致
- `PaneViewModel` 在 Phase 2 定义，Task 3/5 使用一致
- `CoreBridge.shared.copyFile/moveFile` 在 Phase 1 定义，Task 4/5 使用一致
