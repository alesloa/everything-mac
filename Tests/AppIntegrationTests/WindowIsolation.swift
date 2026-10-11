import AppKit
import IndexCore

@main struct WindowIsolation {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let suite = "window-isolation-\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer {
            preferences.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: temporary)
        }
        let index = IndexActor(rules: .defaults, preferencesSuiteName: suite,
            cacheURL: temporary.appendingPathComponent("index.idx"), diskScanner: { _, _, _ in
                var store = FileStore()
                let root = store.append(name: "/", parent: FileStore.noParent, size: 0,
                                        mtime: 0, isDir: true, volID: 1)
                store.append(name: "first.txt", parent: root, size: 1, mtime: 1, isDir: false, volID: 1)
                store.append(name: "second.txt", parent: root, size: 2, mtime: 2, isDir: false, volID: 1)
                return store
            })
        let completed = await index.rescanAll()
        precondition(completed)
        let background = AppModel(index: index, preferences: preferences)
        let first = AppModel(index: index, preferences: preferences)
        let second = AppModel(index: index, preferences: preferences)
        first.prepareWindow(with: background)
        second.prepareWindow(with: background)
        first.fuzzy = false; second.fuzzy = false
        first.query = "first"; second.query = "second"
        await first.runSearch(); await second.runSearch()
        precondition(first.results.map(\.name) == ["first.txt"])
        precondition(second.results.map(\.name) == ["second.txt"])
        first.caseSensitive = true; first.sortKey = .size
        precondition(second.query == "second" && !second.caseSensitive && second.sortKey != .size,
                     "A window changed another window's search options")

        background.rules.names = ["changed-rules"]
        background.shares = []
        background.total = index.totalCount
        background.scanning = true
        precondition(first.scanning && second.scanning)
        precondition(first.rules.names == ["changed-rules"] && second.total == 3)
        background.scanning = false
        background.indexRevision &+= 1
        try await Task.sleep(for: .milliseconds(100))
        precondition(first.results.map(\.name) == ["first.txt"] && second.results.map(\.name) == ["second.txt"])
        print("PASS: windows keep independent searches and receive shared index updates")
    }
}
