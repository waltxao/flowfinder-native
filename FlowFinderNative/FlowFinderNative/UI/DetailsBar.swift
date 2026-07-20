import Cocoa
import Combine

// MARK: - DetailsBar

class DetailsBar: NSView {
    private var file: FileEntry?
    private var selectedCount: Int = 0
    private var collapsed: Bool = false

    private var iconView: NSImageView!
    private var nameField: NSTextField!
    private var typeField: NSTextField!
    private var sizeField: NSTextField!
    private var modifiedField: NSTextField!
    private var createdField: NSTextField!
    private var tagsField: NSTextField!
    private var collapseButton: NSButton!

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupUI()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupUI()
    }

    private func setupUI() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.borderWidth = 1

        // Icon
        iconView = NSImageView()
        iconView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconView)

        // Collapse button
        collapseButton = NSButton()
        collapseButton.title = ""
        collapseButton.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "折叠")
        collapseButton.bezelStyle = .texturedRounded
        collapseButton.imagePosition = .imageOnly
        collapseButton.target = self
        collapseButton.action = #selector(collapseClicked)
        collapseButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(collapseButton)

        // Details grid
        let detailsStack = NSStackView()
        detailsStack.orientation = .vertical
        detailsStack.spacing = 4
        detailsStack.translatesAutoresizingMaskIntoConstraints = false

        nameField = createDetailField(label: "名称:")
        typeField = createDetailField(label: "类型:")
        sizeField = createDetailField(label: "大小:")
        modifiedField = createDetailField(label: "修改:")
        createdField = createDetailField(label: "创建:")
        tagsField = createDetailField(label: "标签:")

        detailsStack.addArrangedSubview(nameField)
        detailsStack.addArrangedSubview(typeField)
        detailsStack.addArrangedSubview(sizeField)
        detailsStack.addArrangedSubview(modifiedField)
        detailsStack.addArrangedSubview(createdField)
        detailsStack.addArrangedSubview(tagsField)

        addSubview(detailsStack)

        // Constraints
        NSLayoutConstraint.activate([
            collapseButton.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            collapseButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            collapseButton.widthAnchor.constraint(equalToConstant: 24),
            collapseButton.heightAnchor.constraint(equalToConstant: 24),

            iconView.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            iconView.widthAnchor.constraint(equalToConstant: 48),
            iconView.heightAnchor.constraint(equalToConstant: 48),

            detailsStack.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            detailsStack.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 12),
            detailsStack.trailingAnchor.constraint(equalTo: collapseButton.leadingAnchor, constant: -8),
            detailsStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
    }

    private func createDetailField(label: String) -> NSTextField {
        let labelView = NSTextField(labelWithString: label)
        labelView.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        labelView.textColor = NSColor.secondaryLabelColor

        let valueView = NSTextField(labelWithString: "")
        valueView.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        valueView.textColor = NSColor.labelColor
        valueView.lineBreakMode = .byTruncatingTail

        let stack = NSStackView(views: [labelView, valueView])
        stack.orientation = .horizontal
        stack.spacing = 4
        stack.alignment = .centerY

        // Store reference to value view for updates
        objc_setAssociatedObject(stack, "valueField", valueView, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)

        let container = NSView()
        container.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        // Return the value field directly so we can update it
        return valueView
    }

    // MARK: - Public API

    func setFile(_ file: FileEntry?) {
        self.file = file
        updateDetails()
    }

    func setSelectedCount(_ count: Int) {
        self.selectedCount = count
        updateDetails()
    }

    /// 统一更新方法（MainWindowController 调用）
    func update(file: FileEntry?, selectedCount: Int) {
        self.file = file
        self.selectedCount = selectedCount
        updateDetails()
    }

    // MARK: - Private

    private func updateDetails() {
        if selectedCount > 1 {
            nameField.stringValue = "已选中 \(selectedCount) 项"
            typeField.stringValue = ""
            sizeField.stringValue = ""
            modifiedField.stringValue = ""
            createdField.stringValue = ""
            tagsField.stringValue = ""
            iconView.image = nil
            return
        }

        guard let file = file else {
            nameField.stringValue = "未选择文件"
            typeField.stringValue = ""
            sizeField.stringValue = ""
            modifiedField.stringValue = ""
            createdField.stringValue = ""
            tagsField.stringValue = ""
            iconView.image = nil
            return
        }

        nameField.stringValue = file.name
        typeField.stringValue = file.kindDescription
        sizeField.stringValue = file.formattedSize
        modifiedField.stringValue = file.formattedModificationDate
        createdField.stringValue = file.formattedCreationDate

        // Tags from xattr
        let tags = TagBridge.shared.getTags(path: file.path)
        tagsField.stringValue = tags.isEmpty ? "无" : tags.map { $0.name }.joined(separator: ", ")

        // Icon
        if file.isDirectory {
            iconView.image = NSImage(systemSymbolName: "folder", accessibilityDescription: "文件夹")
                ?? NSImage(named: NSImage.folderName)
        } else {
            iconView.image = NSImage(systemSymbolName: "doc", accessibilityDescription: "文件")
                ?? NSImage(named: NSImage.multipleDocumentsName)
        }
    }

    private func formatBytes(_ bytes: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    /// 折叠状态的高度约束引用（用于 Auto Layout 动画）
    private var heightConstraint: NSLayoutConstraint?

    @objc private func collapseClicked() {
        collapsed.toggle()

        // 更新按钮图标
        let symbolName = collapsed ? "chevron.right" : "chevron.down"
        collapseButton.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: collapsed ? "展开" : "折叠")

        // 隐藏/显示详情字段（保留图标和折叠按钮可见）
        let detailViews: [NSView] = [nameField, typeField, sizeField, modifiedField, createdField, tagsField]
        for view in detailViews {
            view.isHidden = collapsed
        }

        // 通过 Auto Layout 约束改变高度（非直接改 frame）
        if heightConstraint == nil {
            heightConstraint = heightAnchor.constraint(equalToConstant: 120)
            heightConstraint?.isActive = true
        }

        heightConstraint?.constant = collapsed ? 28 : 120

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            context.allowsImplicitAnimation = true
            window?.layoutIfNeeded()
        }
    }
}
