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
