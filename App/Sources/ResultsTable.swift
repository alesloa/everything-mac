import SwiftUI
import AppKit
import IndexCore
import UniformTypeIdentifiers

struct ResultsTable: NSViewRepresentable {
    var rows: [FileRecord]
    var onSort: (QueryEngine.SortKey, Bool) -> Void
    var onSelect: (FileRecord?) -> Void
    var onActivate: (FileRecord) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = NSTableView()
        for (key, title, width) in [("name","Name",260),("path","Path",380),("size","Size",90),("kind","Kind",130),("mtime","Date Modified",160)] {
            let col = NSTableColumn(identifier: .init(key))
            col.title = title; col.width = CGFloat(width)
            col.sortDescriptorPrototype = NSSortDescriptor(key: key, ascending: true)
            table.addTableColumn(col)
        }
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.target = context.coordinator
        table.doubleAction = #selector(Coordinator.doubleClicked(_:))
        table.usesAlternatingRowBackgroundColors = true

        // Right-click context menu — items target the coordinator; coordinator
        // resolves the clicked row at action time via table.clickedRow. The
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
        menu.addItem(.separator())
        add("Reveal in Finder", #selector(Coordinator.ctxReveal))
        add("Copy Path", #selector(Coordinator.ctxCopyPath))
        add("Copy Name", #selector(Coordinator.ctxCopyName))
        menu.addItem(.separator())
        add("Move to Trash", #selector(Coordinator.ctxTrash))
        table.menu = menu

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        context.coordinator.table = table
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        let coord = context.coordinator
        let table = nsView.documentView as? NSTableView
        // Pin selection to the FILE, not the row index. A live-index refresh replaces
        // `results` ~constantly (FSEvents fires for any file change anywhere), and a
        // plain reloadData drops or visually shifts the highlight out from under the
        // user's click. Capture the selected record's stable store id from the OLD
        // rows, reload, then re-select that same id in the NEW rows (gone only if the
        // file dropped out of the result window).
        let selectedID: UInt32? = {
            guard let t = table, t.selectedRow >= 0, t.selectedRow < coord.parent.rows.count else { return nil }
            return coord.parent.rows[t.selectedRow].id
        }()
        coord.parent = self
        // Suppress the selection callback across reload+reselect: reloadData clears the
        // selection (a spurious "nothing selected") and the reselect below re-sets the
        // SAME file — neither is a user action, and firing onSelect here would mutate
        // published model state mid-view-update. Genuine clicks happen outside this.
        coord.suppressSelectionCallback = true
        defer { coord.suppressSelectionCallback = false }
        table?.reloadData()
        if let id = selectedID, let t = table,
           let row = rows.firstIndex(where: { $0.id == id }) {
            t.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        var parent: ResultsTable
        weak var table: NSTableView?
        weak var openWithMenu: NSMenu?
        var suppressSelectionCallback = false
        init(_ p: ResultsTable) { parent = p }

        func numberOfRows(in tableView: NSTableView) -> Int { parent.rows.count }

        // Report the user's row pick up to the model so the menu bar can act on it.
        // Skipped during programmatic reselection (see updateNSView).
        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !suppressSelectionCallback, let t = table else { return }
            let r = t.selectedRow
            parent.onSelect(r >= 0 && r < parent.rows.count ? parent.rows[r] : nil)
        }

        func tableView(_ t: NSTableView, viewFor col: NSTableColumn?, row: Int) -> NSView? {
            let rec = parent.rows[row]
            let key = col?.identifier.rawValue
            // Name column carries the file-type icon; everything else is text-only.
            if key == "name" {
                let cell = nameCell(t)
                cell.textField?.stringValue = rec.name
                cell.imageView?.image = FileIcons.icon(ext: Self.ext(rec.name), isDir: rec.isDir)
                return cell
            }
            let cell = textCell(t)
            switch key {
            case "path": cell.textField?.stringValue = rec.path
            case "size": cell.textField?.stringValue = rec.isDir ? "--" : ByteCountFormatter.string(fromByteCount: Int64(rec.size), countStyle: .file)
            case "kind": cell.textField?.stringValue = FileIcons.kind(ext: Self.ext(rec.name), isDir: rec.isDir)
            case "mtime": cell.textField?.stringValue = Self.df.string(from: Date(timeIntervalSince1970: TimeInterval(rec.mtime)))
            default: break
            }
            return cell
        }

        private static func ext(_ name: String) -> String { (name as NSString).pathExtension.lowercased() }

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
            IndexActor.dlog("sortDidChange descs=\(t.sortDescriptors.map { "\($0.key ?? "nil"):\($0.ascending)" }) old=\(old.map { $0.key ?? "nil" })")
            guard let d = t.sortDescriptors.first, let k = d.key else { IndexActor.dlog("  no first descriptor -> ignored"); return }
            let key: QueryEngine.SortKey = ["name":.name,"path":.path,"size":.size,"kind":.kind,"mtime":.mtime][k] ?? .name
            IndexActor.dlog("  -> onSort key=\(k) asc=\(d.ascending)")
            parent.onSort(key, d.ascending)
        }

        @objc func doubleClicked(_ sender: NSTableView) {
            let r = sender.clickedRow
            if r >= 0 && r < parent.rows.count { parent.onActivate(parent.rows[r]) }
        }

        // Context-menu handlers — resolve the right-clicked row, then delegate to ResultActions.
        private func clickedRecord() -> FileRecord? {
            guard let r = table?.clickedRow, r >= 0, r < parent.rows.count else { return nil }
            return parent.rows[r]
        }
        @objc func ctxOpen()     { if let r = clickedRecord() { ResultActions.open(r) } }
        @objc func ctxReveal()   { if let r = clickedRecord() { ResultActions.reveal(r) } }
        @objc func ctxCopyPath() { if let r = clickedRecord() { ResultActions.copyPath(r) } }
        @objc func ctxCopyName() { if let r = clickedRecord() { ResultActions.copyName(r) } }
        @objc func ctxTrash()    { if let r = clickedRecord() { ResultActions.trash(r) } }

        // Notepad Studio is always pinned in the submenu so any file — even one with
        // no associated app — can be opened with it. Resolved by bundle id at runtime
        // so it works wherever the app is installed (nil if not installed).
        private static let pinnedAppBundleID = "io.alesloas.notepad-studio"

        // Rebuild the "Open With" submenu for the right-clicked file just before it
        // shows: every app LaunchServices can open it with (icon + name, default
        // marked), then the pinned editor, then a "Choose Application…" picker — so
        // there's always something to open with. Chosen app rides on representedObject.
        func menuNeedsUpdate(_ menu: NSMenu) {
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
            guard let r = clickedRecord(), let app = sender.representedObject as? URL else { return }
            ResultActions.open(r, with: app)
        }

        // Browse for any app to open the file with (Finder's "Open With ▸ Other…").
        // Capture the record first — runModal blocks, but clickedRow stays valid.
        @objc func ctxOpenWithChoose() {
            guard let r = clickedRecord() else { return }
            let panel = NSOpenPanel()
            panel.title = "Choose Application"
            panel.directoryURL = URL(fileURLWithPath: "/Applications")
            panel.allowedContentTypes = [.application]
            panel.allowsMultipleSelection = false
            panel.canChooseDirectories = false
            if panel.runModal() == .OK, let app = panel.url {
                ResultActions.open(r, with: app)
            }
        }

        static let df: DateFormatter = { let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short; return f }()
    }
}
