import Cocoa

/// 批量重命名窗口控制器：模式替换 / 序号添加 / 大小写转换 + 实时预览
public class BatchRenameWindowController: NSWindowController {

    public static let shared = BatchRenameWindowController()

    // MARK: - State

    private var files: [FileEntry] = []
    private weak var paneViewModel: PaneViewModel?

    /// 计算后的预览结果（与 files 一一对应）
    private var previewNames: [String] = []
    /// 冲突标记（与 files 一一对应；true 表示该行的新名称冲突）
    private var conflictFlags: [Bool] = []
    /// 目录中已存在的文件名集合（不含正在被重命名的原名），用于冲突检测
    private var existingNames: Set<String> = []

    private enum RenameMode: Int {
        case pattern = 0
        case sequence = 1
        case caseChange = 2
    }

    private var selectedMode: RenameMode {
        return RenameMode(rawValue: modeSegmentedControl.selectedSegment) ?? .pattern
    }

    private enum CaseOption: String {
        case upper = "大写"
        case lower = "小写"
        case capitalized = "首字母大写"
        case unchanged = "不变"
    }

    // MARK: - UI Elements

    private var modeSegmentedControl: NSSegmentedControl!
    private var patternField: NSTextField!
    private var patternHintLabel: NSTextField!
    private var sequenceContainer: NSView!
    private var patternContainer: NSView!
    private var caseContainer: NSView!
    private var prefixField: NSTextField!
    private var suffixField: NSTextField!
    private var startIndexField: NSTextField!
    private var stepField: NSTextField!
    private var casePopup: NSPopUpButton!
    private var previewTableView: NSTableView!
    private var scrollView: NSScrollView!
    private var renameButton: NSButton!
    private var cancelButton: NSButton!

    // MARK: - Init

    private override init(window: NSWindow?) {
        super.init(window: window)
    }

    private convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 500),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "批量重命名"
        window.minSize = NSSize(width: 560, height: 400)
        window.center()
        window.setFrameAutosaveName("BatchRenameWindow")
        self.init(window: window)
        setupUI()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - UI Setup

    private func setupUI() {
        guard let window = window else { return }
        let contentView = window.contentView!

        // 顶部模式切换
        modeSegmentedControl = NSSegmentedControl(
            labels: ["模式替换", "序号添加", "大小写转换"],
            trackingMode: .selectOne,
            target: self,
            action: #selector(modeChanged)
        )
        modeSegmentedControl.selectedSegment = 0
        modeSegmentedControl.translatesAutoresizingMaskIntoConstraints = false

        // 模式容器：模式替换
        patternContainer = NSView()
        patternContainer.translatesAutoresizingMaskIntoConstraints = false

        patternField = NSTextField(string: "{name}.{ext}")
        patternField.placeholderString = "{name}.{ext}"
        patternField.target = self
        patternField.action = #selector(patternFieldChanged)
        patternField.delegate = self
        patternField.translatesAutoresizingMaskIntoConstraints = false

        patternHintLabel = NSTextField(labelWithString: "占位符: {name} 文件名  {ext} 扩展名  {index} 序号(1开始)  {index0} 序号(0开始)  {index:N} 零填充N位")
        patternHintLabel.font = NSFont.systemFont(ofSize: 10)
        patternHintLabel.textColor = NSColor.secondaryLabelColor
        patternHintLabel.lineBreakMode = .byTruncatingTail
        patternHintLabel.translatesAutoresizingMaskIntoConstraints = false

        patternContainer.addSubview(patternField)
        patternContainer.addSubview(patternHintLabel)

        NSLayoutConstraint.activate([
            patternField.topAnchor.constraint(equalTo: patternContainer.topAnchor),
            patternField.leadingAnchor.constraint(equalTo: patternContainer.leadingAnchor),
            patternField.trailingAnchor.constraint(equalTo: patternContainer.trailingAnchor),

            patternHintLabel.topAnchor.constraint(equalTo: patternField.bottomAnchor, constant: 4),
            patternHintLabel.leadingAnchor.constraint(equalTo: patternContainer.leadingAnchor),
            patternHintLabel.trailingAnchor.constraint(equalTo: patternContainer.trailingAnchor),
            patternHintLabel.bottomAnchor.constraint(equalTo: patternContainer.bottomAnchor),
        ])

        // 模式容器：序号添加
        sequenceContainer = NSView()
        sequenceContainer.translatesAutoresizingMaskIntoConstraints = false
        sequenceContainer.isHidden = true

        let prefixLabel = NSTextField(labelWithString: "前缀:")
        prefixLabel.translatesAutoresizingMaskIntoConstraints = false
        prefixField = NSTextField(string: "IMG_")
        prefixField.placeholderString = "前缀（可空）"
        prefixField.delegate = self
        prefixField.translatesAutoresizingMaskIntoConstraints = false

        let suffixLabel = NSTextField(labelWithString: "后缀:")
        suffixLabel.translatesAutoresizingMaskIntoConstraints = false
        suffixField = NSTextField(string: "")
        suffixField.placeholderString = "后缀（可空）"
        suffixField.delegate = self
        suffixField.translatesAutoresizingMaskIntoConstraints = false

        let startLabel = NSTextField(labelWithString: "起始:")
        startLabel.translatesAutoresizingMaskIntoConstraints = false
        startIndexField = NSTextField(string: "1")
        startIndexField.delegate = self
        startIndexField.translatesAutoresizingMaskIntoConstraints = false

        let stepLabel = NSTextField(labelWithString: "步长:")
        stepLabel.translatesAutoresizingMaskIntoConstraints = false
        stepField = NSTextField(string: "1")
        stepField.delegate = self
        stepField.translatesAutoresizingMaskIntoConstraints = false

        sequenceContainer.addSubview(prefixLabel)
        sequenceContainer.addSubview(prefixField)
        sequenceContainer.addSubview(suffixLabel)
        sequenceContainer.addSubview(suffixField)
        sequenceContainer.addSubview(startLabel)
        sequenceContainer.addSubview(startIndexField)
        sequenceContainer.addSubview(stepLabel)
        sequenceContainer.addSubview(stepField)

        NSLayoutConstraint.activate([
            prefixLabel.topAnchor.constraint(equalTo: sequenceContainer.topAnchor),
            prefixLabel.leadingAnchor.constraint(equalTo: sequenceContainer.leadingAnchor),
            prefixLabel.widthAnchor.constraint(equalToConstant: 40),

            prefixField.topAnchor.constraint(equalTo: sequenceContainer.topAnchor),
            prefixField.leadingAnchor.constraint(equalTo: prefixLabel.trailingAnchor, constant: 4),
            prefixField.widthAnchor.constraint(equalToConstant: 120),

            suffixLabel.topAnchor.constraint(equalTo: sequenceContainer.topAnchor),
            suffixLabel.leadingAnchor.constraint(equalTo: prefixField.trailingAnchor, constant: 12),
            suffixLabel.widthAnchor.constraint(equalToConstant: 40),

            suffixField.topAnchor.constraint(equalTo: sequenceContainer.topAnchor),
            suffixField.leadingAnchor.constraint(equalTo: suffixLabel.trailingAnchor, constant: 4),
            suffixField.widthAnchor.constraint(equalToConstant: 120),

            startLabel.topAnchor.constraint(equalTo: sequenceContainer.topAnchor),
            startLabel.leadingAnchor.constraint(equalTo: suffixField.trailingAnchor, constant: 12),
            startLabel.widthAnchor.constraint(equalToConstant: 40),

            startIndexField.topAnchor.constraint(equalTo: sequenceContainer.topAnchor),
            startIndexField.leadingAnchor.constraint(equalTo: startLabel.trailingAnchor, constant: 4),
            startIndexField.widthAnchor.constraint(equalToConstant: 60),

            stepLabel.topAnchor.constraint(equalTo: sequenceContainer.topAnchor),
            stepLabel.leadingAnchor.constraint(equalTo: startIndexField.trailingAnchor, constant: 12),
            stepLabel.widthAnchor.constraint(equalToConstant: 40),

            stepField.topAnchor.constraint(equalTo: sequenceContainer.topAnchor),
            stepField.leadingAnchor.constraint(equalTo: stepLabel.trailingAnchor, constant: 4),
            stepField.widthAnchor.constraint(equalToConstant: 60),

            sequenceContainer.bottomAnchor.constraint(equalTo: prefixField.bottomAnchor, constant: 8),
        ])

        // 模式容器：大小写转换
        caseContainer = NSView()
        caseContainer.translatesAutoresizingMaskIntoConstraints = false
        caseContainer.isHidden = true

        let caseLabel = NSTextField(labelWithString: "转换方式:")
        caseLabel.translatesAutoresizingMaskIntoConstraints = false
        casePopup = NSPopUpButton()
        casePopup.addItems(withTitles: ["大写", "小写", "首字母大写", "不变"])
        casePopup.selectItem(at: 0)
        casePopup.target = self
        casePopup.action = #selector(casePopupChanged)
        casePopup.translatesAutoresizingMaskIntoConstraints = false

        caseContainer.addSubview(caseLabel)
        caseContainer.addSubview(casePopup)

        NSLayoutConstraint.activate([
            caseLabel.topAnchor.constraint(equalTo: caseContainer.topAnchor),
            caseLabel.leadingAnchor.constraint(equalTo: caseContainer.leadingAnchor),
            caseLabel.bottomAnchor.constraint(equalTo: caseContainer.bottomAnchor),

            casePopup.topAnchor.constraint(equalTo: caseContainer.topAnchor),
            casePopup.leadingAnchor.constraint(equalTo: caseLabel.trailingAnchor, constant: 8),
            casePopup.bottomAnchor.constraint(equalTo: caseContainer.bottomAnchor),
        ])

        // 预览表
        scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        previewTableView = NSTableView()
        previewTableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        previewTableView.usesAlternatingRowBackgroundColors = true
        previewTableView.rowHeight = 22
        previewTableView.dataSource = self
        previewTableView.delegate = self

        let oldCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("old"))
        oldCol.title = "原名称"
        oldCol.width = 300
        previewTableView.addTableColumn(oldCol)

        let newCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("new"))
        newCol.title = "新名称"
        newCol.width = 300
        previewTableView.addTableColumn(newCol)

        scrollView.documentView = previewTableView

        // 底部按钮栏
        let buttonBar = NSView()
        buttonBar.translatesAutoresizingMaskIntoConstraints = false

        cancelButton = NSButton(title: "取消", target: self, action: #selector(cancelClicked))
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"  // Esc
        cancelButton.translatesAutoresizingMaskIntoConstraints = false

        renameButton = NSButton(title: "重命名", target: self, action: #selector(performRename))
        renameButton.bezelStyle = .rounded
        renameButton.keyEquivalent = "\r"  // Return
        renameButton.translatesAutoresizingMaskIntoConstraints = false

        buttonBar.addSubview(cancelButton)
        buttonBar.addSubview(renameButton)

        NSLayoutConstraint.activate([
            cancelButton.topAnchor.constraint(equalTo: buttonBar.topAnchor),
            cancelButton.bottomAnchor.constraint(equalTo: buttonBar.bottomAnchor),
            cancelButton.trailingAnchor.constraint(equalTo: buttonBar.trailingAnchor),

            renameButton.topAnchor.constraint(equalTo: buttonBar.topAnchor),
            renameButton.bottomAnchor.constraint(equalTo: buttonBar.bottomAnchor),
            renameButton.trailingAnchor.constraint(equalTo: cancelButton.leadingAnchor, constant: -8),
        ])

        // 整体布局
        contentView.addSubview(modeSegmentedControl)
        contentView.addSubview(patternContainer)
        contentView.addSubview(sequenceContainer)
        contentView.addSubview(caseContainer)
        contentView.addSubview(scrollView)
        contentView.addSubview(buttonBar)

        NSLayoutConstraint.activate([
            modeSegmentedControl.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            modeSegmentedControl.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            modeSegmentedControl.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),

            patternContainer.topAnchor.constraint(equalTo: modeSegmentedControl.bottomAnchor, constant: 12),
            patternContainer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            patternContainer.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),

            sequenceContainer.topAnchor.constraint(equalTo: modeSegmentedControl.bottomAnchor, constant: 12),
            sequenceContainer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            sequenceContainer.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),

            caseContainer.topAnchor.constraint(equalTo: modeSegmentedControl.bottomAnchor, constant: 12),
            caseContainer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            caseContainer.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),

            scrollView.topAnchor.constraint(equalTo: patternContainer.bottomAnchor, constant: 12),
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            scrollView.bottomAnchor.constraint(equalTo: buttonBar.topAnchor, constant: -12),

            buttonBar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            buttonBar.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            buttonBar.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12),
            buttonBar.heightAnchor.constraint(equalToConstant: 28),
        ])
    }

    // MARK: - Public API

    public func showWindow(selectedFiles: [FileEntry], paneViewModel: PaneViewModel?) {
        self.files = selectedFiles
        self.paneViewModel = paneViewModel
        computeExistingNames()
        updatePreview()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    /// 收集所选文件所在目录的现有文件名，用于冲突检测。
    /// 排除正在被重命名的文件原名（这些将被新名替换）。
    private func computeExistingNames() {
        existingNames.removeAll()
        guard let firstPath = files.first?.path else { return }
        let dir = (firstPath as NSString).deletingLastPathComponent
        let renamingOldNames = Set(files.map { $0.name })
        if let entries = try? FileManager.default.contentsOfDirectory(atPath: dir) {
            for name in entries where !renamingOldNames.contains(name) {
                existingNames.insert(name)
            }
        }
    }

    // MARK: - Actions

    @objc private func modeChanged(_ sender: Any?) {
        let mode = selectedMode
        patternContainer.isHidden = (mode != .pattern)
        sequenceContainer.isHidden = (mode != .sequence)
        caseContainer.isHidden = (mode != .caseChange)
        updatePreview()
    }

    @objc private func patternFieldChanged(_ sender: Any?) {
        updatePreview()
    }

    @objc private func casePopupChanged(_ sender: Any?) {
        updatePreview()
    }

    @objc private func cancelClicked(_ sender: Any?) {
        close()
    }

    // MARK: - Pattern Engine

    /// 根据当前所选模式计算第 index 个文件的新名称
    private func computeNewName(for entry: FileEntry, index: Int) -> String {
        switch selectedMode {
        case .pattern:
            return applyPattern(patternField.stringValue, entry: entry, index: index)
        case .sequence:
            let start = Int(startIndexField.stringValue) ?? 1
            let step = Int(stepField.stringValue) ?? 1
            let num = start + index * step
            let prefix = prefixField.stringValue
            let suffix = suffixField.stringValue
            let ext = entry.fileExtension.isEmpty ? "" : ".\(entry.fileExtension)"
            return "\(prefix)\(num)\(suffix)\(ext)"
        case .caseChange:
            let option = casePopup.selectedItem?.title ?? ""
            return applyCaseChange(entry.name, caseOption: option)
        }
    }

    /// 模式替换占位符：
    /// - {name} 文件名（不含扩展名）
    /// - {ext} 扩展名（不含点，小写）
    /// - {index} 序号从 1 开始
    /// - {index0} 序号从 0 开始
    /// - {index:N} 零填充 N 位（如 {index:3} -> 001, 002, ...）
    ///
    /// 注意：先处理 {index:N}，再处理 {index} 和 {index0}，否则 {index:3}
    /// 会先被 {index} 部分替换为 "1:3" 而破坏后续正则匹配。
    /// {index:N} 使用安全的「先收集所有匹配，再倒序替换」方式，避免在
    /// enumerateMatches 中修改字符串造成的索引错位。
    private func applyPattern(_ pattern: String, entry: FileEntry, index: Int) -> String {
        var result = pattern

        // 先替换 {name} 和 {ext}（不含 {index} 前缀，安全）
        result = result.replacingOccurrences(of: "{name}", with: entry.displayName)
        result = result.replacingOccurrences(of: "{ext}", with: entry.fileExtension)

        // 处理 {index:N}（零填充）。必须先于 {index} / {index0} 处理。
        if let regex = try? NSRegularExpression(pattern: "\\{index:(\\d+)\\}") {
            let nsString = NSMutableString(string: result)
            let fullRange = NSRange(location: 0, length: nsString.length)
            let matches = regex.matches(in: result, range: fullRange)
            // 倒序替换以保持索引稳定
            for match in matches.reversed() {
                guard match.numberOfRanges >= 2,
                      let nRange = Range(match.range(at: 1), in: result) else { continue }
                let n = Int(result[nRange]) ?? 1
                let padded = String(format: "%0\(n)d", index + 1)
                nsString.replaceCharacters(in: match.range, with: padded)
            }
            result = nsString as String
        }

        // 在 {index:N} 已被替换后，处理简单占位符
        result = result.replacingOccurrences(of: "{index}", with: "\(index + 1)")
        result = result.replacingOccurrences(of: "{index0}", with: "\(index)")

        return result
    }

    private func applyCaseChange(_ name: String, caseOption: String) -> String {
        switch caseOption {
        case CaseOption.upper.rawValue:
            return name.uppercased()
        case CaseOption.lower.rawValue:
            return name.lowercased()
        case CaseOption.capitalized.rawValue:
            return name.capitalized
        default:
            return name
        }
    }

    // MARK: - Preview

    /// 重新计算所有新名称并刷新预览表。任何输入变化都应调用此方法。
    private func updatePreview() {
        previewNames = files.indices.map { computeNewName(for: files[$0], index: $0) }

        // 冲突检测：两个新名相同，或与目录中已存在的非重命名文件同名
        var nameCount: [String: Int] = [:]
        for name in previewNames {
            nameCount[name, default: 0] += 1
        }
        conflictFlags = previewNames.map { name in
            if name.isEmpty { return true }
            if nameCount[name, default: 0] > 1 { return true }
            if existingNames.contains(name) { return true }
            return false
        }

        previewTableView.reloadData()

        let hasConflict = conflictFlags.contains(true)
        let hasAnyChange = files.indices.contains { i in
            previewNames[i] != files[i].name && !previewNames[i].isEmpty
        }
        renameButton.isEnabled = !hasConflict && hasAnyChange && !files.isEmpty
    }

    // MARK: - Perform Rename

    @objc private func performRename(_ sender: Any?) {
        var items: [(String, String)] = []
        for (i, entry) in files.enumerated() {
            let newName = previewNames[i]
            if newName != entry.name && !newName.isEmpty {
                items.append((entry.path, newName))
            }
        }

        guard !items.isEmpty else {
            close()
            return
        }

        // 在跳到后台线程前，先收集成功后用于撤销的反向重命名对
        let reverseItems: [(String, String)] = items.map { (oldPath, newName) -> (String, String) in
            let dir = (oldPath as NSString).deletingLastPathComponent
            let newPath = (dir as NSString).appendingPathComponent(newName)
            let oldName = (oldPath as NSString).lastPathComponent
            return (newPath, oldName)  // 从新路径 rename 回旧名
        }

        renameButton.isEnabled = false

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let success = try CoreBridge.shared.batchRename(items: items)
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    // 刷新目录缓存以反映重命名
                    if let firstPath = items.first?.0 {
                        let dir = (firstPath as NSString).deletingLastPathComponent
                        try? CoreBridge.shared.invalidateCache(path: dir)
                    }
                    self.paneViewModel?.refresh()
                    self.registerUndoForBatchRename(items: items, reverseItems: reverseItems)
                    self.close()
                    _ = success
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    self.renameButton.isEnabled = true
                    self.showError(error: error)
                }
            }
        }
    }

    // MARK: - Undo

    private func registerUndoForBatchRename(
        items: [(String, String)],
        reverseItems: [(String, String)]
    ) {
        guard let vm = paneViewModel, let undoManager = vm.undoManager else { return }
        let count = items.count

        undoManager.registerUndo(withTarget: vm) { [weak vm] vm in
            // 撤销：反向 rename（从新路径改回旧名）
            for (newPath, oldName) in reverseItems {
                let dir = (newPath as NSString).deletingLastPathComponent
                let restorePath = (dir as NSString).appendingPathComponent(oldName)
                try? CoreBridge.shared.renameFile(src: newPath, dst: restorePath)
            }
            if let firstNew = reverseItems.first?.0 {
                let dir = (firstNew as NSString).deletingLastPathComponent
                try? CoreBridge.shared.invalidateCache(path: dir)
            }
            // 注册 redo：再次执行批量重命名
            vm.undoManager?.registerUndo(withTarget: vm) { vm2 in
                for (oldPath, newName) in items {
                    let dir = (oldPath as NSString).deletingLastPathComponent
                    let newPath = (dir as NSString).appendingPathComponent(newName)
                    try? CoreBridge.shared.renameFile(src: oldPath, dst: newPath)
                }
                if let firstOld = items.first?.0 {
                    let dir = (firstOld as NSString).deletingLastPathComponent
                    try? CoreBridge.shared.invalidateCache(path: dir)
                }
                vm2.refresh()
            }
            vm.undoManager?.setActionName("批量重命名 \(count) 个项目")
            vm.refresh()
        }
        undoManager.setActionName("批量重命名 \(count) 个项目")
    }

    // MARK: - Helpers

    private func showError(error: Error) {
        let alert = NSAlert()
        alert.messageText = "批量重命名失败"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .critical
        alert.addButton(withTitle: "好")
        if let window = window { alert.beginSheetModal(for: window) { _ in } }
    }
}

// MARK: - NSTextFieldDelegate / NSControlTextEditingDelegate

extension BatchRenameWindowController: NSTextFieldDelegate, NSControlTextEditingDelegate {
    public func controlTextDidChange(_ obj: Notification) {
        updatePreview()
    }
}

// MARK: - NSTableViewDataSource

extension BatchRenameWindowController: NSTableViewDataSource {
    public func numberOfRows(in tableView: NSTableView) -> Int {
        return files.count
    }
}

// MARK: - NSTableViewDelegate

extension BatchRenameWindowController: NSTableViewDelegate {
    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let columnID = tableColumn?.identifier.rawValue ?? "old"
        let cellID = NSUserInterfaceItemIdentifier("\(columnID)_cell")
        let cellView = tableView.makeView(withIdentifier: cellID, owner: self) as? NSTableCellView
            ?? NSTableCellView()
        cellView.identifier = cellID

        if cellView.textField == nil {
            let tf = NSTextField(labelWithString: "")
            tf.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
            tf.lineBreakMode = .byTruncatingTail
            tf.translatesAutoresizingMaskIntoConstraints = false
            cellView.addSubview(tf)
            cellView.textField = tf
            NSLayoutConstraint.activate([
                tf.leadingAnchor.constraint(equalTo: cellView.leadingAnchor, constant: 4),
                tf.trailingAnchor.constraint(equalTo: cellView.trailingAnchor, constant: -4),
                tf.centerYAnchor.constraint(equalTo: cellView.centerYAnchor),
            ])
        }

        guard row < files.count else { return cellView }
        let entry = files[row]

        switch columnID {
        case "old":
            cellView.textField?.stringValue = entry.name
            cellView.textField?.textColor = NSColor.labelColor
        case "new":
            if row < previewNames.count {
                cellView.textField?.stringValue = previewNames[row]
            } else {
                cellView.textField?.stringValue = ""
            }
            if row < conflictFlags.count, conflictFlags[row] {
                cellView.textField?.textColor = NSColor.systemRed
            } else {
                cellView.textField?.textColor = NSColor.labelColor
            }
        default:
            break
        }

        return cellView
    }
}
