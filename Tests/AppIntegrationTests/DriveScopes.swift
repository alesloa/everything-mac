import AppKit
import SwiftUI
import IndexCore

private final class DriveMountFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var online = true
    let mount: MountTable.Mount
    init(path: String, source: String) {
        mount = MountTable.Mount(path: path, source: source, fsType: "smbfs", isLocal: false)
    }
    func disconnect() { lock.withLock { online = false } }
    func mounts() -> [MountTable.Mount] { lock.withLock { online ? [mount] : [] } }
}

@main struct DriveScopesTests {
    @MainActor static func main() {
        Task { @MainActor in
            do {
                try await run()
                print("PASS: startup disk toggles preserve external/offline network files; closing the sidebar clears and persists its scope")
                exit(EXIT_SUCCESS)
            } catch {
                print("FAIL: \(error.localizedDescription)"); exit(EXIT_FAILURE)
            }
        }
        NSApplication.shared.run()
    }

    @MainActor private static func run() async throws {
        let suite = "EverythingMac.DriveScopes.\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        let manager = FileManager.default
        let directory = manager.temporaryDirectory.appendingPathComponent(suite)
        let fileSystem = directory.appendingPathComponent("filesystem")
        defer { preferences.removePersistentDomain(forName: suite); try? manager.removeItem(at: directory) }
        for path in ["Users", "Volumes/Enabled", "Volumes/Excluded", "Volumes/Network"] {
            let folder = fileSystem.appendingPathComponent(path)
            try manager.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data([1]).write(to: folder.appendingPathComponent("item.txt"))
        }
        let alias = fileSystem.appendingPathComponent("Volumes/Startup")
        try manager.createSymbolicLink(atPath: alias.path, withDestinationPath: fileSystem.path)
        let bootFile = fileSystem.path + "/Users/item.txt"
        let externalPath = fileSystem.path + "/Volumes/Enabled"
        let sharePath = fileSystem.path + "/Volumes/Network"
        let aliases = IndexActor.startupVolumeAliases(in: fileSystem.path + "/Volumes", target: fileSystem.path)
        try require(aliases == [alias.path], "Startup alias exclusion did not identify only the boot symlink")
        try verifyDetachedShareRetention()
        let share = NetworkShare(source: "//fixture/network", name: "Network")
        let mounts = DriveMountFixture(path: sharePath, source: share.source)
        var initial = ExcludeRules(pathPrefixes: [fileSystem.path + "/Volumes/Excluded"], networkShares: [share])
        let base = fileSystem.path
        let index = IndexActor(rules: initial, preferencesSuiteName: suite,
            cacheURL: directory.appendingPathComponent("index.idx"), diskScanner: { rules, cancelled, progress in
                var local = rules
                local.pathPrefixes.append(sharePath)
                if rules.excludeBootVolume { local.pathPrefixes += aliases }
                return ParallelScanner.scanWholeDisk(rules: local, fileSystemRoot: base,
                                                     isCancelled: cancelled, progress: progress)
            }, networkMounts: { mounts.mounts() })
        try require(await index.rescanAll(), "Initial volume fixture scan failed")
        try await waitUntil {
            let records = await index.search("item.txt", matchPath: false, sort: .name, ascending: true)
            return records.count == 3
        }
        mounts.disconnect()
        initial.excludeBootVolume = true
        await index.setRules(initial)
        try require(await index.rescanAll(), "External-only fixture scan failed")
        var records = await index.search("item.txt", matchPath: false, sort: .name, ascending: true)
        try require(Set(records.map(\.path)) == [externalPath + "/item.txt", sharePath + "/item.txt"],
                    "Disabling the startup disk lost an external drive or offline network cache")
        await index.sweepUserFolders()
        records = await index.search("item.txt", matchPath: false, sort: .name, ascending: true)
        try require(!records.map(\.path).contains(bootFile), "A user-folder sweep restored excluded boot files")
        let persistedRules = try JSONDecoder().decode(ExcludeRules.self, from: preferences.data(forKey: "excludeRules")!)
        try require(persistedRules.excludeBootVolume, "Startup disk choice did not persist")
        await index.flush()
        let cached = try IndexCache.load(from: directory.appendingPathComponent("index.idx")).0
        try require(cached.path(of: cached.rootID) == fileSystem.path + "/Volumes", "Cache kept the startup scan root")
        initial.excludeBootVolume = false
        await index.setRules(initial)
        try require(await index.rescanAll(), "Re-enabling startup scan failed")
        records = await index.search("item.txt", matchPath: false, sort: .name, ascending: true)
        try require(records.count == 3 && records.map(\.path).contains(bootFile), "Re-enabling startup lost local or offline files")

        let edit = SettingsModel()
        edit.load(from: initial)
        let view = VolumesSettingsView(edit: edit, apply: {})
        let boot = VolumesSettingsView.VolumeInfo(name: "Startup", path: "/", isBoot: true)
        let external = VolumesSettingsView.VolumeInfo(name: "Enabled", path: externalPath, isBoot: false)
        view.volumeBinding(boot).wrappedValue = false
        try require(!view.volumeBinding(boot).wrappedValue && view.volumeBinding(external).wrappedValue,
                    "Startup switch disabled the external switch")
        try require(edit.makeRules().excludeBootVolume && !edit.pathPrefixes.contains("/"),
                    "Startup switch excluded the entire filesystem")
        view.volumeBinding(external).wrappedValue = false
        try require(edit.pathPrefixes.contains(externalPath), "External exclusion did not persist")
        view.volumeBinding(external).wrappedValue = true
        view.volumeBinding(boot).wrappedValue = true
        try require(!edit.makeRules().excludeBootVolume, "Startup switch could not be re-enabled")

        let model = AppModel(index: index, preferences: preferences)
        model.workspace.activate(defaultState: SearchWorkspaceState())
        model.query = "item.txt"; model.searchFilters = SearchFilters(types: [.files])
        model.sortKey = .size; model.ascending = false
        model.setFolderScope(FolderScope(path: externalPath))
        try await waitUntil { model.totalMatches == 1 && model.results.first?.path == externalPath + "/item.txt" }
        try require(model.folderSidebarVisible, "A selected scope was hidden")
        let saved = try model.saveCurrentSearch(name: "Selected drive")
        let second = AppModel(index: index, preferences: preferences,
            workspace: SearchWorkspaceController(library: model.workspace.library))
        second.workspace.activate(defaultState: SearchWorkspaceState())
        second.query = "item.txt"
        second.setFolderScope(FolderScope(path: sharePath))
        model.setFolderSidebarVisible(false)
        try await waitUntil { model.totalMatches == 3 }
        try require(model.folderScope == nil && !model.folderSidebarVisible,
                    "Closing the sidebar left an active folder restriction")
        try require(model.query == "item.txt" && model.searchFilters.selectedTypes == [.files]
                    && model.sortKey == .size && !model.ascending, "Closing sidebar changed unrelated search choices")
        try require(second.folderScope?.path == sharePath && second.folderSidebarVisible,
                    "Closing one sidebar changed another window")
        let windowID = model.workspace.window.id
        let restored = WorkspaceLibrary(preferences: preferences)
        try require(restored.archive.windows.first { $0.id == windowID }?.selectedTab.state.folderScopePath == nil,
                    "Closed sidebar scope returned after session reload")
        model.setFolderSidebarVisible(true)
        try require(model.folderScope == nil, "Reopening the sidebar restored a forgotten restriction")
        var legacy = saved.state
        legacy.folderSidebarVisible = false
        model.applyWorkspace(legacy)
        try require(model.folderScope?.path == externalPath && model.folderSidebarVisible,
                    "Restoring an older scoped search hid its restriction")
        model.setFolderSidebarVisible(false)
        model.newSearchTab(); model.closeSearchTab()
        try require(model.folderScope == nil && !model.folderSidebarVisible,
                    "Tab switching restored a cleared folder restriction")
        model.openSavedSearch(saved)
        try require(model.folderScope?.path == externalPath && model.folderSidebarVisible,
                    "Opening an explicit saved drive search discarded or hid its location")
        let custom = try model.saveCurrentSearch(name: "Selected drive filter", isCustomFilter: true)
        model.applySavedFilter(custom.id)
        try require(model.workspaceSnapshot.customFilterID == custom.id, "Saved custom filter selection was discarded")
        model.applySavedFilter(nil)
        try require(model.workspaceSnapshot.customFilterID == nil, "Saved custom filter could not be cleared")
        try await verifySidebarToggle(model)
        edit.indexBootVolume = false
        try await capture(NSHostingView(rootView: VolumesSettingsView(edit: edit, apply: {}).environmentObject(model)),
                          size: NSSize(width: 540, height: 480), path: "/tmp/everything-drive-settings.png")
    }

    @MainActor private static func verifySidebarToggle(_ model: AppModel) async throws {
        let view = NSHostingView(rootView: ContentView().environmentObject(model))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 850, height: 420),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view; window.orderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(150))
        view.layoutSubtreeIfNeeded()
        guard let expanded = sidebarToggle(in: view) else { throw failure("Expanded sidebar toggle is missing") }
        let frame = expanded.convert(expanded.bounds, to: nil)
        try require(expanded.state == .on, "Expanded toggle does not reflect the open sidebar")
        expanded.performClick(nil)
        try await waitUntil { !model.folderSidebarVisible && model.folderScope == nil && model.totalMatches == 3 }
        view.layoutSubtreeIfNeeded()
        guard let collapsed = sidebarToggle(in: view) else { throw failure("Collapsed sidebar toggle disappeared") }
        let collapsedFrame = collapsed.convert(collapsed.bounds, to: nil)
        try require(abs(collapsedFrame.minX - frame.minX) < 1 && abs(collapsedFrame.minY - frame.minY) < 1,
                    "Sidebar toggle moved when the panel collapsed")
        try require(collapsed.state == .off, "Collapsed toggle does not reflect the hidden sidebar")
        try await screenshot(window, path: "/tmp/everything-drive-toggle-collapsed.png")
        collapsed.performClick(nil)
        try await waitUntil { model.folderSidebarVisible }
        try require(model.folderScope == nil && model.query == "item.txt", "Expanding restored a forgotten folder or erased the query")
        try await screenshot(window, path: "/tmp/everything-drive-toggle-expanded.png")
    }

    @MainActor private static func sidebarToggle(in root: NSView) -> NSButton? {
        var remaining = [root]
        while let view = remaining.popLast() {
            if let button = view as? NSButton, button.identifier?.rawValue == "folder-sidebar-toggle" { return button }
            remaining.append(contentsOf: view.subviews)
        }
        return nil
    }

    @MainActor private static func screenshot(_ window: NSWindow, path: String) async throws {
        try await Task.sleep(for: .milliseconds(100))
        window.contentView?.layoutSubtreeIfNeeded()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-l", String(window.windowNumber), path]
        try process.run(); process.waitUntilExit()
        try require(process.terminationStatus == 0, "Native UI capture failed")
    }

    private static func verifyDetachedShareRetention() throws {
        let share = NetworkShare(source: "//fixture/detached", name: "Detached")
        func localStore(_ rootPath: String) -> FileStore {
            var store = FileStore()
            store.append(name: rootPath, parent: FileStore.noParent, size: 0, mtime: 0, isDir: true, volID: 1)
            return store
        }
        var replacement = localStore("/Volumes")
        var scanned = FileStore()
        let root = scanned.append(name: "/Users/fixture/Network", parent: FileStore.noParent,
                                  size: 17, mtime: 23, isDir: true, volID: share.volID)
        scanned.append(name: "known.txt", parent: root, size: 42, mtime: 7, isDir: false, volID: share.volID)
        try require(ShareIndexMutation.replace(share, at: "/Users/fixture/Network", with: scanned, in: &replacement),
                    "A network share outside /Volumes could not be added with the startup disk disabled")
        try require(replacement.path(of: replacement.rootID) == "/Volumes", "Detached share replaced the local root")
        var offline = localStore("/Volumes")
        ShareIndexMutation.retainKnownShares([share], from: replacement, in: &offline, isCancelled: { false })
        let hits = QueryEngine().search(Query(text: "known.txt"), in: offline)
        try require(hits.count == 1 && offline.path(of: hits[0]) == "/Users/fixture/Network/known.txt",
                    "Offline network files outside /Volumes were lost on rebuild")
        var enabled = localStore("/")
        let users = enabled.append(name: "Users", parent: enabled.rootID, size: 0, mtime: 0, isDir: true, volID: 1)
        enabled.append(name: "fixture", parent: users, size: 0, mtime: 0, isDir: true, volID: 1)
        ShareIndexMutation.retainKnownShares([share], from: offline, in: &enabled, isCancelled: { false })
        try require(enabled.idForDirPath("/Users/fixture/Network") != nil, "Re-enabled boot scan could not reattach a detached share")
    }

    @MainActor private static func capture(_ view: NSView, size: NSSize, path: String) async throws {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view; window.orderFront(nil)
        try await Task.sleep(for: .milliseconds(150))
        view.layoutSubtreeIfNeeded()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-l", String(window.windowNumber), path]
        try process.run(); process.waitUntilExit()
        try require(process.terminationStatus == 0, "Native UI capture failed")
        window.close()
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw failure(message) }
    }
    private static func failure(_ message: String) -> Error {
        NSError(domain: "DriveScopesTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
    @MainActor private static func waitUntil(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !(await condition()) {
            try require(ContinuousClock.now < deadline, "Timed out waiting for drive search results")
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
