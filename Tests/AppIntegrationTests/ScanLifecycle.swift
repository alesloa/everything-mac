import Foundation
import AppKit
import IndexCore

private final class ScanFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [Set<String>] = []
    private var cancelled = 0
    private var progress: [(Int, UUID)] = []

    var callCount: Int { lock.withLock { calls.count } }
    var slowCount: Int { lock.withLock { calls.filter { $0.contains("slow") }.count } }
    var cancelledCount: Int { lock.withLock { cancelled } }
    func recordProgress(_ count: Int, id: UUID) { lock.withLock { progress.append((count, id)) } }
    func hasProgress(_ count: Int, id: UUID) -> Bool { lock.withLock { progress.contains { $0 == (count, id) } } }

    func scan(_ rules: ExcludeRules, isCancelled: @escaping @Sendable () -> Bool,
              progress: @escaping @Sendable (Int) -> Void) -> FileStore {
        lock.withLock { calls.append(rules.names) }
        if rules.names.contains("slow") {
            progress(77)
            let deadline = ContinuousClock.now + .seconds(5)
            while !isCancelled() && ContinuousClock.now < deadline { usleep(1_000) }
            if isCancelled() { lock.withLock { cancelled += 1 } }
            // Simulate a callback and stale nonempty result already in flight.
            progress(88_888)
            return Self.store("stale.txt")
        }
        if rules.names.contains("empty") { return FileStore() }
        let latest = rules.names.contains("latest")
        progress(latest ? 3 : 2)
        return Self.store(latest ? "latest.txt" : "original.txt", extra: latest)
    }

    private static func store(_ name: String, extra: Bool = false) -> FileStore {
        var store = FileStore()
        let root = store.append(name: "/", parent: FileStore.noParent, size: 0, mtime: 0, isDir: true, volID: 1)
        store.append(name: name, parent: root, size: 1, mtime: 1, isDir: false, volID: 1)
        if extra { store.append(name: "latest-two.txt", parent: root, size: 1, mtime: 1, isDir: false, volID: 1) }
        return store
    }
}

@main struct ScanLifecycle {
    @MainActor private static func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !predicate() {
            precondition(ContinuousClock.now < deadline, "Fixture did not reach the expected scan state")
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    @MainActor static func main() async throws {
        let suite = "scan-lifecycle-\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer {
            preferences.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: temporary)
        }
        func rules(_ name: String) -> ExcludeRules {
            var result = ExcludeRules.defaults
            result.names = [name]
            return result
        }
        let fixture = ScanFixture()
        let actor = IndexActor(rules: .defaults, preferencesSuiteName: suite,
                               cacheURL: temporary.appendingPathComponent("actor.idx"),
                               diskScanner: { fixture.scan($0, isCancelled: $1, progress: $2) },
                               onProgress: { fixture.recordProgress($0, id: $1) })
        let originalCompleted = await actor.rescanAll()
        precondition(originalCompleted && actor.totalCount == 2)
        await actor.setRules(rules("slow"))
        let oldID = UUID()
        let old = Task { await actor.rescanAll(scanID: oldID) }
        try await waitUntil { fixture.slowCount == 1 }
        await actor.setRules(rules("latest"))
        let newID = UUID()
        let latestCompleted = await actor.rescanAll(scanID: newID)
        let oldCompleted = await old.value
        precondition(latestCompleted && !oldCompleted && actor.totalCount == 3)
        precondition(fixture.cancelledCount == 1, "Superseded walk was not cancelled")
        precondition(!fixture.hasProgress(88_888, id: oldID), "Obsolete scan progress escaped its generation")
        let latestHits = await actor.search("latest", matchPath: false, sort: .name, ascending: true)
        precondition(latestHits.map(\.name) == ["latest-two.txt", "latest.txt"])

        await actor.setRules(rules("empty"))
        let emptyCompleted = await actor.rescanAll()
        precondition(!emptyCompleted && actor.totalCount == 3, "Failed root scan erased a good snapshot")
        await actor.flush()
        let checkpoint = try IndexCache.load(from: temporary.appendingPathComponent("actor.idx")).1
        // This volume-root overflow has no directory in the fixture store, so its
        // drain does not read the real filesystem. Only a successful full rebuild
        // may unblock its replay checkpoint.
        await actor.enqueueChanges([.init(path: "/Volumes/scan-lifecycle-fixture", mustScanSubtree: true,
                                          eventID: checkpoint + 1)])
        await actor.setRules(rules("slow"))
        let cancelled = Task { await actor.rescanAll() }
        try await waitUntil { fixture.slowCount == 2 }
        cancelled.cancel()
        let cancelledCompleted = await cancelled.value
        precondition(!cancelledCompleted && actor.totalCount == 3 && fixture.cancelledCount == 2)
        try await Task.sleep(for: .milliseconds(650)) // event batching interval is 500ms
        await actor.flush()
        let afterCancellation = try IndexCache.load(from: temporary.appendingPathComponent("actor.idx")).1
        precondition(afterCancellation == checkpoint, "Cancelled rebuild advanced an unresolved overflow checkpoint")

        let modelFixture = ScanFixture()
        let modelIndex = IndexActor(rules: .defaults, preferencesSuiteName: suite,
                                    cacheURL: temporary.appendingPathComponent("model.idx"),
                                    diskScanner: { modelFixture.scan($0, isCancelled: $1, progress: $2) })
        let model = AppModel(index: modelIndex, preferences: preferences)
        model.rebuildIndex()
        precondition(model.scanning, "Rebuild commands were not disabled synchronously")
        model.rebuildIndex()
        try await waitUntil { !model.scanning && modelFixture.callCount == 1 }
        precondition(model.total == 2)
        model.query = "latest"
        model.applyRules(rules("slow"))
        try await waitUntil { modelFixture.slowCount == 1 }
        let beforeStaleProgress = model.total
        model.onScanProgress(99_999, scanID: UUID())
        precondition(model.total == beforeStaleProgress)
        model.applyRules(rules("latest"))
        try await waitUntil { !model.scanning && model.results.count == 2 }
        precondition(modelFixture.cancelledCount == 1 && model.total == 3 && model.rules == rules("latest"))
        precondition(model.results.allSatisfy { $0.name.hasPrefix("latest") })
        model.onScanProgress(99_999, scanID: UUID())
        precondition(!model.scanning && model.total == 3, "Late progress restarted the completed status")
        let cached = try IndexCache.load(from: temporary.appendingPathComponent("model.idx")).0
        precondition(cached.liveCount(volID: 1) == 3)
        try await verifySupersededOverflow(in: temporary, suite: suite)
        try await verifyLiveOverflowRebuildsOnce(in: temporary, suite: suite)
        try await verifyOverflowAfterReplayWaitsForLaunch(in: temporary, suite: suite)
        try verifyShareReplacement(in: temporary)
        verifyExactSharePathIdentity()
        verifyOfflineShareRetention()
        print("PASS: superseded/cancelled scans keep current results and progress; failed share replacement preserves known files")
    }

    @MainActor private static func verifySupersededOverflow(in temporary: URL, suite: String) async throws {
        let fixture = ScanFixture()
        let url = temporary.appendingPathComponent("superseded-overflow.idx")
        let index = IndexActor(rules: .defaults, preferencesSuiteName: suite, cacheURL: url,
                               diskScanner: { fixture.scan($0, isCancelled: $1, progress: $2) })
        let seeded = await index.rescanAll()
        precondition(seeded)
        await index.flush()
        let checkpoint = try IndexCache.load(from: url).1
        var slowRules = ExcludeRules.defaults
        slowRules.names = ["slow"]
        await index.setRules(slowRules)
        let older = Task { await index.rescanAll() }
        try await waitUntil { fixture.slowCount == 1 }
        // The overflow arrives after A began. B must accumulate that state before
        // resetting its own flag, because cancellation accepts neither snapshot.
        await index.enqueueChanges([.init(path: "/Volumes/scan-lifecycle-fixture", mustScanSubtree: true,
                                          eventID: checkpoint + 1)])
        let newer = Task { await index.rescanAll() }
        try await waitUntil { fixture.slowCount == 2 }
        newer.cancel()
        let olderCompleted = await older.value
        let newerCompleted = await newer.value
        precondition(!olderCompleted && !newerCompleted && fixture.cancelledCount == 2)
        try await Task.sleep(for: .milliseconds(650)) // event batching interval is 500ms
        await index.flush()
        let afterCancellation = try IndexCache.load(from: url).1
        precondition(afterCancellation == checkpoint,
                     "Overflow during a superseded rebuild advanced an unresolved checkpoint")
        precondition(index.totalCount == 2)

        var latestRules = ExcludeRules.defaults
        latestRules.names = ["latest"]
        await index.setRules(latestRules)
        let accepted = await index.rescanAll()
        precondition(accepted)
        await index.flush()
        let acceptedCheckpoint = try IndexCache.load(from: url).1
        await index.enqueueChanges([.init(path: "/Volumes/scan-lifecycle-fixture", mustScanSubtree: false,
                                          eventID: acceptedCheckpoint + 1)])
        try await Task.sleep(for: .milliseconds(650))
        await index.flush()
        let afterAcceptance = try IndexCache.load(from: url).1
        precondition(afterAcceptance == acceptedCheckpoint + 1,
                     "Accepted rebuild did not clear the previous overflow checkpoint block")
    }

    // An overflow during the launch replay freezes the replay checkpoint.
    // Without a rebuild, every launch replays the same days-old history again.
    @MainActor private static func verifyLiveOverflowRebuildsOnce(in temporary: URL, suite: String) async throws {
        let fixture = ScanFixture()
        let url = temporary.appendingPathComponent("live-overflow.idx")
        let index = IndexActor(rules: .defaults, preferencesSuiteName: suite, cacheURL: url,
                               diskScanner: { fixture.scan($0, isCancelled: $1, progress: $2) })
        let seeded = await index.rescanAll()
        precondition(seeded)
        await index.flush()
        let checkpoint = try IndexCache.load(from: url).1
        let overflow = LiveMonitor.FSChange(path: "/Volumes/scan-lifecycle-fixture", mustScanSubtree: true,
                                            eventID: checkpoint + 1)
        await index.receiveLiveChanges([overflow], generation: 0)
        try await waitUntil { fixture.callCount == 2 }
        try await Task.sleep(for: .milliseconds(650)) // event batching interval is 500ms
        await index.flush()
        let rebuilt = try IndexCache.load(from: url).1
        await index.receiveLiveChanges([.init(path: "/Volumes/scan-lifecycle-fixture", mustScanSubtree: false,
                                              eventID: rebuilt + 1)], generation: 0)
        try await Task.sleep(for: .milliseconds(650))
        await index.flush()
        let advanced = try IndexCache.load(from: url).1
        precondition(advanced == rebuilt + 1, "Replay checkpoint stayed frozen after the overflow rebuild")
        await index.receiveLiveChanges([overflow], generation: 0)
        try await Task.sleep(for: .milliseconds(650))
        precondition(fixture.callCount == 2, "A second overflow started another full rebuild in one session")
        precondition(index.totalCount == 2)
    }

    // After the replay catches up, an overflow keeps the checkpoint frozen for the
    // next launch's short replay instead of a full rebuild mid-session.
    @MainActor private static func verifyOverflowAfterReplayWaitsForLaunch(in temporary: URL, suite: String) async throws {
        let fixture = ScanFixture()
        let url = temporary.appendingPathComponent("post-replay-overflow.idx")
        let index = IndexActor(rules: .defaults, preferencesSuiteName: suite, cacheURL: url,
                               diskScanner: { fixture.scan($0, isCancelled: $1, progress: $2) })
        let seeded = await index.rescanAll()
        precondition(seeded)
        await index.flush()
        let checkpoint = try IndexCache.load(from: url).1
        let path = "/Volumes/scan-lifecycle-fixture"
        await index.receiveLiveChanges([.init(path: path, mustScanSubtree: false, eventID: checkpoint + 1,
                                              historyDone: true)], generation: 0)
        await index.receiveLiveChanges([.init(path: path, mustScanSubtree: true, eventID: checkpoint + 2)],
                                       generation: 0)
        await index.receiveLiveChanges([.init(path: path, mustScanSubtree: false, eventID: checkpoint + 3)],
                                       generation: 0)
        try await Task.sleep(for: .milliseconds(650)) // event batching interval is 500ms
        await index.flush()
        precondition(fixture.callCount == 1, "An overflow after the replay started a full rebuild")
        let frozen = try IndexCache.load(from: url).1
        precondition(frozen <= checkpoint + 1, "A live overflow advanced the replay checkpoint")
    }

    private static func verifyShareReplacement(in temporary: URL) throws {
        let share = NetworkShare(source: "//fixture/share", name: "share")
        let mount = temporary.appendingPathComponent("share")
        let unreadable = mount.appendingPathComponent("unreadable")
        try FileManager.default.createDirectory(at: unreadable, withIntermediateDirectories: true)
        try Data([1]).write(to: unreadable.appendingPathComponent("secret.txt"))
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: unreadable.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: unreadable.path) }
        var store = FileStore()
        let root = store.append(name: temporary.path, parent: FileStore.noParent, size: 0, mtime: 0, isDir: true, volID: 1)
        // The mount appeared over a directory already present in the local index,
        // before /Volumes reconciliation removed its obsolete local records.
        let localRoot = store.append(name: "share", parent: root, size: 0, mtime: 0, isDir: true, volID: 1)
        let localFile = store.append(name: "old-local.txt", parent: localRoot, size: 1, mtime: 1, isDir: false, volID: 1)
        let localFolder = store.append(name: "old-folder", parent: localRoot, size: 0, mtime: 0, isDir: true, volID: 1)
        let localNested = store.append(name: "nested.txt", parent: localFolder, size: 1, mtime: 1, isDir: false, volID: 1)
        let unrelated = store.append(name: "unrelated.txt", parent: root, size: 1, mtime: 1, isDir: false, volID: 1)
        let oldShare = store.append(name: "share", parent: root, size: 0, mtime: 0, isDir: true, volID: share.volID)
        let known = store.append(name: "known.txt", parent: oldShare, size: 1, mtime: 1, isDir: false, volID: share.volID)
        let partial = ParallelScanner.scan(root: mount.path, rules: .defaults, volID: share.volID, workers: 2)
        precondition(partial.count > 0 && !partial.scanCompleted, "Unreadable descendant fixture must produce a partial scan")
        precondition(!ShareIndexMutation.replace(share, at: mount.path, with: partial, in: &store))
        precondition(store.isLive(known) && store.liveCount(volID: share.volID) == 2)
        precondition(store.isLive(localRoot) && store.isLive(localFile) && store.isLive(localNested),
                     "Incomplete share scan removed the last-known local subtree")
        precondition(!ShareIndexMutation.replace(share, at: mount.path, with: FileStore(), in: &store))
        precondition(store.isLive(known) && store.isLive(localFile))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: unreadable.path)
        let complete = ParallelScanner.scan(root: mount.path, rules: .defaults, volID: share.volID, workers: 2)
        precondition(ShareIndexMutation.replace(share, at: mount.path, with: complete, in: &store))
        precondition(!store.isLive(known) && store.liveCount(volID: share.volID) == complete.count)
        let roots = store.childIDs(of: root).filter { store.name(of: $0) == "share" }
        precondition(roots.count == 1 && store.volID(of: roots[0]) == share.volID,
                     "Complete share scan left duplicate roots at the mount path")
        precondition(!store.isLive(localRoot) && !store.isLive(localFile) && !store.isLive(localFolder)
                     && !store.isLive(localNested) && store.isLive(unrelated),
                     "Complete share scan did not replace only its stale mount-path subtree")
    }

    private static func verifyExactSharePathIdentity() {
        let share = NetworkShare(source: "//fixture/unicode", name: "unicode")
        let composed = "caf\u{e9}", decomposed = "cafe\u{301}"
        precondition(composed == decomposed && !composed.utf8.elementsEqual(decomposed.utf8))
        var store = FileStore()
        let parent = store.append(name: "/fixture", parent: FileStore.noParent, size: 0, mtime: 0, isDir: true, volID: 1)
        let replaced = store.append(name: composed, parent: parent, size: 0, mtime: 0, isDir: true, volID: 1)
        let other = store.append(name: decomposed, parent: parent, size: 0, mtime: 0, isDir: true, volID: 1)
        let otherFile = store.append(name: "other.txt", parent: other, size: 1, mtime: 1, isDir: false, volID: 1)
        let mountPath = "/fixture/" + composed
        var wrongPath = FileStore()
        wrongPath.append(name: "/fixture/" + decomposed, parent: FileStore.noParent, size: 0, mtime: 0,
                         isDir: true, volID: share.volID)
        precondition(!ShareIndexMutation.replace(share, at: mountPath, with: wrongPath, in: &store),
                     "Canonically equivalent strings identified a different mount path")
        var complete = FileStore()
        complete.append(name: mountPath, parent: FileStore.noParent, size: 0, mtime: 0, isDir: true, volID: share.volID)
        precondition(ShareIndexMutation.replace(share, at: mountPath, with: complete, in: &store))
        precondition(!store.isLive(replaced) && store.isLive(other) && store.isLive(otherFile),
                     "Share replacement removed a distinct UTF-8 path")
        let roots = store.childIDs(of: parent)
        precondition(roots.count == 2 && roots.filter {
            store.name(of: $0).utf8.elementsEqual(composed.utf8)
        }.count == 1)
        var fresh = FileStore()
        let freshParent = fresh.append(name: "/fixture", parent: FileStore.noParent, size: 0, mtime: 0, isDir: true, volID: 1)
        fresh.append(name: decomposed, parent: freshParent, size: 0, mtime: 0, isDir: true, volID: 1)
        ShareIndexMutation.retainKnownShares([share], from: store, in: &fresh, isCancelled: { false })
        precondition(fresh.liveCount(volID: share.volID) == 1,
                     "A distinct canonical-equivalent local path suppressed offline share retention")
    }

    private static func verifyOfflineShareRetention() {
        let share = NetworkShare(source: "//fixture/offline", name: "offline")
        func localStore() -> (FileStore, UInt32) {
            var store = FileStore()
            let root = store.append(name: "/", parent: FileStore.noParent, size: 0, mtime: 0, isDir: true, volID: 1)
            let volumes = store.append(name: "Volumes", parent: root, size: 0, mtime: 0, isDir: true, volID: 1)
            return (store, volumes)
        }
        var (previous, parent) = localStore()
        let shareRoot = previous.append(name: "offline", parent: parent, size: 0, mtime: 0, isDir: true, volID: share.volID)
        previous.append(name: "known.txt", parent: shareRoot, size: 42, mtime: 123, isDir: false, volID: share.volID)
        let deleted = previous.append(name: "deleted.txt", parent: shareRoot, size: 1, mtime: 1, isDir: false, volID: share.volID)
        previous.markDeleted(deleted)
        var (replacement, _) = localStore()
        ShareIndexMutation.retainKnownShares([share], from: previous, in: &replacement, isCancelled: { false })
        let hits = QueryEngine().search(Query(text: "known.txt"), in: replacement)
        precondition(hits.count == 1 && replacement.path(of: hits[0]) == "/Volumes/offline/known.txt"
                     && replacement.size(of: hits[0]) == 42)
        precondition(replacement.liveCount(volID: share.volID) == 2)
        var (occupied, occupiedParent) = localStore()
        let local = occupied.append(name: "offline", parent: occupiedParent, size: 0, mtime: 0, isDir: true, volID: 1)
        occupied.append(name: "local.txt", parent: local, size: 1, mtime: 1, isDir: false, volID: 1)
        ShareIndexMutation.retainKnownShares([share], from: previous, in: &occupied, isCancelled: { false })
        precondition(occupied.liveCount(volID: share.volID) == 0, "Offline metadata displaced a new local volume")
        var (removed, _) = localStore()
        ShareIndexMutation.retainKnownShares([], from: previous, in: &removed, isCancelled: { false })
        precondition(removed.liveCount(volID: share.volID) == 0)
    }
}
