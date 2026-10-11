import SwiftUI
import AppKit
import IndexCore
import UniformTypeIdentifiers

struct ResultsTable: NSViewRepresentable {
    var rows: [FileRecord]
    var onSort: (QueryEngine.SortKey, Bool) -> Void
    var onSelect: (FileRecord?) -> Void
    var onActivate: (FileRecord) -> Void
    var onSelection: (([FileRecord]) -> Void)? = nil
    var onPreview: (([FileRecord]) -> Void)? = nil
    var selectedRecords: [FileRecord]? = nil
    var query: Query? = nil
    var folderTotals: FolderSnapshot? = nil
    var sortKey: QueryEngine.SortKey? = nil
    var ascending = true
    var showIndexedTotals: Bool? = nil
    var onIndexedTotalsVisibilityChanged: ((Bool) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = ResultsKeyTableView()
        table.onResultKey = context.coordinator.handleResultKey
        context.coordinator.table = table
        context.coordinator.installColumns(in: table)
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.target = context.coordinator
        table.doubleAction = #selector(Coordinator.doubleClicked(_:))
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true
        table.setDraggingSourceOperationMask([.copy, .move, .link], forLocal: false)

        // Right-click context menu — items target the coordinator; coordinator
        // pins the clicked record before tracking starts. The
        // "Open With" submenu is per-file, so it's rebuilt lazily by the coordinator
        // (its menu delegate) when the user hovers it — see menuNeedsUpdate.
        let menu = NSMenu()
        func add(_ title: String, _ sel: Selector) {
            let mi = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            mi.target = context.coordinator
            menu.addItem(mi)
        }
        add("Open", #selector(Coordinator.ctxOpen))
        let openWith = NSMenuItem(title: "Open With", action: nil, keyEquivalent: "")
        let openWithSub = NSMenu(title: "Open With")
        openWithSub.delegate = context.coordinator
        openWith.submenu = openWithSub
        menu.addItem(openWith)
        context.coordinator.openWithMenu = openWithSub
        context.coordinator.contextMenu = menu
        menu.delegate = context.coordinator
        menu.addItem(.separator())
        add("Reveal in Finder", #selector(Coordinator.ctxReveal))
        add("Copy Path", #selector(Coordinator.ctxCopyPath))
        add("Copy Name", #selector(Coordinator.ctxCopyName))
        add("Copy Files", #selector(Coordinator.ctxCopyFiles))
        add("Paste Files…", #selector(Coordinator.ctxPasteFiles))
        add("Copy To…", #selector(Coordinator.ctxCopyTo))
        add("Move To…", #selector(Coordinator.ctxMoveTo))
        add("Rename…", #selector(Coordinator.ctxRename))
        add("Get Info", #selector(Coordinator.ctxGetInfo))
        menu.addItem(.separator())
        add("Move to Trash", #selector(Coordinator.ctxTrash))
        table.menu = menu

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        context.coordinator.table = table
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.reload(self)
    }

    @MainActor final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate, NSMenuItemValidation {
        var parent: ResultsTable
        weak var table: NSTableView?
        weak var openWithMenu: NSMenu?
        weak var contextMenu: NSMenu?
        weak var columnsMenu: NSMenu?
        let columnDefaults: UserDefaults
        var columnLayout: ResultsColumnLayout
        var suppressColumnPersistence = false
        var lastIndexedTotalsVisibility: Bool?
        var highlightTask: Task<Void, Never>?
        var highlightRequest = UUID()
        var highlightPrepared = false
        var highlights: [SelectionIdentity: RecordHighlights] = [:]
        private var contextRecords: [FileRecord] = []
        var suppressSelectionCallback = false
        var suppressSortCallback = false
        init(_ p: ResultsTable, columnDefaults: UserDefaults = .standard) {
            parent = p
            self.columnDefaults = columnDefaults
            columnLayout = ResultsColumnLayout.load(from: columnDefaults)
        }
        deinit { highlightTask?.cancel() }

        func numberOfRows(in tableView: NSTableView) -> Int { parent.rows.count }

        func reload(_ next: ResultsTable) {
            let selected = next.selectedRecords ?? selectedRecords()
            let updateHighlights = parent.query != next.query || !Self.sameRows(parent.rows, next.rows)
            let updateTotalsVisibility = parent.showIndexedTotals != next.showIndexedTotals
            parent = next
            if updateTotalsVisibility { applyIndexedTotalsOverride() }
            applySortIndicators()
            suppressSelectionCallback = true
            defer { suppressSelectionCallback = false }
            table?.reloadData()
            let identities = Set(selected.map { SelectionIdentity($0) })
            let indexes = IndexSet(parent.rows.indices.filter { identities.contains(SelectionIdentity(parent.rows[$0])) })
            // Rebuilds reuse IDs; every selected row must also keep its exact path bytes.
            if indexes.isEmpty { table?.deselectAll(nil) }
            else { table?.selectRowIndexes(indexes, byExtendingSelection: false) }
            if updateHighlights || !highlightPrepared { prepareHighlights() }
        }

        // Report the user's row pick up to the model so the menu bar can act on it.
        // Skipped during programmatic reselection (see updateNSView).
        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !suppressSelectionCallback else { return }
            let records = selectedRecords()
            parent.onSelect(records.first)
            parent.onSelection?(records)
        }

        func selectedRecords() -> [FileRecord] {
            guard let table else { return [] }
            return table.selectedRowIndexes.compactMap { parent.rows.indices.contains($0) ? parent.rows[$0] : nil }
        }

        func handleResultKey(_ action: ResultsKeyAction) -> Bool {
            let records = selectedRecords()
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

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
            guard parent.rows.indices.contains(row) else { return nil }
            return URL(fileURLWithPath: parent.rows[row].path) as NSURL
        }

        func tableView(_ t: NSTableView, viewFor col: NSTableColumn?, row: Int) -> NSView? {
            guard parent.rows.indices.contains(row) else { return nil }
            let rec = parent.rows[row]
            let key = col?.identifier.rawValue
            // Name column carries the file-type icon; everything else is text-only.
            if key == "name" {
                let cell = nameCell(t)
                applyText(rec.name, ranges: highlights[SelectionIdentity(rec)]?.name ?? [], to: cell.textField)
                cell.imageView?.image = FileIcons.icon(ext: Self.ext(rec.name), isDir: rec.isDir)
                return cell
            }
            let cell = textCell(t)
            switch key {
            // Row names, paths, dates, bytes and file counts come from FileRecord
            // or the matching immutable indexed folder snapshot.
            case "path": applyText(rec.path, ranges: highlights[SelectionIdentity(rec)]?.path ?? [], to: cell.textField)
            case "size":
                cell.textField?.stringValue = Self.sizeText(rec.size)
            case "indexedSize":
                let bytes = rec.isDir ? parent.folderTotals?.totals(for: rec)?.bytes : rec.size
                cell.textField?.stringValue = bytes.map(Self.sizeText) ?? ""
            case "fileCount": cell.textField?.stringValue = parent.folderTotals?.totals(for: rec)?.fileCount.formatted() ?? ""
            case "kind": cell.textField?.stringValue = FileIcons.kind(ext: Self.ext(rec.name), isDir: rec.isDir)
            case "mtime": cell.textField?.stringValue = Self.df.string(from: Date(timeIntervalSince1970: TimeInterval(rec.mtime)))
            default: break
            }
            return cell
        }

        private static func ext(_ name: String) -> String { (name as NSString).pathExtension.lowercased() }

        private static func sizeText(_ bytes: UInt64) -> String {
            // FileRecord/cache sizes are unsigned; ByteCountFormatter accepts only
            // Int64. Preserve oversized values instead of trapping or clamping.
            guard let signed = Int64(exactly: bytes) else {
                return "\(bytes) \(UnitInformationStorage.bytes.symbol)"
            }
            return ByteCountFormatter.string(fromByteCount: signed, countStyle: .file)
        }

        // Text-only reusable cell (path / size / kind / date columns).
        @MainActor private func textCell(_ t: NSTableView) -> NSTableCellView {
            let id = NSUserInterfaceItemIdentifier("cell")
            if let c = t.makeView(withIdentifier: id, owner: self) as? NSTableCellView { return c }
            let c = NSTableCellView()
            let tf = NSTextField(labelWithString: "")
            c.textField = tf; c.addSubview(tf)
            tf.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                tf.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 4),
                tf.trailingAnchor.constraint(lessThanOrEqualTo: c.trailingAnchor, constant: -4),
                tf.centerYAnchor.constraint(equalTo: c.centerYAnchor)])
            c.identifier = id
            return c
        }

        // Name cell: 16×16 icon on the left, name text after it.
        @MainActor private func nameCell(_ t: NSTableView) -> NSTableCellView {
            let id = NSUserInterfaceItemIdentifier("namecell")
            if let c = t.makeView(withIdentifier: id, owner: self) as? NSTableCellView { return c }
            let c = NSTableCellView()
            let iv = NSImageView()
            iv.imageScaling = .scaleProportionallyUpOrDown
            let tf = NSTextField(labelWithString: "")
            c.imageView = iv; c.textField = tf
            c.addSubview(iv); c.addSubview(tf)
            iv.translatesAutoresizingMaskIntoConstraints = false
            tf.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                iv.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 4),
                iv.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                iv.widthAnchor.constraint(equalToConstant: 16),
                iv.heightAnchor.constraint(equalToConstant: 16),
                tf.leadingAnchor.constraint(equalTo: iv.trailingAnchor, constant: 4),
                tf.trailingAnchor.constraint(lessThanOrEqualTo: c.trailingAnchor, constant: -4),
                tf.centerYAnchor.constraint(equalTo: c.centerYAnchor)])
            c.identifier = id
            return c
        }

        func tableView(_ t: NSTableView, sortDescriptorsDidChange old: [NSSortDescriptor]) {
            guard !suppressSortCallback else { return }
            guard let d = t.sortDescriptors.first, let k = d.key else { return }
            let key: QueryEngine.SortKey = ["name":.name,"path":.path,"size":.size,"kind":.kind,"mtime":.mtime][k] ?? .name
            parent.onSort(key, d.ascending)
        }

        @objc func doubleClicked(_ sender: NSTableView) {
            let r = sender.clickedRow
            if r >= 0 && r < parent.rows.count { parent.onActivate(parent.rows[r]) }
        }

        // Context-menu handlers use the pinned right-click target.
        func clickedRecord() -> FileRecord? {
            // The main menu captures the file before tracking starts. Live results
            // can reorder while the menu is open; actions keep the clicked path.
            if contextMenu != nil { return contextRecords.first }
            guard let r = table?.clickedRow, r >= 0, r < parent.rows.count else { return nil }
            return parent.rows[r]
        }
        func clickedRecords() -> [FileRecord] {
            if contextMenu != nil { return contextRecords }
            return clickedRecord().map { [$0] } ?? []
        }
        @objc func ctxOpen()     { ResultActions.open(clickedRecords()) }
        @objc func ctxReveal()   { ResultActions.reveal(clickedRecords()) }
        @objc func ctxCopyPath() { ResultActions.copyPath(clickedRecords()) }
        @objc func ctxCopyName() { ResultActions.copyName(clickedRecords()) }
        @objc func ctxTrash()    { ResultActions.trash(clickedRecords()) }
        @objc func ctxCopyFiles() { ResultActions.copyFiles(clickedRecords()) }
        @objc func ctxPasteFiles() { ResultActions.pasteFiles(into: clickedRecords().count == 1 ? clickedRecord() : nil) }
        @objc func ctxCopyTo() { ResultActions.copyTo(clickedRecords()) }
        @objc func ctxMoveTo() { ResultActions.moveTo(clickedRecords()) }
        @objc func ctxRename() { ResultActions.rename(clickedRecords()) }
        @objc func ctxGetInfo() { ResultActions.getInfo(clickedRecords()) }

        func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
            if menuItem.action == #selector(toggleColumn(_:)) {
                guard let key = menuItem.representedObject as? String,
                      let column = table?.tableColumns.first(where: { $0.identifier.rawValue == key }) else { return false }
                return column.isHidden || (table?.tableColumns.filter({ !$0.isHidden }).count ?? 0) > 1
            }
            guard !clickedRecords().isEmpty, !ResultActions.state.isBusy else { return false }
            if menuItem.action == #selector(ctxPasteFiles) { return ResultActions.canPasteFiles }
            return true
        }

        // Notepad Studio is always pinned in the submenu so any file — even one with
        // no associated app — can be opened with it. Resolved by bundle id at runtime
        // so it works wherever the app is installed (nil if not installed).
        private static let pinnedAppBundleID = "io.alesloas.notepad-studio"

        // Rebuild the "Open With" submenu for the right-clicked file just before it
        // shows: every app LaunchServices can open it with (icon + name, default
        // marked), then the pinned editor, then a "Choose Application…" picker — so
        // there's always something to open with. Chosen app rides on representedObject.
        func menuNeedsUpdate(_ menu: NSMenu) {
            if menu === columnsMenu { updateColumnMenu(); return }
            if menu === contextMenu {
                if let row = table?.clickedRow, parent.rows.indices.contains(row) {
                    contextRecords = table?.selectedRowIndexes.contains(row) == true ? selectedRecords() : [parent.rows[row]]
                } else { contextRecords = [] }
                for item in menu.items where item.action != nil {
                    item.isEnabled = !contextRecords.isEmpty && !ResultActions.state.isBusy
                }
                return
            }
            guard menu === openWithMenu else { return }
            menu.removeAllItems()
            guard let rec = clickedRecord() else { return }
            let url = URL(fileURLWithPath: rec.path)
            let ws = NSWorkspace.shared
            var apps = ws.urlsForApplications(toOpen: url)
            let defaultApp = ws.urlForApplication(toOpen: url)

            // Pin Notepad Studio if it isn't already in the associated list.
            if let pinned = ws.urlForApplication(withBundleIdentifier: Self.pinnedAppBundleID),
               !apps.contains(where: { $0.standardizedFileURL == pinned.standardizedFileURL }) {
                apps.append(pinned)
            }

            for app in apps {
                var name = FileManager.default.displayName(atPath: app.path)
                if app.standardizedFileURL == defaultApp?.standardizedFileURL { name += " (default)" }
                let item = NSMenuItem(title: name, action: #selector(ctxOpenWith(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = app
                let icon = ws.icon(forFile: app.path)
                icon.size = NSSize(width: 16, height: 16)
                item.image = icon
                menu.addItem(item)
            }

            menu.addItem(.separator())
            let choose = NSMenuItem(title: "Choose Application…", action: #selector(ctxOpenWithChoose), keyEquivalent: "")
            choose.target = self
            menu.addItem(choose)
        }

        @objc func ctxOpenWith(_ sender: NSMenuItem) {
            guard let app = sender.representedObject as? URL else { return }
            ResultActions.open(clickedRecords(), with: app)
        }

        // Browse for any app to open the file with (Finder's "Open With ▸ Other…").
        // Capture the pinned record before the panel's nested event loop.
        @objc func ctxOpenWithChoose() {
            let records = clickedRecords()
            guard !records.isEmpty else { return }
            let panel = NSOpenPanel()
            panel.title = "Choose Application"
            panel.directoryURL = URL(fileURLWithPath: "/Applications")
            panel.allowedContentTypes = [.application]
            panel.allowsMultipleSelection = false
            panel.canChooseDirectories = false
            if panel.runModal() == .OK, let app = panel.url {
                ResultActions.open(records, with: app)
            }
        }

        static let df: DateFormatter = { let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short; return f }()
    }
}

// Keyboard actions are scoped to the results view as first responder. Field
// editors and search fields keep Space, Return and standard text commands.
enum ResultsKeyAction: Equatable {
    case preview, open, copy, paste, undo

    static func action(for event: NSEvent, isResultsFirstResponder: Bool) -> Self? {
        guard isResultsFirstResponder, event.type == .keyDown else { return nil }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if modifiers.isEmpty {
            if event.keyCode == 49 { return .preview }
            if event.keyCode == 36 || event.keyCode == 76 { return .open }
        }
        if modifiers == .command {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "c": return .copy
            case "v": return .paste
            case "z": return .undo
            default: break
            }
        }
        return nil
    }
}

@MainActor final class ResultsKeyTableView: NSTableView {
    var onResultKey: ((ResultsKeyAction) -> Bool)?

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
