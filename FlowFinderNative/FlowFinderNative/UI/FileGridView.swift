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

        pathLabel = NSTextField(labelWithString: "")
        pathLabel.isHidden = true
        pathLabel.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(imageView)
        view.addSubview(nameLabel)
        view.addSubview(pathLabel)

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
