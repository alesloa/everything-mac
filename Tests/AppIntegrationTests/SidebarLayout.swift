import AppKit
import SwiftUI
import IndexCore

private actor FolderPreparationGate {
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        released = true
        let pending = waiters; waiters = []
        for waiter in pending { waiter.resume() }
    }
}

@main struct SidebarLayoutTests {
    @MainActor static func main() {
        Task { @MainActor in
            do {
                try await run()
                print("PASS: sidebar loading/toggles, scoped tables, empty results, thumbnails, previews and resized windows keep full-height results")
                exit(EXIT_SUCCESS)
            } catch {
                print("FAIL: \(error.localizedDescription)")
                exit(EXIT_FAILURE)
            }
        }
        NSApplication.shared.run()
    }

    @MainActor private static func run() async throws {
        let suite = "EverythingMac.SidebarLayout.\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            preferences.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        var store = FileStore()
        let root = store.append(name: "/", parent: FileStore.noParent, size: 0, mtime: 0, isDir: true, volID: 1)
        let volumes = store.append(name: "Volumes", parent: root, size: 0, mtime: 0, isDir: true, volID: 1)
        let drive = store.append(name: "Fixture", parent: volumes, size: 0, mtime: 0, isDir: true, volID: 2)
        store.append(name: "item.txt", parent: drive, size: 1, mtime: 0, isDir: false, volID: 2)
        let fixture = store
        let index = IndexActor(preferencesSuiteName: suite, cacheURL: directory.appendingPathComponent("index.idx"),
                               diskScanner: { _, _, _ in fixture }, networkMounts: { [] })
        try require(await index.rescanAll(), "Fixture publication failed")
        let gate = FolderPreparationGate()
        let model = AppModel(index: index, preferences: preferences)
        model.workspace.activate(defaultState: SearchWorkspaceState())
        model.folderDetails = FolderDetailsModel(index: index.searchIndex, loadSnapshot: { index in
            await gate.wait()
            return await index.folderSnapshot()
        })
        model.query = "item.txt"
        model.setFolderScope(FolderScope(path: "/Volumes/Fixture"))
        try await waitUntil { model.totalMatches == 1 }
        let view = NSHostingView(rootView: ContentView().environmentObject(model).frame(minWidth: 800, minHeight: 500))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1296, height: 780),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.setContentSize(NSSize(width: 1296, height: 780))
        window.orderFront(nil)
        defer { window.close() }
        try await settle(view)
        try require(model.folderDetails.snapshot == nil, "Folder preparation did not remain pending")
        try await capture(window, path: "/tmp/everything-sidebar-loading.png")
        try checkLayout(in: view, thumbnails: false, state: "pending folder details")
        let snapshotID = model.resultSnapshotID
        for _ in 0..<6 {
            guard let toggle = descendants(of: view).compactMap({ $0 as? NSButton }).first(where: {
                $0.identifier?.rawValue == "folder-sidebar-toggle"
            }) else { throw failure("Sidebar toggle disappeared") }
            toggle.performClick(nil)
            try await settle(view)
            try checkLayout(in: view, thumbnails: false, state: "sidebar toggle with pending folder details")
            try require(model.folderScope?.path == "/Volumes/Fixture" && model.totalMatches == 1
                        && model.resultSnapshotID == snapshotID, "Sidebar toggle changed selected drive or results")
        }
        await gate.release()
        model.folderDetails.refresh()
        try await waitUntil { model.folderDetails.snapshot != nil }
        try await settle(view)
        try checkLayout(in: view, thumbnails: false, state: "folder details ready")
        for size in [NSSize(width: 800, height: 500), NSSize(width: 1296, height: 780)] {
            window.setContentSize(size)
            try await settle(view)
            try checkLayout(in: view, thumbnails: false, state: "resized scoped results")
        }
        model.previewVisible = true
        try await settle(view)
        try checkLayout(in: view, thumbnails: false, state: "empty preview panel")
        model.previewVisible = false
        model.thumbnailView = true
        try await settle(view)
        try checkLayout(in: view, thumbnails: true, state: "thumbnail results")
        model.query = "missing"
        await model.runSearch()
        try await settle(view)
        try checkLayout(in: view, thumbnails: true, state: "empty thumbnail results")
        model.thumbnailView = false
        try await settle(view)
        try checkLayout(in: view, thumbnails: false, state: "empty table results")
        model.query = "item.txt"
        await model.runSearch()
        try await settle(view)
        try await capture(window, path: "/tmp/everything-sidebar-ready.png")
    }

    @MainActor private static func checkLayout(in view: NSView, thumbnails: Bool, state: String) throws {
        let descendants = descendants(of: view)
        let scroll: NSScrollView?
        if thumbnails {
            scroll = descendants.compactMap { $0 as? NSCollectionView }.first?.enclosingScrollView
        } else {
            scroll = descendants.compactMap { $0 as? NSTableView }.first?.enclosingScrollView
        }
        guard let scroll, let toggle = descendants.compactMap({ $0 as? NSButton }).first(where: {
            $0.identifier?.rawValue == "folder-sidebar-toggle"
        }) else { throw failure("Results or toolbar missing in \(state)") }
        let toolbar = toggle.convert(toggle.bounds, to: view)
        let topGap = view.isFlipped ? toolbar.minY - view.bounds.minY : view.bounds.maxY - toolbar.maxY
        print("LAYOUT: \(state); window=\(view.bounds.height), results=\(scroll.bounds.height), toolbar top=\(topGap)")
        try require(scroll.bounds.height >= view.bounds.height * 0.65,
                    "Results collapsed to \(scroll.bounds.height) points in \(state), window \(view.bounds.height)")
        try require(topGap < 80, "Search toolbar moved \(topGap) points from the window top in \(state)")
    }

    @MainActor private static func descendants(of root: NSView) -> [NSView] {
        var remaining = [root], result: [NSView] = []
        while let view = remaining.popLast() { result.append(view); remaining.append(contentsOf: view.subviews) }
        return result
    }

    @MainActor private static func settle(_ view: NSView) async throws {
        try await Task.sleep(for: .milliseconds(150))
        view.layoutSubtreeIfNeeded()
    }

    @MainActor private static func capture(_ window: NSWindow, path: String) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-l", String(window.windowNumber), path]
        try process.run(); process.waitUntilExit()
        try require(process.terminationStatus == 0, "Native layout capture failed")
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw failure(message) }
    }
    private static func failure(_ message: String) -> Error {
        NSError(domain: "SidebarLayoutTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
    @MainActor private static func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            try require(ContinuousClock.now < deadline, "Timed out waiting for fixture results")
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
