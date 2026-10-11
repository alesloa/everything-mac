import Foundation
import IndexCore

private final class ShareFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var currentMounts: [MountTable.Mount] = []
    private var now = Date(timeIntervalSince1970: 1_700_000_000)
    private var scans = 0
    private var blocked: Set<Int> = []
    private var released: Set<Int> = []
    private var blockNext = false
    private var blockEvery = false
    private var cancelled: Set<Int> = []

    var mounts: [MountTable.Mount] { lock.withLock { currentMounts } }
    var date: Date { lock.withLock { now } }
    var callCount: Int { lock.withLock { scans } }
    var blockedCalls: Set<Int> { lock.withLock { blocked } }
    var cancelledCalls: Set<Int> { lock.withLock { cancelled } }

    func setMounts(_ mounts: [MountTable.Mount]) { lock.withLock { currentMounts = mounts } }
    func advance(_ seconds: TimeInterval) { lock.withLock { now += seconds } }
    func blockOne() { lock.withLock { blockNext = true } }
    func blockAll() { lock.withLock { blockEvery = true } }
    func release(_ call: Int) { _ = lock.withLock { released.insert(call) } }
    func releaseAll() { lock.withLock { blockEvery = false; released.formUnion(blocked) } }

    func scan(_ path: String, rules: ExcludeRules, volID: UInt32,
              isCancelled: @escaping @Sendable () -> Bool,
              progress: @escaping @Sendable (Int) -> Void) -> FileStore {
        let (call, shouldBlock) = lock.withLock {
            scans += 1
            let shouldBlock = blockNext || blockEvery
            blockNext = false
            return (scans, shouldBlock)
        }
        let snapshot = ParallelScanner.scan(root: path, rules: rules, volID: volID, workers: 2,
                                            isCancelled: isCancelled, progress: progress)
        if shouldBlock {
            _ = lock.withLock { blocked.insert(call) }
            // Simulate a syscall which ignores cooperative cancellation until it
            // returns, including a final progress callback already in flight.
            while !lock.withLock({ released.contains(call) }) { usleep(1_000) }
            if isCancelled() { _ = lock.withLock { cancelled.insert(call) } }
            progress(88_888)
        }
        return snapshot
    }
}

@main struct NetworkRefresh {
    private static func require(_ condition: Bool, _ message: String = "Network refresh assertion failed") {
        precondition(condition, message)
    }

    private static func waitUntil(_ predicate: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !(await predicate()) {
            require(ContinuousClock.now < deadline, "Network fixture did not reach the expected state")
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    private static func settled(_ index: IndexActor) async -> Bool {
        await index.networkShareStatuses().allSatisfy { !$0.scanning && !$0.queued }
    }

    private static func hits(_ index: IndexActor, _ text: String) async -> [FileRecord] {
        await index.search(text, matchPath: false, sort: .name, ascending: true)
    }

    private static func rootStore(_ path: String) -> FileStore {
        var result = FileStore()
        result.append(name: path, parent: FileStore.noParent, size: 0, mtime: 0, isDir: true, volID: 1)
        return result
    }

    static func main() async throws {
        let suite = "network-refresh-\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer {
            preferences.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: base)
        }
        try await verifyScheduledRefresh(base: base, suite: suite)
        try await verifyWorkerBound(base: base, suite: suite)
        print("PASS: mounted-share edits refresh without blocking search; pause/cancel/offline/stale results preserve snapshots and worker bounds")
    }

    private static func verifyScheduledRefresh(base: URL, suite: String) async throws {
        let fixture = ShareFixture()
        let directory = base.appendingPathComponent("share")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let oldFile = directory.appendingPathComponent("old.txt")
        try Data([1]).write(to: oldFile)
        let share = NetworkShare(source: "//fixture/share", name: "share")
        func mount(_ path: String) -> MountTable.Mount {
            .init(path: path, source: share.source, fsType: "smbfs", isLocal: false)
        }
        fixture.setMounts([mount(directory.path)])
        var rules = ExcludeRules.defaults
        rules.networkShares = [share]
        let index = IndexActor(rules: rules, preferencesSuiteName: suite,
            cacheURL: base.appendingPathComponent("index.idx"),
            diskScanner: { _, _, _ in rootStore(base.path) },
            shareScanner: { fixture.scan($0, rules: $1, volID: $2, isCancelled: $3, progress: $4) },
            networkMounts: { fixture.mounts }, refreshClock: { fixture.date })
        let seeded = await index.rescanAll()
        require(seeded)
        try await waitUntil { await settled(index) && fixture.callCount == 1 }
        require(await hits(index, "old.txt").count == 1)
        require(await index.networkShareStatuses()[0].lastRefreshed == fixture.date)

        try FileManager.default.removeItem(at: oldFile)
        let newFile = directory.appendingPathComponent("new.txt")
        try Data([2, 3]).write(to: newFile)
        fixture.advance(299)
        await index.checkNetworkShares()
        require(fixture.callCount == 1, "Refresh ran before the configured interval")
        fixture.advance(1)
        await index.checkNetworkShares()
        try await waitUntil { await settled(index) && fixture.callCount == 2 }
        require(await hits(index, "old.txt").isEmpty)
        require(await hits(index, "new.txt").count == 1)

        let paused = NetworkShareRefreshPolicy(paused: true, interval: 60)
        await index.setShareRefreshPolicy(paused, for: share)
        fixture.advance(3600)
        await index.checkNetworkShares()
        require(fixture.callCount == 2)
        let restored = IndexActor(rules: rules, preferencesSuiteName: suite)
        require(await restored.currentShareRefreshPolicy(for: share) == paused)
        await index.refreshShare(share)
        try await waitUntil { await settled(index) && fixture.callCount == 3 }
        require(await index.networkShareStatuses()[0].paused)
        await index.setShareRefreshPolicy(NetworkShareRefreshPolicy(interval: 60), for: share)
        try await waitUntil { await settled(index) && fixture.callCount == 4 }

        fixture.blockOne()
        await index.refreshShare(share)
        try await waitUntil { fixture.blockedCalls.contains(5) }
        let beforeSearch = ContinuousClock.now
        let snapshotHits = await hits(index, "new.txt")
        require(snapshotHits.count == 1 && ContinuousClock.now - beforeSearch < .seconds(1),
                     "A stalled share scan blocked an immutable-snapshot query")
        await index.setShareRefreshPolicy(paused, for: share)
        for _ in 0..<4 { await index.refreshShare(share) }
        require(fixture.callCount == 5, "Cancellation started an overlapping physical share walk")
        require(await index.networkShareStatuses()[0].queued)
        await index.cancelShareRefresh(share)
        let afterCancel = ContinuousClock.now
        let cancelledHits = await hits(index, "new.txt")
        require(cancelledHits.count == 1 && ContinuousClock.now - afterCancel < .seconds(1),
                "Cancellation blocked access to the previous searchable snapshot")
        fixture.release(5)
        try await waitUntil { fixture.cancelledCalls.contains(5) }
        try await Task.sleep(for: .milliseconds(20))
        require(await settled(index))
        require(await index.networkShareStatuses()[0].count < 88_888,
                     "Retired worker progress escaped its generation")

        // A manual request queued behind a cancelled physical syscall remains
        // valid even when automatic scheduling is paused and checked again.
        fixture.blockOne()
        await index.refreshShare(share)
        try await waitUntil { fixture.blockedCalls.contains(6) }
        await index.cancelShareRefresh(share)
        await index.refreshShare(share)
        await index.checkNetworkShares()
        require(await index.networkShareStatuses()[0].queued)
        require(fixture.callCount == 6)
        fixture.release(6)
        try await waitUntil { await settled(index) && fixture.callCount == 7 }
        require(await index.networkShareStatuses()[0].paused)

        // A permission failure must not turn a scheduled refresh into deletion.
        let unreadable = directory.appendingPathComponent("unreadable")
        try FileManager.default.createDirectory(at: unreadable, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: unreadable.path)
        let lastGood = await index.networkShareStatuses()[0].lastRefreshed
        fixture.advance(1)
        await index.refreshShare(share)
        try await waitUntil { await settled(index) && fixture.callCount == 8 }
        require(await hits(index, "new.txt").count == 1)
        require(await index.networkShareStatuses()[0].lastRefreshed == lastGood)
        for _ in 0..<10 { await index.checkNetworkShares() }
        require(fixture.callCount == 8, "A rejected refresh entered a busy retry loop")
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: unreadable.path)

        fixture.blockOne()
        await index.refreshShare(share)
        try await waitUntil { fixture.blockedCalls.contains(9) }
        fixture.setMounts([])
        await index.checkNetworkShares()
        require(await index.networkShareStatuses()[0].isOffline)
        require(await hits(index, "new.txt").count == 1, "Unmounting erased cached offline results")
        let moved = base.appendingPathComponent("share-remounted")
        try FileManager.default.moveItem(at: directory, to: moved)
        try FileManager.default.removeItem(at: moved.appendingPathComponent("new.txt"))
        try Data([4]).write(to: moved.appendingPathComponent("remounted.txt"))
        fixture.setMounts([mount(moved.path)])
        await index.setShareRefreshPolicy(NetworkShareRefreshPolicy(interval: 60), for: share)
        require(fixture.callCount == 9)
        fixture.release(9)
        try await waitUntil { await settled(index) && fixture.callCount == 10 }
        let remounted = await hits(index, "remounted.txt")
        require(remounted.count == 1 && remounted[0].path == moved.appendingPathComponent("remounted.txt").path)
        require(await hits(index, "new.txt").isEmpty, "Stale completion overwrote remounted-share results")
        let successful = await index.networkShareStatuses()[0].lastRefreshed
        fixture.advance(-120)
        await index.checkNetworkShares()
        try await waitUntil { await settled(index) && fixture.callCount == 11 }
        require(await index.networkShareStatuses()[0].lastRefreshed != successful,
                     "A backwards wall-clock adjustment suppressed scheduled refresh indefinitely")
    }

    private static func verifyWorkerBound(base: URL, suite: String) async throws {
        let fixture = ShareFixture()
        fixture.blockAll()
        defer { fixture.releaseAll() }
        var rules = ExcludeRules.defaults
        var mounts: [MountTable.Mount] = []
        for number in 1...3 {
            let directory = base.appendingPathComponent("bounded-\(number)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data([1]).write(to: directory.appendingPathComponent("file-\(number).txt"))
            let share = NetworkShare(source: "//fixture/bounded-\(number)", name: "bounded-\(number)")
            rules.networkShares.append(share)
            mounts.append(.init(path: directory.path, source: share.source, fsType: "smbfs", isLocal: false))
        }
        fixture.setMounts(mounts)
        let index = IndexActor(rules: rules, preferencesSuiteName: suite,
            cacheURL: base.appendingPathComponent("bounded.idx"),
            diskScanner: { _, _, _ in rootStore(base.path) },
            shareScanner: { fixture.scan($0, rules: $1, volID: $2, isCancelled: $3, progress: $4) },
            networkMounts: { fixture.mounts }, refreshClock: { fixture.date })
        let seeded = await index.rescanAll()
        require(seeded)
        try await waitUntil { fixture.blockedCalls.count == 2 }
        for _ in 0..<10 { await index.checkNetworkShares() }
        require(fixture.callCount == 2, "Scheduled work exceeded the physical worker bound")
        let statuses = await index.networkShareStatuses()
        require(statuses.filter(\.scanning).count == 2 && statuses.filter(\.queued).count == 1)
        fixture.release(1)
        try await waitUntil { fixture.callCount == 3 && fixture.blockedCalls.contains(3) }
        require(await index.networkShareStatuses().filter(\.scanning).count == 2)
        fixture.releaseAll()
        try await waitUntil { await settled(index) }
        require(await hits(index, "file-").count == 3)
    }
}
