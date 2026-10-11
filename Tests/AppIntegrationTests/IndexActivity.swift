import Foundation
import IndexCore

// Holds the actual filesystem writer, as a synchronous NAS syscall can do.
extension IndexActor {
    func blockActivityFixture(entered: DispatchSemaphore, release: DispatchSemaphore) {
        entered.signal()
        _ = release.wait(timeout: .now() + 5)
    }
}

private final class ActivityScanFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var shouldBlock = false
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    var blockNext: Bool {
        get { lock.withLock { shouldBlock } }
        set { lock.withLock { shouldBlock = newValue } }
    }

    func scan(_ root: String, rules: ExcludeRules, cancelled: @escaping @Sendable () -> Bool,
              progress: @escaping @Sendable (Int) -> Void) -> FileStore {
        let block = lock.withLock { let block = shouldBlock; shouldBlock = false; return block }
        let store = ParallelScanner.scan(root: root, rules: rules, volID: 1, workers: 2,
                                          isCancelled: cancelled, progress: progress)
        progress(store.count)
        if block {
            entered.signal()
            _ = release.wait(timeout: .now() + 5)
            progress(99_999) // A stale callback from a syscall already in flight.
        }
        return store
    }
}

@main struct IndexActivityFixture {
    private static func require(_ condition: Bool, _ message: String = "Index activity assertion failed") {
        precondition(condition, message)
    }

    private static func waitForEntry(_ semaphore: DispatchSemaphore) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: semaphore.wait(timeout: .now() + 5) == .success)
            }
        }
    }
    private static func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !predicate() {
            require(ContinuousClock.now < deadline, "Activity fixture did not settle")
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    static func main() async throws {
        let suite = "index-activity-\(UUID().uuidString)", preferences = UserDefaults(suiteName: suite)!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            preferences.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let tree = directory.appendingPathComponent("tree"), cache = directory.appendingPathComponent("index.idx")
        try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
        try Data([1]).write(to: tree.appendingPathComponent("seed.txt"))
        let fixture = ActivityScanFixture()
        let index = IndexActor(rules: .defaults, preferencesSuiteName: suite, cacheURL: cache,
            diskScanner: { fixture.scan(tree.path, rules: $0, cancelled: $1, progress: $2) },
            networkMounts: { [] }, activityCapacity: 12)
        require(await index.rescanAll())
        require(index.activitySnapshot().indexedRoots == [tree.path])
        require(index.activitySnapshot().indexedCount == index.totalCount)
        try await verifyLiveChanges(index: index, tree: tree)
        await index.flush()
        let saved = index.activitySnapshot().cache
        require(saved.lastOperation == .cacheSaved && saved.lastSavedAt != nil)
        let attributes = try FileManager.default.attributesOfItem(atPath: cache.path)
        require(saved.byteCount == (attributes[.size] as! NSNumber).uint64Value)
        require(saved.modifiedAt == attributes[.modificationDate] as? Date)
        let loader = IndexActor(rules: .defaults, preferencesSuiteName: suite, cacheURL: cache, networkMounts: { [] })
        require(await loader.hasUsableCache())
        require(loader.activitySnapshot().cache.lastOperation == .cacheLoaded)
        require(loader.activitySnapshot().cache.lastLoadedAt != nil)
        try await verifyRetiredScan(index: index, fixture: fixture)
        try await verifyRequestedCancellation(index: index, fixture: fixture)
        for _ in 0..<3 { require(await index.rescanAll()) }
        try await verifyCacheFailure(tree: tree, directory: directory, suite: suite)
        let snapshot = index.activitySnapshot()
        require(snapshot.events.count <= 12 && snapshot.droppedEventCount > 0)
        require(snapshot.events.map(\.id) == snapshot.events.map(\.id).sorted())
        await verifyBlockedWriter(index)
        index.clearActivity()
        require(index.activitySnapshot().events.isEmpty)
        require(index.activitySnapshot().indexedCount == snapshot.indexedCount)
        print("PASS: real filesystem observations; bounded ordered journal; stale cancelled scans; cache size/dates and actual failures; activity and search bypass a blocked writer")
    }

    private static func verifyLiveChanges(index: IndexActor, tree: URL) async throws {
        let added = tree.appendingPathComponent("added.txt")
        try Data([2]).write(to: added)
        await index.enqueueChanges([.init(path: tree.path, mustScanSubtree: false)])
        try await waitUntil { index.activitySnapshot().events.contains { $0.kind == .added && $0.path == added.path } }
        try FileManager.default.removeItem(at: added)
        await index.enqueueChanges([.init(path: tree.path, mustScanSubtree: false)])
        try await waitUntil { index.activitySnapshot().events.contains { $0.kind == .removed && $0.path == added.path } }
    }

    private static func verifyRetiredScan(index: IndexActor, fixture: ActivityScanFixture) async throws {
        fixture.blockNext = true
        let old = Task.detached { await index.rescanAll() }
        require(await waitForEntry(fixture.entered))
        let before = index.activitySnapshot().events.count
        require(await index.rescanAll())
        let snapshot = index.activitySnapshot()
        require(snapshot.events.dropFirst(before).contains { $0.kind == .scanCancelled })
        let terminalCount = snapshot.events.filter { $0.kind == .scanCompleted }.count
        fixture.release.signal()
        require(!(await old.value))
        try await Task.sleep(for: .milliseconds(20))
        require(index.activitySnapshot().activeScans.isEmpty)
        require(index.activitySnapshot().events.filter { $0.kind == .scanCompleted }.count == terminalCount)
        require(!index.activitySnapshot().events.contains { $0.count == 99_999 })
    }

    private static func verifyBlockedWriter(_ index: IndexActor) async {
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let blocked = Task.detached { await index.blockActivityFixture(entered: entered, release: release) }
        require(await waitForEntry(entered))
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { release.signal() }
        let started = ContinuousClock.now
        let snapshot = index.activitySnapshot()
        index.clearActivity()
        let hits = await index.search("seed.txt", matchPath: false, sort: .name, ascending: true)
        let elapsed = ContinuousClock.now - started
        release.signal()
        await blocked.value
        require(snapshot.indexedCount > 0 && hits.count == 1)
        require(elapsed < .milliseconds(500), "Activity polling waited behind the filesystem writer")
    }

    private static func verifyRequestedCancellation(index: IndexActor, fixture: ActivityScanFixture) async throws {
        fixture.blockNext = true
        let scan = Task.detached { await index.rescanAll() }
        require(await waitForEntry(fixture.entered))
        let completed = index.activitySnapshot().events.filter { $0.kind == .scanCompleted }.map(\.id)
        scan.cancel()
        try await waitUntil { index.activitySnapshot().activeScans.isEmpty }
        require(index.activitySnapshot().events.last?.kind == .scanCancelled)
        fixture.release.signal()
        require(!(await scan.value))
        require(index.activitySnapshot().events.filter { $0.kind == .scanCompleted }.map(\.id) == completed)
    }

    private static func verifyCacheFailure(tree: URL, directory: URL, suite: String) async throws {
        let badCache = directory.appendingPathComponent("absent/index.idx")
        let index = IndexActor(rules: .defaults, preferencesSuiteName: suite, cacheURL: badCache,
            diskScanner: { ParallelScanner.scan(root: tree.path, rules: $0, volID: 1, workers: 2,
                                                 isCancelled: $1, progress: $2) }, networkMounts: { [] })
        require(await index.rescanAll())
        await index.flush()
        let status = index.activitySnapshot().cache
        require(status.lastOperation == .cacheSaveFailed && status.lastSavedAt == nil)
        do {
            try IndexCache.save(index.searchIndex.readSnapshot(), to: badCache, lastEventID: 0, rulesFingerprint: 0)
            preconditionFailure("Cache fixture unexpectedly saved")
        } catch { require(status.detail == error.localizedDescription) }
        require(!(await index.hasUsableCache()))
        require(index.activitySnapshot().cache.lastOperation == .cacheLoadFailed)
    }
}
