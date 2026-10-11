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
    var resultList: SearchResultList? = nil
    var onVisibleRows: (([FileRecord]) -> Void)? = nil
    var onOrdering: ((UUID, Bool) -> Void)? = nil
    var selectedRows: SearchRowSelection? = nil
    var onRowSelection: ((SearchRowSelection) -> Void)? = nil
    var onRowAction: ((SearchRowSelection, ResultSelectionAction) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let collection = ResultsKeyCollectionView()
        collection.collectionViewLayout = ResultsGridLayout()
        collection.isSelectable = true
        collection.allowsMultipleSelection = true
        collection.backgroundColors = [.clear]
        collection.register(ThumbnailItem.self, forItemWithIdentifier: ThumbnailItem.identifier)
        collection.dataSource = context.coordinator
        collection.delegate = context.coordinator
        collection.onResultKey = context.coordinator.handleResultKey
        collection.onLayout = { [weak coordinator = context.coordinator] in coordinator?.refreshVisible() }
        collection.onSelectAll = { [weak coordinator = context.coordinator] in coordinator?.selectAllRows() }
        collection.onActivate = context.coordinator.activate
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
        private var orderingTask: Task<Void, Never>?
        private var selectionTask: Task<Void, Never>?
        private var rowCache: [Int: FileRecord] = [:]
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
            if let list = parent.resultList {
                let callback = parent.onOrdering
                Task { callback?(list.id, false) }
            }
            tasks.values.forEach { $0.cancel() }
            tasks.removeAll()
            completed.removeAll()
            refreshTask?.cancel()
            refreshTask = nil
            orderingTask?.cancel(); selectionTask?.cancel()
            NotificationCenter.default.removeObserver(self)
            revision = UUID()
            collection?.onLayout = nil
            collection?.onResultKey = nil
            collection?.onSelectAll = nil
            collection?.onActivate = nil
        }

        func reload(_ next: ThumbnailResultsView) {
            let changed = !loaded || next.rows != parent.rows || next.resultList !== parent.resultList || next.allowsNetwork != parent.allowsNetwork
            loaded = true
            parent = next
            guard let collection else { return }
            suppressSelection = true
            if changed {
                if let list = parent.resultList {
                    let callback = parent.onOrdering
                    Task { callback?(list.id, false) }
                }
                orderingTask?.cancel(); orderingTask = nil; rowCache = [:]
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
            if let selection = parent.selectedRows, selection.list === parent.resultList {
                collection.selectionIndexPaths = displayedSelection(selection)
            }
            suppressSelection = false
            selectionTask?.cancel()
            if parent.selectedRows == nil, let list = parent.resultList, !parent.selectedRecords.isEmpty {
                let records = parent.selectedRecords, expected = collection.selectionIndexPaths
                selectionTask = Task { [weak self] in
                    let indexes = await list.indexes(of: records)
                    guard !Task.isCancelled, let self, self.parent.resultList === list,
                          self.collection?.selectionIndexPaths == expected else { return }
                    self.suppressSelection = true
                    self.collection?.selectionIndexPaths = Set(indexes.map { IndexPath(item: $0, section: 0) })
                    self.suppressSelection = false
                }
            }
            scheduleRefresh()
        }

        func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
            parent.resultList?.count ?? parent.rows.count
        }

        func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
            let item = collectionView.makeItem(withIdentifier: ThumbnailItem.identifier, for: indexPath)
            guard let item = item as? ThumbnailItem else { return item }
            if let record = record(at: indexPath.item) { item.configure(record) }
            else { item.clear() }
            return item
        }

        func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
            updateSelection(indexPaths, adding: true, extending: extendsSelection)
        }
        func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
            updateSelection(indexPaths, adding: false, extending: extendsSelection)
        }

        private var extendsSelection: Bool {
            collection?.selectionModifiers.intersection([.command, .shift]).isEmpty == false
        }

        func updateSelection(_ indexes: Set<IndexPath>, adding: Bool, extending: Bool) {
            guard !suppressSelection else { return }
            guard extending, let selected = parent.selectedRows, selected.list === parent.resultList else {
                reportSelection(); return
            }
            var rows = selected.rows
            for index in indexes { if adding { rows.insert(index.item) } else { rows.remove(index.item) } }
            let next = SearchRowSelection(list: selected.list, rows: rows)
            parent.selectedRows = next.count == 0 ? nil : next
            parent.onRowSelection?(next)
        }

        private func reportSelection() {
            guard !suppressSelection else { return }
            if let selection = rowSelection(), let callback = parent.onRowSelection {
                parent.selectedRows = selection.count == 0 ? nil : selection
                callback(selection); return
            }
            parent.onSelection(selection())
        }

        func selectAllRows() {
            guard let list = parent.resultList, let callback = parent.onRowSelection else { return }
            let selection = SearchRowSelection(list: list, rows: IndexSet(integersIn: 0..<list.count))
            parent.selectedRows = selection
            callback(selection)
            suppressSelection = true
            collection?.selectionIndexPaths = displayedSelection(selection)
            suppressSelection = false
        }

        private func displayedSelection(_ selection: SearchRowSelection) -> Set<IndexPath> {
            if selection.count <= 512 { return Set(selection.rows.map { IndexPath(item: $0, section: 0) }) }
            return Set((collection?.indexPathsForVisibleItems() ?? []).filter { selection.rows.contains($0.item) })
        }

        func selection() -> [FileRecord] {
            if let selected = parent.selectedRows, selected.list === parent.resultList { return selected.preview }
            return (collection?.selectionIndexPaths ?? []).sorted { $0.item < $1.item }.prefix(32).compactMap {
                record(at: $0.item)
            }
        }

        func handleResultKey(_ action: ResultsKeyAction) -> Bool {
            let records = selection()
            switch action {
            case .preview:
                guard !records.isEmpty, let onPreview = parent.onPreview else { return false }
                onPreview(records)
            case .open:
                guard (parent.selectedRows?.count ?? collection?.selectionIndexPaths.count ?? 0) > 0 else { return false }
                perform(.open)
            case .copy:
                guard (parent.selectedRows?.count ?? collection?.selectionIndexPaths.count ?? 0) > 0 else { return false }
                perform(.copyFiles)
            case .paste:
                guard ResultActions.canPasteFiles else { return false }
                let count = parent.selectedRows?.count ?? collection?.selectionIndexPaths.count ?? 0
                ResultActions.pasteFiles(into: count == 1 ? records.first : nil)
            case .undo:
                guard ResultActions.state.canUndo, !ResultActions.state.isBusy else { return false }
                ResultActions.undoLastOperation()
            }
            return true
        }

        func activate(_ point: NSPoint) {
            guard let collection, let index = collection.indexPathForItem(at: point),
                  let record = record(at: index.item) else { return }
            parent.onActivate(record)
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
                    collection.item(at: $0)?.view.frame.intersects(collection.visibleRect) == true
            }
            if let selected = parent.selectedRows, selected.list === parent.resultList, selected.count > 512 {
                suppressSelection = true
                collection.selectionIndexPaths = displayedSelection(selected)
                suppressSelection = false
            }
            let records = visible.sorted { $0.item < $1.item }.compactMap { record(at: $0.item) }
            let publication = parent.resultList
            Task { [weak self] in
                guard let self, self.parent.resultList === publication else { return }
                self.parent.onVisibleRows?(records)
            }
            let identities = Set(records.map(SelectionIdentity.init))
            for identity in Array(tasks.keys) where !identities.contains(identity) {
                tasks.removeValue(forKey: identity)?.cancel()
            }
            completed.formIntersection(identities)
            for index in visible {
                guard let record = record(at: index.item) else { continue }
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
                    guard let current = self.record(at: index.item), SelectionIdentity(current) == identity,
                          let item = self.collection?.item(at: index) as? ThumbnailItem,
                          item.identity == identity else { return }
                    if let image { item.imageView?.image = image }
                }
            }
        }

        func record(at row: Int) -> FileRecord? {
            guard let list = parent.resultList else { return parent.rows.indices.contains(row) ? parent.rows[row] : nil }
            if let cached = rowCache[row] { return cached }
            if let record = list.record(at: row) {
                if rowCache.count >= 512 { rowCache.removeAll(keepingCapacity: true) }
                rowCache[row] = record; return record
            }
            guard row >= 0, row < list.count, orderingTask == nil else { return nil }
            orderingTask = Task { [weak self] in
                self?.parent.onOrdering?(list.id, true)
                async let complete = list.prepare()
                if await list.prepareTail(), let self, self.parent.resultList === list, !Task.isCancelled {
                    self.collection?.reloadItems(at: Set(self.collection?.indexPathsForVisibleItems() ?? []))
                    self.scheduleRefresh()
                }
                let ready = await complete
                guard !Task.isCancelled, let self, self.parent.resultList === list else { return }
                self.orderingTask = nil
                self.parent.onOrdering?(list.id, false)
                guard ready, let collection = self.collection else { return }
                collection.reloadItems(at: Set(collection.indexPathsForVisibleItems()))
                if let selection = self.parent.selectedRows, selection.list === list {
                    self.parent.onRowSelection?(selection)
                } else { self.reportSelection() }
                self.scheduleRefresh()
            }
            return nil
        }

        private func rowSelection() -> SearchRowSelection? {
            guard let list = parent.resultList else { return nil }
            return SearchRowSelection(list: list, rows: IndexSet((collection?.selectionIndexPaths ?? []).map(\.item)))
        }
        private func perform(_ action: ResultSelectionAction) {
            if let selection = parent.selectedRows ?? rowSelection() {
                if let callback = parent.onRowAction { callback(selection, action) }
                else { Task { let records = await selection.records(); if !Task.isCancelled { action.perform(records) } } }
            } else { action.perform(selection()) }
        }
    }
}

@MainActor final class ResultsKeyCollectionView: NSCollectionView {
    var onResultKey: ((ResultsKeyAction) -> Bool)?
    var onLayout: (() -> Void)?
    var onSelectAll: (() -> Void)?
    var onActivate: ((NSPoint) -> Void)?
    var selectionModifiers: NSEvent.ModifierFlags = []

    override func mouseDown(with event: NSEvent) {
        selectionModifiers = event.modifierFlags
        super.mouseDown(with: event)
        if event.clickCount == 2 { onActivate?(convert(event.locationInWindow, from: nil)) }
    }

    override func selectAll(_ sender: Any?) {
        if let onSelectAll { onSelectAll() } else { super.selectAll(sender) }
    }

    override func layout() { super.layout(); onLayout?() }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command),
           let action = ResultsKeyAction.action(for: event, isResultsFirstResponder: window?.firstResponder === self),
           onResultKey?(action) == true { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        selectionModifiers = event.modifierFlags
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

    func clear() {
        identity = nil; textField?.stringValue = ""; imageView?.image = nil
        view.toolTip = nil; view.setAccessibilityLabel(nil)
    }

    override var isSelected: Bool {
        didSet { view.layer?.backgroundColor = (isSelected ? NSColor.selectedContentBackgroundColor.withAlphaComponent(0.25) : .clear).cgColor }
    }
}
