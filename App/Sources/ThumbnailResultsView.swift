import AppKit
import SwiftUI
import IndexCore

struct ThumbnailResultsView: NSViewRepresentable {
    var rows: [FileRecord]
    var selectedRecords: [FileRecord] = []
    var onSelection: ([FileRecord]) -> Void
    var onActivate: (FileRecord) -> Void
    var onPreview: (([FileRecord]) -> Void)? = nil
    var allowsNetwork = false

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let collection = ResultsKeyCollectionView()
        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = NSSize(width: 156, height: 144)
        layout.minimumInteritemSpacing = 12
        layout.minimumLineSpacing = 12
        layout.sectionInset = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        collection.collectionViewLayout = layout
        collection.isSelectable = true
        collection.allowsMultipleSelection = true
        collection.backgroundColors = [.clear]
        collection.register(ThumbnailItem.self, forItemWithIdentifier: ThumbnailItem.identifier)
        collection.dataSource = context.coordinator
        collection.delegate = context.coordinator
        collection.onResultKey = context.coordinator.handleResultKey
        collection.onLayout = { [weak coordinator = context.coordinator] in coordinator?.refreshVisible() }
        let activate = NSClickGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.activate(_:)))
        activate.numberOfClicksRequired = 2
        collection.addGestureRecognizer(activate)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.documentView = collection
        collection.frame = scroll.contentView.bounds
        collection.autoresizingMask = [.width]
        context.coordinator.collection = collection
        context.coordinator.observe(scroll.contentView)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) { context.coordinator.reload(self) }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) { coordinator.stop() }

    @MainActor final class Coordinator: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegate {
        var parent: ThumbnailResultsView
        weak var collection: ResultsKeyCollectionView?
        private weak var clip: NSClipView?
        private var tasks: [SelectionIdentity: Task<Void, Never>] = [:]
        private var completed: Set<SelectionIdentity> = []
        private var revision = UUID()
        private var suppressSelection = false
        private var refreshTask: Task<Void, Never>?
        private var loaded = false
        private let thumbnailService: ThumbnailService
        var loadingCount: Int { tasks.count }

        init(_ parent: ThumbnailResultsView, thumbnailService: ThumbnailService = .shared) {
            self.parent = parent
            self.thumbnailService = thumbnailService
        }

        func observe(_ clip: NSClipView) {
            self.clip = clip
            clip.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(boundsChanged(_:)),
                name: NSView.boundsDidChangeNotification, object: clip)
        }

        @objc private func boundsChanged(_ notification: Notification) { refreshVisible() }

        func stop() {
            tasks.values.forEach { $0.cancel() }
            tasks.removeAll()
            completed.removeAll()
            refreshTask?.cancel()
            refreshTask = nil
            NotificationCenter.default.removeObserver(self)
            revision = UUID()
            collection?.onLayout = nil
            collection?.onResultKey = nil
        }

        func reload(_ next: ThumbnailResultsView) {
            let changed = !loaded || next.rows != parent.rows || next.allowsNetwork != parent.allowsNetwork
            loaded = true
            parent = next
            guard let collection else { return }
            suppressSelection = true
            if changed {
                tasks.values.forEach { $0.cancel() }
                tasks.removeAll()
                completed.removeAll()
                revision = UUID()
                collection.reloadData()
            }
            let identities = Set(parent.selectedRecords.map(SelectionIdentity.init))
            collection.selectionIndexPaths = Set(parent.rows.indices.compactMap {
                identities.contains(SelectionIdentity(parent.rows[$0])) ? IndexPath(item: $0, section: 0) : nil
            })
            suppressSelection = false
            scheduleRefresh()
        }

        func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
            parent.rows.count
        }

        func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
            let item = collectionView.makeItem(withIdentifier: ThumbnailItem.identifier, for: indexPath)
            guard let item = item as? ThumbnailItem, parent.rows.indices.contains(indexPath.item) else { return item }
            item.configure(parent.rows[indexPath.item])
            return item
        }

        func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) { reportSelection() }
        func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) { reportSelection() }

        private func reportSelection() {
            guard !suppressSelection else { return }
            parent.onSelection(selection())
        }

        func selection() -> [FileRecord] {
            (collection?.selectionIndexPaths ?? []).sorted { $0.item < $1.item }.compactMap {
                parent.rows.indices.contains($0.item) ? parent.rows[$0.item] : nil
            }
        }

        func handleResultKey(_ action: ResultsKeyAction) -> Bool {
            let records = selection()
            switch action {
            case .preview:
                guard !records.isEmpty, let onPreview = parent.onPreview else { return false }
                onPreview(records)
            case .open:
                guard !records.isEmpty else { return false }
                ResultActions.open(records)
            case .copy:
                guard !records.isEmpty else { return false }
                ResultActions.copyFiles(records)
            case .paste:
                guard ResultActions.canPasteFiles else { return false }
                ResultActions.pasteFiles(into: records.count == 1 ? records.first : nil)
            case .undo:
                guard ResultActions.state.canUndo, !ResultActions.state.isBusy else { return false }
                ResultActions.undoLastOperation()
            }
            return true
        }

        @objc func activate(_ gesture: NSClickGestureRecognizer) {
            guard let collection, let index = collection.indexPathForItem(at: gesture.location(in: collection)),
                  parent.rows.indices.contains(index.item) else { return }
            parent.onActivate(parent.rows[index.item])
        }

        private func scheduleRefresh() {
            refreshTask?.cancel()
            refreshTask = Task { [weak self] in
                await Task.yield()
                guard !Task.isCancelled else { return }
                self?.refreshVisible()
            }
        }

        func refreshVisible() {
            guard let collection, collection.window?.isVisible == true else {
                tasks.values.forEach { $0.cancel() }
                tasks.removeAll()
                return
            }
            let visible = collection.indexPathsForVisibleItems().filter {
                parent.rows.indices.contains($0.item) &&
                    collection.item(at: $0)?.view.frame.intersects(collection.visibleRect) == true
            }
            let identities = Set(visible.map { SelectionIdentity(parent.rows[$0.item]) })
            for identity in Array(tasks.keys) where !identities.contains(identity) {
                tasks.removeValue(forKey: identity)?.cancel()
            }
            completed.formIntersection(identities)
            for index in visible {
                let record = parent.rows[index.item]
                let identity = SelectionIdentity(record)
                guard tasks[identity] == nil, !completed.contains(identity) else { continue }
                let revision = revision
                let allowsNetwork = parent.allowsNetwork
                let scale = collection.window?.backingScaleFactor ?? 1
                tasks[identity] = Task { [weak self] in
                    guard let service = self?.thumbnailService else { return }
                    let image = await service.image(for: record, scale: scale, allowsNetwork: allowsNetwork)
                    guard !Task.isCancelled, let self, self.revision == revision else { return }
                    self.tasks.removeValue(forKey: identity)
                    self.completed.insert(identity)
                    guard self.parent.rows.indices.contains(index.item),
                          SelectionIdentity(self.parent.rows[index.item]) == identity,
                          let item = self.collection?.item(at: index) as? ThumbnailItem,
                          item.identity == identity else { return }
                    if let image { item.imageView?.image = image }
                }
            }
        }
    }
}

@MainActor final class ResultsKeyCollectionView: NSCollectionView {
    var onResultKey: ((ResultsKeyAction) -> Bool)?
    var onLayout: (() -> Void)?

    override func layout() { super.layout(); onLayout?() }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command),
           let action = ResultsKeyAction.action(for: event, isResultsFirstResponder: window?.firstResponder === self),
           onResultKey?(action) == true { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if let action = ResultsKeyAction.action(for: event, isResultsFirstResponder: window?.firstResponder === self),
           onResultKey?(action) == true { return }
        super.keyDown(with: event)
    }
}

@MainActor private final class ThumbnailItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("native-thumbnail")
    var identity: SelectionIdentity?

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        view.layer?.cornerRadius = 8
        let image = NSImageView()
        image.imageScaling = .scaleProportionallyUpOrDown
        let label = NSTextField(labelWithString: "")
        label.alignment = .center
        label.maximumNumberOfLines = 2
        label.lineBreakMode = .byTruncatingMiddle
        imageView = image
        textField = label
        view.addSubview(image)
        view.addSubview(label)
        image.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            image.topAnchor.constraint(equalTo: view.topAnchor, constant: 6),
            image.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            image.widthAnchor.constraint(equalToConstant: 110),
            image.heightAnchor.constraint(equalToConstant: 100),
            label.topAnchor.constraint(equalTo: image.bottomAnchor, constant: 6),
            label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -4),
            label.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -4)
        ])
    }

    func configure(_ record: FileRecord) {
        identity = SelectionIdentity(record)
        // Source: FileRecord's actual name/path; the fallback icon is the native
        // UTType registry icon, resolved without opening the file.
        textField?.stringValue = record.name
        view.toolTip = record.path
        imageView?.image = FileIcons.icon(ext: (record.name as NSString).pathExtension, isDir: record.isDir)
        view.setAccessibilityLabel(record.name)
    }

    override var isSelected: Bool {
        didSet { view.layer?.backgroundColor = (isSelected ? NSColor.selectedContentBackgroundColor.withAlphaComponent(0.25) : .clear).cgColor }
    }
}
