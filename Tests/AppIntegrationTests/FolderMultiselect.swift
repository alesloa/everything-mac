import AppKit
import SwiftUI
import IndexCore

@main struct FolderMultiselectTests {
    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(.regular)
        Task { @MainActor in
            do {
                try await run()
                print("PASS: native Shift/Command folder selection, keyboard ranges, search-only exclusions, pinned context paths, Unicode/offline restores and persistent expansion")
                exit(EXIT_SUCCESS)
            } catch {
                print("FAIL: \(error.localizedDescription)")
                exit(EXIT_FAILURE)
            }
        }
        NSApplication.shared.run()
    }

    @MainActor private static func run() async throws {
        let suite = "EverythingMac.FolderMultiselect.\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            preferences.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let fixture = makeFixture()
        let index = IndexActor(preferencesSuiteName: suite, cacheURL: directory.appendingPathComponent("index.idx"),
                               diskScanner: { _, _, _ in fixture }, networkMounts: { [] })
        try require(await index.rescanAll(), "Fixture publication failed")
        let model = AppModel(index: index, preferences: preferences)
        model.workspace.activate(defaultState: SearchWorkspaceState())
        model.query = "item.txt"
        model.searchFilters = SearchFilters(types: [.files])
        model.sortKey = .name
        model.setFolderSidebarVisible(true)
        await model.runSearch()
        model.folderDetails.refresh()
        print("CHECK: initial search; matches=\(model.totalMatches ?? -1), folders ready=\(model.folderDetails.snapshot != nil)")
        try await waitUntil { model.folderDetails.snapshot != nil && model.totalMatches == 7 }
        let view = NSHostingView(rootView: ContentView().environmentObject(model))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1050, height: 650),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        defer { window.close() }
        try await settle(view)
        window.makeKey()
        var outline = try findOutline(view)
        try require(outline.allowsMultipleSelection, "Native outline does not support multiple selection")
        guard let root = outline.item(atRow: 0) as? FolderOutlineItem else { throw failure("Root folder missing") }
        outline.expandItem(root)
        try await settle(view)

        try await click("/Applications", flags: [], outline: outline, model: model, view: view)
        try await matches(model, count: 1)
        try await click("/Library", flags: [.shift], outline: outline, model: model, view: view)
        try await matches(model, count: 4)
        let rangedBytes = Set(model.folderSearchScope?.included.map { Array($0.path.utf8) } ?? [])
        try require(rangedBytes == [Array("/Applications".utf8), Array("/Library".utf8),
            Array("/caf\u{E9}".utf8), Array("/cafe\u{301}".utf8)], "Shift-click did not select the complete native row range")
        try await click("/Users", flags: [.command], outline: outline, model: model, view: view)
        try await matches(model, count: 5)
        try require(model.folderSearchScope?.included.count == 5 && paths(model).contains("/Users"),
                    "Command-click did not add an individual folder")
        try await click("/Library", flags: [.command], outline: outline, model: model, view: view)
        try await matches(model, count: 4)
        try require(model.folderSearchScope?.included.count == 4 && !paths(model).contains("/Library")
                    && paths(model).contains("/Users"), "Command-click did not remove an individual folder")
        try await click("/Library", flags: [], outline: outline, model: model, view: view)
        window.makeFirstResponder(outline)
        guard let down = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.shift],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, characters: "\u{F701}", charactersIgnoringModifiers: "\u{F701}", isARepeat: false, keyCode: 125)
        else { throw failure("Keyboard event unavailable") }
        outline.keyDown(with: down)
        try await settle(view)
        try await matches(model, count: 2)
        try require(outline.selectedRowIndexes == IndexSet(integersIn: 4..<6)
                    && model.folderSearchScope?.included.count == 2,
                    "Shift-down did not extend the native keyboard selection")
        try require(model.query == "item.txt" && model.searchFilters.selectedTypes == [.files],
                    "Selecting folder ranges changed other filters")
        try await capture(window, path: "/tmp/everything-multi-folder-selected.png")

        // Start unrestricted and right-click an unselected folder. Constructing
        // its native menu must not select that folder or start a scoped search.
        model.setFolderSearchScope(nil)
        try await settle(view)
        try await matches(model, count: 7)
        let volumesMenu = try contextMenu("/Volumes", outline: outline)
        try require(model.folderSearchScope == nil && outline.selectedRowIndexes.isEmpty,
                    "Right-click changed an unrestricted search before its action")
        try invoke(volumesMenu, title: "Exclude from This Search")
        try await settle(view)
        try await matches(model, count: 5)
        try require(model.folderSearchScope?.included.isEmpty == true
                    && model.folderSearchScope?.excluded.map(\.path) == ["/Volumes"],
                    "Exclusion did not keep all other indexed folders")
        try await capture(window, path: "/tmp/everything-multi-folder-exclude-volumes.png")
        let includeMenu = try contextMenu("/Volumes", outline: outline)
        try invoke(includeMenu, title: "Include in This Search")
        try await settle(view)
        try await matches(model, count: 7)
        try require(model.folderSearchScope == nil, "Include did not undo an unrestricted-search exclusion")

        model.query = "branch.txt"
        model.setFolderSearchScope(FolderSearchScope(excluded: [FolderScope(path: "/Users")]))
        try await settle(view)
        try await matches(model, count: 0)
        if let users = outline.item(atRow: row("/Users", outline: outline)) { outline.expandItem(users) }
        let childMenu = try contextMenu("/Users/Ale", outline: outline)
        guard let childInclude = childMenu.items.first(where: { $0.title == "Include in This Search" }) else {
            throw failure("Excluded child menu action missing")
        }
        try require(!childInclude.isEnabled && childInclude.toolTip?.contains("/Users") == true,
                    "Including a child under an excluded parent did not explain its blocking ancestor")
        let excludedUsers = model.folderSearchScope
        try invoke(childMenu, title: "Include in This Search")
        try await settle(view)
        try require(model.folderSearchScope == excludedUsers && model.totalMatches == 0,
                    "A direct or stale child Include action silently widened the excluded parent and siblings")
        try invoke(contextMenu("/Users", outline: outline), title: "Include in This Search")
        try await settle(view)
        try await matches(model, count: 2)
        try require(model.folderSearchScope == nil, "Explicitly including the excluded parent did not undo its exclusion")
        model.query = "item.txt"
        await model.runSearch()

        // Context paths survive a publication that assigns the old Volumes ID
        // to an unrelated folder while tracking is in progress.
        let pinned = try contextMenu("/Volumes", outline: outline)
        let snapshotID = model.folderDetails.snapshot?.snapshotID
        index.searchIndex.publish(makeFixture(reordered: true))
        model.folderDetails.refresh()
        try await waitUntil { model.folderDetails.snapshot?.snapshotID != snapshotID }
        try await settle(view)
        try invoke(pinned, title: "Exclude from This Search")
        try await settle(view)
        try await matches(model, count: 5)
        try require(model.folderSearchScope?.excluded.map(\.path) == ["/Volumes"],
                    "A pinned context action redirected to a reused directory ID")

        // Saved byte-distinct names and absent/offline roots stay selected.
        let composed = "/caf\u{E9}", decomposed = "/cafe\u{301}"
        model.setFolderSearchScope(FolderSearchScope(included: [FolderScope(path: composed),
            FolderScope(path: decomposed), FolderScope(path: "/Offline")], excluded: [FolderScope(path: "/Volumes")]))
        try await settle(view)
        try await matches(model, count: 2)
        outline = try findOutline(view)
        let selectedBytes = Set(outline.selectedRowIndexes.compactMap {
            (outline.item(atRow: $0) as? FolderOutlineItem).map { Array($0.record.path.utf8) }
        })
        try require(selectedBytes == [Array(composed.utf8), Array(decomposed.utf8)],
                    "Programmatic restore merged byte-distinct folder names")
        let before = model.folderSearchScope
        let beforeSnapshot = model.resultSnapshotID
        guard let toggle = descendants(view).compactMap({ $0 as? NSButton }).first(where: {
            $0.identifier?.rawValue == "folder-sidebar-toggle"
        }) else { throw failure("Permanent sidebar toggle missing") }
        toggle.performClick(nil)
        try await settle(view)
        try require(!model.folderSidebarVisible && model.folderSearchScope == before
                    && model.resultSnapshotID == beforeSnapshot && model.totalMatches == 2,
                    "Collapsing reset multi-folder restrictions or restarted their search")
        try require(descendants(view).contains(where: {
            ($0 as? NSScrollView)?.documentView is NSOutlineView
        }) == false, "Collapsed sidebar remained visible")
        try await capture(window, path: "/tmp/everything-multi-folder-collapsed.png")
        toggle.performClick(nil)
        try await settle(view)
        outline = try findOutline(view)
        try require(outline.numberOfRows > 1 && model.folderSearchScope == before,
                    "Reopening lost the expanded tree or selected folders")
        try await click("/Users", flags: [.command], outline: outline, model: model, view: view)
        try await matches(model, count: 3)
        try require(paths(model).contains("/Offline"), "Extended selection discarded an absent selected root")

        model.setFolderSearchScope(FolderSearchScope(included: [FolderScope(path: "/Volumes/Code")]))
        try await settle(view)
        try await matches(model, count: 1)
        outline = try findOutline(view)
        try require(row("/Volumes/Code", outline: outline) >= 0,
                    "Restoring a deep selected folder did not reveal its ancestors")
        if let item = outline.item(atRow: row("/Volumes", outline: outline)) {
            outline.collapseItem(item)
            try await settle(view)
            try require(model.folderSearchScope?.included.map(\.path) == ["/Volumes/Code"] && model.totalMatches == 1,
                        "Collapsing a tree branch discarded its hidden selected descendant")
        }
        model.setFolderSearchScope(nil)
        try await settle(view)
        try await matches(model, count: 7)
        try require(model.folderSearchScope == nil, "All Indexed Folders did not clear both selections and exclusions")

        let previousSnapshot = model.folderDetails.snapshot?.snapshotID
        var detached = makeFixture()
        let share = detached.append(name: "/Users/Share", parent: FileStore.noParent,
            size: 0, mtime: 0, isDir: true, volID: 3)
        detached.append(name: "item.txt", parent: share, size: 1, mtime: 0, isDir: false, volID: 3)
        index.searchIndex.publish(detached)
        model.folderDetails.refresh()
        try await waitUntil { model.folderDetails.snapshot?.snapshotID != previousSnapshot }
        model.setFolderSearchScope(FolderSearchScope(included: [FolderScope(path: "/")],
            excluded: [FolderScope(path: "/Users")]))
        try await settle(view)
        try await matches(model, count: 6)
        outline = try findOutline(view)
        let detachedRow = row("/Users/Share", outline: outline)
        guard let detachedCell = outline.view(atColumn: 0, row: detachedRow, makeIfNecessary: true) as? NSTableCellView else {
            throw failure("Detached root cell missing")
        }
        try require(detachedCell.textField?.textColor != .disabledControlTextColor,
                    "Textual /Users prefix incorrectly styled a detached root as excluded")
        try invoke(contextMenu("/Users/Share", outline: outline), title: "Include in This Search")
        try await settle(view)
        try await matches(model, count: 7)
        try require(paths(model) == ["/", "/Users/Share"]
                    && model.folderSearchScope?.excluded.map(\.path) == ["/Users"],
                    "Including a detached root used textual coverage or removed an unrelated exclusion")
        model.setFolderSearchScope(FolderSearchScope(included: [FolderScope(path: "/Offline")]))
        try await settle(view)
        try await matches(model, count: 0)
        model.folderDetails.refresh()
        try await settle(view)
        try require(model.folderSearchScope?.included.map(\.path) == ["/Offline"] && model.totalMatches == 0,
                    "Reloading an unavailable-only scope widened its zero-match search")
    }

    private static func makeFixture(reordered: Bool = false) -> FileStore {
        var store = FileStore()
        let root = store.append(name: "/", parent: FileStore.noParent, size: 0, mtime: 0, isDir: true, volID: 1)
        let names = reordered ? ["Users", "Volumes", "Library", "Applications", "caf\u{E9}", "cafe\u{301}"]
                              : ["Applications", "Library", "Users", "Volumes", "caf\u{E9}", "cafe\u{301}"]
        for name in names {
            let folder = store.append(name: name, parent: root, size: 0, mtime: 0, isDir: true, volID: 1)
            if name == "Volumes" {
                for driveName in ["Code", "Backup"] {
                    let drive = store.append(name: driveName, parent: folder, size: 0, mtime: 0, isDir: true, volID: 2)
                    store.append(name: "item.txt", parent: drive, size: 1, mtime: 0, isDir: false, volID: 2)
                }
            } else {
                store.append(name: "item.txt", parent: folder, size: 1, mtime: 0, isDir: false, volID: 1)
                if name == "Users" {
                    for childName in ["Ale", "Other"] {
                        let child = store.append(name: childName, parent: folder, size: 0, mtime: 0, isDir: true, volID: 1)
                        store.append(name: "branch.txt", parent: child, size: 1, mtime: 0, isDir: false, volID: 1)
                    }
                }
            }
        }
        return store
    }

    @MainActor private static func click(_ path: String, flags: NSEvent.ModifierFlags,
                                         outline: FolderOutlineTable, model: AppModel, view: NSView) async throws {
        let selectedRow = row(path, outline: outline)
        try require(selectedRow >= 0, "Folder row missing: \(path)")
        outline.scrollRowToVisible(selectedRow)
        let rect = outline.rect(ofRow: selectedRow)
        let point = outline.convert(NSPoint(x: min(110, rect.maxX - 8), y: rect.midY), to: nil)
        guard let window = outline.window,
              let down = mouse(.leftMouseDown, point: point, flags: flags, window: window),
              let up = mouse(.leftMouseUp, point: point, flags: flags, window: window)
        else { throw failure("Native mouse event unavailable") }
        // mouseDown tracks through AppKit's event queue, including mouseUp.
        NSApplication.shared.postEvent(up, atStart: true)
        NSApplication.shared.sendEvent(down)
        if let release = NSApplication.shared.nextEvent(matching: .leftMouseUp, until: Date(), inMode: .default, dequeue: true) {
            NSApplication.shared.sendEvent(release)
        }
        print("CLICK: \(path); row=\(selectedRow), table=\(outline.frame), selected=\(outline.selectedRowIndexes)")
        try await settle(view)
    }

    @MainActor private static func contextMenu(_ path: String, outline: FolderOutlineTable) throws -> NSMenu {
        let selectedRow = row(path, outline: outline)
        try require(selectedRow >= 0, "Context folder row missing: \(path)")
        outline.scrollRowToVisible(selectedRow)
        let point = outline.convert(NSPoint(x: 110, y: outline.rect(ofRow: selectedRow).midY), to: nil)
        guard let window = outline.window,
              let event = mouse(.rightMouseDown, point: point, flags: [], window: window),
              let menu = outline.menu(for: event) else { throw failure("Native folder context menu missing") }
        return menu
    }

    @MainActor private static func invoke(_ menu: NSMenu, title: String) throws {
        guard let item = menu.items.first(where: { $0.title == title }), let action = item.action else {
            throw failure("Folder action missing: \(title)")
        }
        try require(NSApplication.shared.sendAction(action, to: item.target, from: item), "Native folder action failed")
    }

    @MainActor private static func mouse(_ type: NSEvent.EventType, point: NSPoint,
        flags: NSEvent.ModifierFlags, window: NSWindow) -> NSEvent? {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: flags,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)
    }

    @MainActor private static func row(_ path: String, outline: NSOutlineView) -> Int {
        (0..<outline.numberOfRows).first { row in
            guard let item = outline.item(atRow: row) as? FolderOutlineItem else { return false }
            return item.record.path.utf8.elementsEqual(path.utf8)
        } ?? -1
    }
    @MainActor private static func paths(_ model: AppModel) -> Set<String> {
        Set(model.folderSearchScope?.included.map(\.path) ?? [])
    }
    @MainActor private static func findOutline(_ view: NSView) throws -> FolderOutlineTable {
        guard let outline = descendants(view).compactMap({ $0 as? FolderOutlineTable }).first else {
            throw failure("Native folder outline missing")
        }
        return outline
    }
    @MainActor private static func descendants(_ root: NSView) -> [NSView] {
        var pending = [root], result: [NSView] = []
        while let view = pending.popLast() { result.append(view); pending += view.subviews }
        return result
    }
    @MainActor private static func matches(_ model: AppModel, count: Int) async throws {
        await model.runSearch()
        print("CHECK: expected \(count), received \(model.totalMatches ?? -1); included=\(model.folderSearchScope?.included.map(\.path) ?? []), excluded=\(model.folderSearchScope?.excluded.map(\.path) ?? [])")
        try await waitUntil { model.totalMatches == count }
    }
    @MainActor private static func settle(_ view: NSView) async throws {
        try await Task.sleep(for: .milliseconds(120))
        view.layoutSubtreeIfNeeded()
    }
    @MainActor private static func capture(_ window: NSWindow, path: String) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-l", String(window.windowNumber), path]
        try process.run(); process.waitUntilExit()
        try require(process.terminationStatus == 0, "Native sidebar capture failed")
    }
    private static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw failure(message) }
    }
    private static func failure(_ message: String) -> Error {
        NSError(domain: "FolderMultiselectTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
    @MainActor private static func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            try require(ContinuousClock.now < deadline, "Timed out waiting for native folder selection")
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
