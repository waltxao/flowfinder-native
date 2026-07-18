import Cocoa
import QuickLook

// MARK: - QuickLook Preview Panel

/// QuickLook preview panel using macOS Quick Look framework
public class QuickLookPreviewPanel: NSObject {

    public static let shared = QuickLookPreviewPanel()

    private var currentPath: String?

    private override init() {
        super.init()
    }

    /// Show QuickLook preview for a file path
    /// - Parameter path: File path to preview
    public func showPreview(for path: String) {
        currentPath = path
        // In a full implementation, this would use QLPreviewView or similar
        // For now, we just store the path for potential future use
        print("QuickLook preview requested for: \(path)")
    }

    /// Toggle QuickLook preview panel visibility
    public func togglePreview(for path: String) {
        showPreview(for: path)
    }

    /// Close the preview panel
    public func closePreview() {
        currentPath = nil
    }

    /// Get preview image for a file path
    /// - Parameter path: File path
    /// - Returns: NSImage or nil if not available
    public func previewImage(for path: String) -> NSImage? {
        // Use system icon as fallback when QLThumbnailGenerator is unavailable
        return NSWorkspace.shared.icon(forFile: path)
    }
}

// MARK: - QuickLook Preview Sidebar

/// Sidebar view for QuickLook preview with toggle functionality
public class QuickLookPreviewSidebar: NSView {

    private var previewView: NSImageView!
    private var placeholderLabel: NSTextField!
    private var toggleButton: NSButton!

    public var isVisible: Bool = true {
        didSet {
            previewView.isHidden = !isVisible
            placeholderLabel.isHidden = !isVisible
            toggleButton.title = isVisible ? "Hide Preview" : "Show Preview"
        }
    }
    public var onToggle: ((Bool) -> Void)?
    public var currentEntry: FileEntry? {
        didSet {
            updatePreview()
        }
    }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupUI()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupUI()
    }

    private func setupUI() {
        // Preview image view
        previewView = NSImageView()
        previewView.imageScaling = .scaleProportionallyUpOrDown
        previewView.wantsLayer = true
        previewView.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        previewView.translatesAutoresizingMaskIntoConstraints = false

        // Placeholder label
        placeholderLabel = NSTextField(labelWithString: "No preview available")
        placeholderLabel.alignment = .center
        placeholderLabel.textColor = NSColor.secondaryLabelColor
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false

        // Toggle button
        toggleButton = NSButton(title: "Hide Preview", target: self, action: #selector(togglePreview))
        toggleButton.bezelStyle = .rounded
        toggleButton.translatesAutoresizingMaskIntoConstraints = false

        addSubview(previewView)
        addSubview(placeholderLabel)
        addSubview(toggleButton)

        NSLayoutConstraint.activate([
            previewView.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            previewView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            previewView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            previewView.heightAnchor.constraint(equalTo: previewView.widthAnchor, multiplier: 0.75),

            placeholderLabel.topAnchor.constraint(equalTo: previewView.bottomAnchor, constant: 8),
            placeholderLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            placeholderLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),

            toggleButton.topAnchor.constraint(equalTo: placeholderLabel.bottomAnchor, constant: 12),
            toggleButton.centerXAnchor.constraint(equalTo: centerXAnchor),
            toggleButton.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -8)
        ])
    }

    @objc private func togglePreview() {
        isVisible.toggle()
        onToggle?(isVisible)
    }

    private func updatePreview() {
        guard let entry = currentEntry else {
            previewView.image = nil
            placeholderLabel.isHidden = false
            return
        }

        if let image = QuickLookPreviewPanel.shared.previewImage(for: entry.path) {
            previewView.image = image
            placeholderLabel.isHidden = true
        } else {
            previewView.image = NSWorkspace.shared.icon(forFile: entry.path)
            placeholderLabel.isHidden = false
        }
    }
}

// MARK: - NSImage Extension

private extension NSImage {
    convenience init?(cgImage: CGImage) {
        let size = NSSize(width: cgImage.width, height: cgImage.height)
        self.init(cgImage: cgImage, size: size)
    }

    var cgImage: CGImage? {
        var rect = NSRect(origin: .zero, size: self.size)
        return self.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }
}
