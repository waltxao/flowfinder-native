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
    private var detailsContainer: NSView!

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
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.borderWidth = 1

        // Icon
        iconView = NSImageView()
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyUpOrDown
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

        // 创建详情行（每行包含 label + value）
        let (nameRow, nameValue) = createDetailRow(label: "名称:")
        let (typeRow, typeValue) = createDetailRow(label: "类型:")
        let (sizeRow, sizeValue) = createDetailRow(label: "大小:")
        let (modifiedRow, modifiedValue) = createDetailRow(label: "修改:")
        let (createdRow, createdValue) = createDetailRow(label: "创建:")
        let (tagsRow, tagsValue) = createDetailRow(label: "标签:")

        nameField = nameValue
        typeField = typeValue
        sizeField = sizeValue
        modifiedField = modifiedValue
        createdField = createdValue
        tagsField = tagsValue

        // 左列（名称/类型/大小）
        let leftColumn = NSStackView(views: [nameRow, typeRow, sizeRow])
        leftColumn.orientation = .vertical
        leftColumn.spacing = 4
        leftColumn.alignment = .leading
        leftColumn.translatesAutoresizingMaskIntoConstraints = false

        // 右列（修改/创建/标签）
        let rightColumn = NSStackView(views: [modifiedRow, createdRow, tagsRow])
        rightColumn.orientation = .vertical
        rightColumn.spacing = 4
        rightColumn.alignment = .leading
        rightColumn.translatesAutoresizingMaskIntoConstraints = false

        detailsContainer = NSView()
        detailsContainer.addSubview(leftColumn)
        detailsContainer.addSubview(rightColumn)
        detailsContainer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(detailsContainer)

        NSLayoutConstraint.activate([
            leftColumn.topAnchor.constraint(equalTo: detailsContainer.topAnchor),
            leftColumn.leadingAnchor.constraint(equalTo: detailsContainer.leadingAnchor),
            leftColumn.bottomAnchor.constraint(equalTo: detailsContainer.bottomAnchor),
            leftColumn.widthAnchor.constraint(lessThanOrEqualTo: detailsContainer.widthAnchor, multiplier: 0.55),

            rightColumn.topAnchor.constraint(equalTo: detailsContainer.topAnchor),
            rightColumn.leadingAnchor.constraint(equalTo: leftColumn.trailingAnchor, constant: 12),
            rightColumn.trailingAnchor.constraint(equalTo: detailsContainer.trailingAnchor),
            rightColumn.bottomAnchor.constraint(equalTo: detailsContainer.bottomAnchor),
        ])

        // 主约束
        NSLayoutConstraint.activate([
            collapseButton.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            collapseButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            collapseButton.widthAnchor.constraint(equalToConstant: 24),
            collapseButton.heightAnchor.constraint(equalToConstant: 24),

            iconView.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            iconView.widthAnchor.constraint(equalToConstant: 48),
            iconView.heightAnchor.constraint(equalToConstant: 48),

            detailsContainer.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            detailsContainer.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 12),
            detailsContainer.trailingAnchor.constraint(equalTo: collapseButton.leadingAnchor, constant: -8),
            detailsContainer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
    }

    /// 创建 label + value 水平排列的行
    /// - Returns: (rowView: 包含 label+value 的 NSStackView, valueField: 值 NSTextField)
    private func createDetailRow(label: String) -> (rowView: NSStackView, valueField: NSTextField) {
        let labelView = NSTextField(labelWithString: label)
        labelView.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        labelView.textColor = NSColor.secondaryLabelColor

        let valueView = NSTextField(labelWithString: "")
        valueView.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        valueView.textColor = NSColor.labelColor
        valueView.lineBreakMode = .byTruncatingTail
        valueView.maximumNumberOfLines = 1
        valueView.cell?.truncatesLastVisibleLine = true

        let row = NSStackView(views: [labelView, valueView])
        row.orientation = .horizontal
        row.spacing = 4
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false

        // 固定 label 宽度对齐（加宽以适应中文标签）
        labelView.widthAnchor.constraint(equalToConstant: 52).isActive = true

        return (row, valueView)
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

    @objc private func collapseClicked() {
        collapsed.toggle()

        // 更新按钮图标
        let symbolName = collapsed ? "chevron.right" : "chevron.down"
        collapseButton.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: collapsed ? "展开" : "折叠")

        // 隐藏/显示详情容器（保留图标和折叠按钮可见）
        detailsContainer.isHidden = collapsed

        // 通知父视图重新布局（高度由 MainWindowController 的约束控制）
        if let window = window {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                context.allowsImplicitAnimation = true
                window.layoutIfNeeded()
            }
        }
    }
}
