import AppKit
import IndexCore

extension ResultsTable.Coordinator {
    var rowCount: Int { parent.resultList?.count ?? parent.rows.count }

    func record(at row: Int) -> FileRecord? {
        guard row >= 0, row < rowCount else { return nil }
        guard let list = parent.resultList else { return parent.rows[row] }
        if let cached = rowCache[row] { return cached }
        guard let record = list.record(at: row) else { prepareOrder(list); return nil }
        if rowCache.count >= 512 { rowCache.removeAll(keepingCapacity: true) }
        rowCache[row] = record
        return record
    }

    func observe(_ clip: NSClipView) {
        clip.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(visibleRowsChanged(_:)),
                                               name: NSView.boundsDidChangeNotification, object: clip)
    }

    @objc private func visibleRowsChanged(_ notification: Notification) {
        // Start ordering while the already sorted first rows still cover scrolling.
        if visibleRowIndexes().first ?? 0 > 0, let list = parent.resultList { prepareOrder(list) }
        prepareHighlights()
    }

    func stop() {
        if let list = parent.resultList {
            let callback = parent.onOrdering
            Task { callback?(list.id, false) }
        }
        orderingTask?.cancel(); selectionTask?.cancel(); highlightTask?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    func visibleRowIndexes() -> IndexSet {
        guard let table else { return [] }
        let visible = table.rows(in: table.visibleRect)
        guard visible.location != NSNotFound else { return [] }
        let start = max(0, visible.location), end = min(rowCount, NSMaxRange(visible))
        return start < end ? IndexSet(integersIn: start..<end) : []
    }

    func visibleAnchor() -> (FileRecord, CGFloat)? {
        guard let table, let row = visibleRowIndexes().first, let record = record(at: row) else { return nil }
        return (record, table.visibleRect.minY - table.rect(ofRow: row).minY)
    }

    func initialSelectionIndexes(_ records: [FileRecord]) -> IndexSet {
        let identities = Set(records.map(SelectionIdentity.init))
        let initial = parent.rows.indices.filter { identities.contains(SelectionIdentity(parent.rows[$0])) }
        let cached = rowCache.compactMap { row, record in identities.contains(SelectionIdentity(record)) ? row : nil }
        return IndexSet(initial + cached)
    }

    func restoreVirtualSelection(_ records: [FileRecord], anchor: (FileRecord, CGFloat)?, resetScroll: Bool) {
        selectionTask?.cancel()
        if resetScroll { table?.enclosingScrollView?.contentView.scroll(to: .zero) }
        guard let list = parent.resultList, !records.isEmpty || anchor != nil else { return }
        let knownSelection = initialSelectionIndexes(records)
        let knownAnchor = anchor.flatMap { initialSelectionIndexes([$0.0]).first }
        if knownSelection.count == records.count, anchor == nil || knownAnchor != nil {
            restoreAnchor(anchor, row: knownAnchor)
            return
        }
        let selectionRows = table?.selectedRowIndexes
        let scrollOrigin = table?.enclosingScrollView?.contentView.bounds.origin
        selectionTask = Task { [weak self] in
            let rows = await list.indexes(of: records)
            let anchorRows = await list.indexes(of: anchor.map { [$0.0] } ?? [])
            guard !Task.isCancelled, let self, self.parent.resultList === list else { return }
            if !records.isEmpty, self.table?.selectedRowIndexes == selectionRows {
                self.suppressSelectionCallback = true
                self.table?.selectRowIndexes(IndexSet(rows), byExtendingSelection: false)
                self.suppressSelectionCallback = false
            }
            if self.table?.enclosingScrollView?.contentView.bounds.origin == scrollOrigin {
                self.restoreAnchor(anchor, row: anchorRows.first)
            }
        }
    }

    private func restoreAnchor(_ anchor: (FileRecord, CGFloat)?, row: Int?) {
        guard let anchor, let row, let table, let scroll = table.enclosingScrollView else { return }
        let point = NSPoint(x: scroll.contentView.bounds.minX, y: table.rect(ofRow: row).minY + anchor.1)
        guard point != scroll.contentView.bounds.origin else { return }
        scroll.contentView.scroll(to: point)
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    func prepareOrder(_ list: SearchResultList) {
        guard orderingTask == nil, !list.isPrepared else { return }
        orderingTask = Task { [weak self] in
            self?.parent.onOrdering?(list.id, true)
            async let complete = list.prepare()
            if await list.prepareTail(), let self, self.parent.resultList === list, let table = self.table, !Task.isCancelled {
                table.reloadData(forRowIndexes: self.visibleRowIndexes(), columnIndexes: IndexSet(integersIn: 0..<table.tableColumns.count))
                self.prepareHighlights()
            }
            let ready = await complete
            guard !Task.isCancelled, let self, self.parent.resultList === list else { return }
            self.orderingTask = nil
            self.parent.onOrdering?(list.id, false)
            guard ready, let table = self.table else { return }
            table.reloadData(forRowIndexes: self.visibleRowIndexes(), columnIndexes: IndexSet(integersIn: 0..<table.tableColumns.count))
            self.prepareHighlights()
            self.tableViewSelectionDidChange(Notification(name: NSTableView.selectionDidChangeNotification, object: table))
        }
    }
}
