import AppKit
import SwiftUI
import IndexCore

// Expansion belongs to the results area, so hiding the panel does not discard it.
@MainActor final class FolderSidebarState: ObservableObject {
    var expandedPaths: Set<[UInt8]> = []
}

@MainActor final class FolderOutlineItem: NSObject {
    let record: FileRecord
    var children: [FolderOutlineItem]?
    init(_ record: FileRecord) { self.record = record }
}

@MainActor final class FolderOutlineTable: NSOutlineView {
    var contextMenuProvider: ((NSEvent) -> NSMenu?)?
    var suppressSelection = 0
    var selectionModifiers: NSEvent.ModifierFlags = []
    var isSelectionGesture = false

    override func mouseDown(with event: NSEvent) {
        selectionModifiers = event.modifierFlags
        isSelectionGesture = true
        defer { isSelectionGesture = false }
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        selectionModifiers = event.modifierFlags
        isSelectionGesture = true
        defer { isSelectionGesture = false }
        super.keyDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? { contextMenuProvider?(event) }

    override func rightMouseDown(with event: NSEvent) {
        // AppKit normally selects the clicked row before opening a menu. A menu
        // exclusion must not first restrict an unrestricted search to that row.
        guard let menu = menu(for: event) else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    override func collapseItem(_ item: Any?, collapseChildren: Bool) {
        suppressSelection += 1
        defer { suppressSelection -= 1 }
        super.collapseItem(item, collapseChildren: collapseChildren)
    }

    override func collapseItem(_ item: Any?) {
        suppressSelection += 1
        defer { suppressSelection -= 1 }
        super.collapseItem(item)
    }
}

struct FolderOutlineView: NSViewRepresentable {
    let snapshot: FolderSnapshot?
    let selection: FolderSearchScope?
    let state: FolderSidebarState
    let onSelect: (FolderSearchScope?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = FolderOutlineTable()
        table.identifier = NSUserInterfaceItemIdentifier("folder-outline")
        table.setAccessibilityIdentifier("folder-outline")
        // Source: the owner's requested indexed-folder multiple selection.
        table.setAccessibilityLabel("Indexed folders")
        table.headerView = nil
        table.rowHeight = 25
        table.indentationPerLevel = 15
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.style = .sourceList
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("folder"))
        column.minWidth = 140
        table.addTableColumn(column)
        table.outlineTableColumn = column
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.contextMenuProvider = { [weak coordinator = context.coordinator] event in
            coordinator?.menu(for: event)
        }
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        table.backgroundColor = .clear
        context.coordinator.table = table
        return scroll
    }

    func updateNSView(_ view: NSScrollView, context: Context) { context.coordinator.reload(self) }

    @MainActor final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
        var parent: FolderOutlineView
        weak var table: FolderOutlineTable?
        private var roots: [FolderOutlineItem] = []
        private var nodes: [UInt32: FolderOutlineItem] = [:]
        private var loadedSnapshot: UUID?
        private var loadedRevision: UInt64?
        private var acceptedSelection: FolderSearchScope?
        private var contextPaths: [FolderScope] = []
        private var collapsing = 0

        init(_ parent: FolderOutlineView) { self.parent = parent }

        func reload(_ next: FolderOutlineView) {
            let changedSnapshot = loadedSnapshot != next.snapshot?.snapshotID || loadedRevision != next.snapshot?.revision
            let changedSelection = acceptedSelection != next.selection
            parent = next
            guard let table else { return }
            table.suppressSelection += 1
            defer { table.suppressSelection -= 1 }
            if changedSnapshot {
                loadedSnapshot = next.snapshot?.snapshotID
                loadedRevision = next.snapshot?.revision
                nodes = [:]
                roots = next.snapshot?.roots.compactMap { makeNode($0) } ?? []
                table.reloadData()
                restoreExpansions(roots)
            }
            if changedSnapshot || changedSelection {
                acceptedSelection = next.selection
                // A selected path may be absent while a mounted/offline root is
                // refreshing. Only restore rows; never rewrite the model here.
                let selected = next.selection?.included.compactMap { reveal($0.path) } ?? []
                let indexes = IndexSet(selected.compactMap { item in
                    let row = table.row(forItem: item)
                    return row >= 0 ? row : nil
                })
                table.selectRowIndexes(indexes, byExtendingSelection: false)
                let visible = IndexSet(integersIn: 0..<table.numberOfRows)
                table.reloadData(forRowIndexes: visible, columnIndexes: IndexSet(integer: 0))
            }
        }

        private func makeNode(_ id: UInt32) -> FolderOutlineItem? {
            if let existing = nodes[id] { return existing }
            guard let record = parent.snapshot?.record(for: id) else { return nil }
            let node = FolderOutlineItem(record)
            nodes[id] = node
            return node
        }

        private func children(_ node: FolderOutlineItem) -> [FolderOutlineItem] {
            if let children = node.children { return children }
            let children = parent.snapshot?.children(of: node.record.id).compactMap { makeNode($0) } ?? []
            node.children = children
            return children
        }

        private func restoreExpansions(_ items: [FolderOutlineItem]) {
            guard let table else { return }
            for item in items where parent.state.expandedPaths.contains(Array(item.record.path.utf8)) {
                table.expandItem(item)
                restoreExpansions(children(item))
            }
        }

        // Find by literal path bytes and walk only its ancestors. Swift String
        // equality normalizes Unicode; index paths intentionally do not.
        private func pathChain(_ path: String) -> [FolderOutlineItem]? {
            let bytes = Array(path.utf8)
            for root in roots {
                guard Self.covers(root.record.path, path) else { continue }
                var chain = [root], item = root
                while Array(item.record.path.utf8) != bytes {
                    guard let child = children(item).first(where: { Self.covers($0.record.path, path) }) else { break }
                    item = child; chain.append(child)
                }
                if Array(item.record.path.utf8) == bytes { return chain }
            }
            return nil
        }

        private func reveal(_ path: String) -> FolderOutlineItem? {
            guard let chain = pathChain(path) else { return nil }
            for ancestor in chain.dropLast() { table?.expandItem(ancestor) }
            return chain.last
        }

        private static func covers(_ root: String, _ path: String) -> Bool {
            let prefix = Array(root.utf8), target = Array(path.utf8)
            return prefix == target || (target.starts(with: prefix)
                && (prefix.last == 47 || (target.count > prefix.count && target[prefix.count] == 47)))
        }

        private func branchContains(_ path: String, record: FileRecord) -> Bool {
            let bytes = Array(path.utf8)
            var current: FileRecord? = record
            var visited = Set<UInt32>()
            while let record = current, visited.insert(record.id).inserted {
                if record.path.utf8.elementsEqual(bytes) { return true }
                current = parent.snapshot?.record(for: record.parent)
            }
            return false
        }

        private func branchContains(_ root: String, path: String) -> Bool {
            guard let record = pathChain(path)?.last?.record else {
                // An unavailable saved path has no verifiable ancestry. Only an
                // exact restriction can be undone without widening its siblings.
                return root.utf8.elementsEqual(path.utf8)
            }
            return branchContains(root, record: record)
        }

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            (item as? FolderOutlineItem).map { children($0).count } ?? roots.count
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            (item as? FolderOutlineItem).map { children($0)[index] } ?? roots[index]
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            guard let item = item as? FolderOutlineItem else { return false }
            return parent.snapshot?.children(of: item.record.id).isEmpty == false
        }

        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let item = item as? FolderOutlineItem else { return nil }
            let cell = NSTableCellView()
            let icon = NSImageView()
            icon.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
            let label = NSTextField(labelWithString: item.record.name.isEmpty ? item.record.path : item.record.name)
            label.lineBreakMode = .byTruncatingTail
            let excluded = parent.selection?.excluded.contains { branchContains($0.path, record: item.record) } == true
            label.textColor = excluded ? .disabledControlTextColor : .labelColor
            icon.contentTintColor = excluded ? .disabledControlTextColor : .secondaryLabelColor
            cell.imageView = icon; cell.textField = label
            cell.toolTip = item.record.path
            for view in [icon, label] { view.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(view) }
            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: 16), icon.heightAnchor.constraint(equalToConstant: 16),
                label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
            return cell
        }

        func outlineViewItemDidExpand(_ notification: Notification) {
            guard let item = notification.userInfo?["NSObject"] as? FolderOutlineItem else { return }
            parent.state.expandedPaths.insert(Array(item.record.path.utf8))
        }

        func outlineViewItemWillCollapse(_ notification: Notification) { collapsing += 1 }

        func outlineViewItemDidCollapse(_ notification: Notification) {
            collapsing = max(0, collapsing - 1)
            guard let item = notification.userInfo?["NSObject"] as? FolderOutlineItem else { return }
            parent.state.expandedPaths.remove(Array(item.record.path.utf8))
        }

        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard let table, table.suppressSelection == 0, collapsing == 0 else { return }
            var included = table.selectedRowIndexes.compactMap { row in
                (table.item(atRow: row) as? FolderOutlineItem).map { FolderScope(record: $0.record) }
            }
            let extending = table.selectionModifiers.contains(.command) || table.selectionModifiers.contains(.shift)
            if extending || !table.isSelectionGesture {
                // Hidden selected descendants and unavailable roots remain part
                // of an extended selection, even though AppKit has no row for them.
                included += parent.selection?.included.filter {
                    guard let node = pathChain($0.path)?.last else { return true }
                    return table.row(forItem: node) < 0
                } ?? []
            }
            let next = FolderSearchScope(included: included, excluded: parent.selection?.excluded ?? [])
            acceptedSelection = next.included.isEmpty && next.excluded.isEmpty ? nil : next
            parent.onSelect(acceptedSelection)
        }

        func menu(for event: NSEvent) -> NSMenu? {
            guard let table else { return nil }
            let row = table.row(at: table.convert(event.locationInWindow, from: nil))
            guard row >= 0 else { return nil }
            let indexes = table.selectedRowIndexes.contains(row) ? table.selectedRowIndexes : IndexSet(integer: row)
            // Values are copied from the accepted immutable snapshot before menu
            // tracking. A rebuild may reuse its IDs while the menu stays open.
            contextPaths = indexes.compactMap { row in
                (table.item(atRow: row) as? FolderOutlineItem).map { FolderScope(path: $0.record.path) }
            }
            guard !contextPaths.isEmpty else { return nil }
            let menu = NSMenu()
            menu.autoenablesItems = false
            // Source: the owner's requested search-only folder exclusions.
            for (title, selector) in [("Exclude from This Search", #selector(excludeContext)),
                                      ("Include in This Search", #selector(includeContext))] {
                let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
                item.target = self
                if selector == #selector(includeContext) {
                    let blocked = blockingExclusions()
                    item.isEnabled = blocked.isEmpty
                    if !blocked.isEmpty {
                        // Source: these actual excluded ancestor paths from this
                        // tab's model; including a child cannot undo only part of a branch.
                        item.toolTip = "Excluded by " + blocked.map(\.path).joined(separator: ", ")
                            + ". Remove that exclusion first."
                    }
                }
                menu.addItem(item)
            }
            return menu
        }

        @objc func excludeContext() {
            let current = parent.selection
            let next = FolderSearchScope(included: current?.included ?? [],
                                         excluded: (current?.excluded ?? []) + contextPaths)
            parent.onSelect(next)
        }

        @objc func includeContext() {
            // The model may change while the pinned menu remains open.
            guard blockingExclusions().isEmpty else { return }
            var included = parent.selection?.included ?? []
            let excluded = (parent.selection?.excluded ?? []).filter { restriction in
                !contextPaths.contains {
                    branchContains(restriction.path, path: $0.path) || branchContains($0.path, path: restriction.path)
                }
            }
            if !included.isEmpty {
                included += contextPaths.filter { path in !included.contains { branchContains($0.path, path: path.path) } }
            }
            let next = FolderSearchScope(included: included, excluded: excluded)
            parent.onSelect(next.included.isEmpty && next.excluded.isEmpty ? nil : next)
        }

        private func blockingExclusions() -> [FolderScope] {
            (parent.selection?.excluded ?? []).filter { restriction in
                let coversChild = contextPaths.contains {
                    !$0.path.utf8.elementsEqual(restriction.path.utf8)
                        && branchContains(restriction.path, path: $0.path)
                }
                let broaderTargetSelected = contextPaths.contains { branchContains($0.path, path: restriction.path) }
                return coversChild && !broaderTargetSelected
            }
        }
    }
}
