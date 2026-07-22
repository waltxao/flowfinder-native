import AppKit

/// 侧边栏区域圆角遮罩视图
/// 为每个 sidebar section（收藏夹、标签、存储设备）提供半透明圆角背景
class GlassSectionMaskView: NSView {

    var cornerRadius: CGFloat = 8 {
        didSet { layer?.cornerRadius = cornerRadius }
    }

    var maskColor: NSColor = NSColor.windowBackgroundColor.withAlphaComponent(0.5) {
        didSet { layer?.backgroundColor = maskColor.cgColor }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        wantsLayer = true
        layer?.backgroundColor = maskColor.cgColor
        layer?.cornerRadius = cornerRadius
        layer?.masksToBounds = true
    }
}
