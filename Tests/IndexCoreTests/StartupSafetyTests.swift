import Foundation
import Darwin
import Testing
@testable import IndexCore

private final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var changes: [LiveMonitor.FSChange] = []
    func append(_ value: [LiveMonitor.FSChange]) { lock.withLock { changes.append(contentsOf: value) } }
    func contains(_ path: String) -> Bool {
        // Foundation's temporary path uses /var; FSEvents reports /private/var.
        let expected = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        return lock.withLock {
            changes.contains {
                let delivered = URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path
                return delivered == expected || delivered.hasPrefix(expected + "/")
            }
        }
    }
    func clear() { lock.withLock { changes.removeAll() } }
    var count: Int { lock.withLock { changes.count } }
}

private final class CaptureToken: Sendable {}

private func safetyDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("startup-safety-\(UUID().uuidString)").resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func generateEvent(in directory: URL) throws {
    try Data([1]).write(to: directory.appendingPathComponent(UUID().uuidString))
}

private func awaitEvent(_ log: EventLog, in directory: URL) async throws -> Bool {
    let clock = ContinuousClock(), deadline = clock.now.advanced(by: .seconds(5))
    while clock.now < deadline {
        try generateEvent(in: directory)
        try await Task.sleep(for: .milliseconds(50))
        if log.contains(directory.path) { return true }
    }
    return log.contains(directory.path)
}

@Suite(.serialized) struct StartupWatcherSafetyTests {
    @Test func releasingWatcherStopsDeliveryAndReleasesCallbackCapture() async throws {
        let directory = try safetyDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = EventLog()
        weak var dropped: LiveMonitor?
        weak var captured: CaptureToken?
        do {
            let token = CaptureToken()
            captured = token
            let monitor = LiveMonitor { [token] changes in
                log.append(changes)
                withExtendedLifetime(token) {}
            }
            dropped = monitor
            monitor.start(paths: [directory.path])
            let delivered = try await awaitEvent(log, in: directory)
            #expect(delivered)
        }
        #expect(dropped == nil)
        let clock = ContinuousClock(), deadline = clock.now.advanced(by: .seconds(2))
        while captured != nil && clock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(captured == nil)
        let prior = log.count
        for _ in 0..<8 {
            try generateEvent(in: directory)
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(log.count == prior)
    }

    @Test func restartingWatcherStopsThePreviousStream() async throws {
        let first = try safetyDirectory(), second = try safetyDirectory()
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }
        let log = EventLog(), monitor = LiveMonitor { log.append($0) }
        defer { monitor.stop() }
        monitor.start(paths: [first.path])
        let firstDelivered = try await awaitEvent(log, in: first)
        #expect(firstDelivered)
        monitor.start(paths: [second.path])
        let secondDelivered = try await awaitEvent(log, in: second)
        #expect(secondDelivered)
        log.clear()
        for _ in 0..<8 {
            try generateEvent(in: first)
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(!log.contains(first.path))
        monitor.stop()
        monitor.stop()
    }

    @Test func callbackCanStopItsOwnWatcher() async throws {
        final class Handle: @unchecked Sendable {
            private let lock = NSLock()
            private weak var value: LiveMonitor?
            func set(_ monitor: LiveMonitor) { lock.withLock { value = monitor } }
            func stop() { lock.withLock { value }?.stop() }
        }
        let directory = try safetyDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let handle = Handle(), finished = EventLog()
        let monitor = LiveMonitor { changes in
            handle.stop()
            finished.append(changes)
        }
        handle.set(monitor)
        monitor.start(paths: [directory.path])
        let delivered = try await awaitEvent(finished, in: directory)
        #expect(delivered)
        monitor.stop()
    }

    @Test func concurrentWatcherRestartsAndStopsRemainUsable() async throws {
        let directory = try safetyDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = EventLog(), monitor = LiveMonitor { log.append($0) }
        DispatchQueue.concurrentPerform(iterations: 16) { iteration in
            monitor.start(paths: [directory.path])
            if iteration % 2 == 0 { monitor.stop() }
        }
        monitor.start(paths: [directory.path])
        let delivered = try await awaitEvent(log, in: directory)
        #expect(delivered)
        monitor.stop()
    }
}

@Test func concurrentMountSnapshotsRemainWellFormed() {
    final class Failures: @unchecked Sendable {
        private let lock = NSLock()
        private var failures = 0
        func add() { lock.withLock { failures += 1 } }
        var count: Int { lock.withLock { failures } }
    }
    let failures = Failures()
    DispatchQueue.concurrentPerform(iterations: 8) { _ in
        for _ in 0..<100 {
            let mounts = MountTable.mounts()
            if !mounts.contains(where: { $0.path == "/" }) ||
                mounts.contains(where: { !$0.path.hasPrefix("/") || $0.fsType.isEmpty }) {
                failures.add()
            }
        }
    }
    #expect(failures.count == 0)
}

@Test func startupCacheLoadRejectsUntrustedCountsBeforeIntegerConversion() throws {
    let directory = try safetyDirectory(), url = directory.appendingPathComponent("index.idx")
    defer { try? FileManager.default.removeItem(at: directory) }
    var store = FileStore()
    let root = store.append(name: "/", parent: FileStore.noParent, size: 0, mtime: 0, isDir: true, volID: 1)
    store.append(name: "report.pdf", parent: root, size: 42, mtime: 123, isDir: false, volID: 1)
    try IndexCache.save(store, to: url, lastEventID: 7, rulesFingerprint: 9)
    let valid = try Data(contentsOf: url)
    let loaded = try IndexCache.load(from: url)
    #expect(loaded.0.path(of: 1) == "/report.pdf" && loaded.1 == 7 && loaded.2 == 9)
    var cursor = 24
    for stride in [1, 4, 2, 4, 8, 8, 1, 4, 1, 8] {
        let originalCount = valid.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: cursor, as: UInt64.self) }
        var corrupt = valid
        withUnsafeBytes(of: UInt64.max) { corrupt.replaceSubrange(cursor..<(cursor + 8), with: $0) }
        try corrupt.write(to: url, options: .atomic)
        #expect(throws: (any Error).self) { try IndexCache.load(from: url) }
        cursor += 8 + Int(originalCount) * stride
    }
}

@Test func storageReviewUnreadableDirectoryKeepsLastKnownChildren() throws {
    let directory = try safetyDirectory()
    defer {
        chmod(directory.path, 0o700)
        try? FileManager.default.removeItem(at: directory)
    }
    try Data([1]).write(to: directory.appendingPathComponent("cached.txt"))
    var store = FileStore()
    try Scanner(rules: ExcludeRules()).scan(rootPath: directory.path, into: &store, volID: 1)
    let child = try #require(store.childID(named: "cached.txt", under: store.rootID))
    #expect(chmod(directory.path, 0) == 0)
    #expect(!LiveMonitor.reconcile(directory: directory.path, in: &store, rules: ExcludeRules(), volID: 1))
    #expect(store.isLive(child))
    #expect(store.reconcileMtime(of: store.rootID) == nil)
}

@Test func storageReviewDirectoryReplacedByFileDropsDescendantGhosts() throws {
    let directory = try safetyDirectory(), replaced = directory.appendingPathComponent("same")
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: replaced, withIntermediateDirectories: true)
    try Data([1]).write(to: replaced.appendingPathComponent("old.txt"))
    var store = FileStore()
    try Scanner(rules: ExcludeRules()).scan(rootPath: directory.path, into: &store, volID: 1)
    let priorDirectory = try #require(store.childID(named: "same", under: store.rootID))
    let priorFile = try #require(store.childID(named: "old.txt", under: priorDirectory))
    try FileManager.default.removeItem(at: replaced)
    try Data([2]).write(to: replaced)
    #expect(LiveMonitor.reconcile(directory: directory.path, in: &store, rules: ExcludeRules(), volID: 1))
    let replacement = try #require(store.childID(named: "same", under: store.rootID))
    #expect(!store.isDir(of: replacement))
    #expect(!store.isLive(priorDirectory) && !store.isLive(priorFile))
}

@Test func storageReviewFileReplacedByDirectoryIndexesItsContents() throws {
    let directory = try safetyDirectory(), replaced = directory.appendingPathComponent("same")
    defer { try? FileManager.default.removeItem(at: directory) }
    try Data([1]).write(to: replaced)
    var store = FileStore()
    try Scanner(rules: ExcludeRules()).scan(rootPath: directory.path, into: &store, volID: 1)
    let priorFile = try #require(store.childID(named: "same", under: store.rootID))
    try FileManager.default.removeItem(at: replaced)
    try FileManager.default.createDirectory(at: replaced, withIntermediateDirectories: true)
    try Data([2]).write(to: replaced.appendingPathComponent("new.txt"))
    #expect(LiveMonitor.reconcile(directory: directory.path, in: &store, rules: ExcludeRules(), volID: 1))
    let replacement = try #require(store.childID(named: "same", under: store.rootID))
    #expect(store.isDir(of: replacement) && !store.isLive(priorFile))
    #expect(store.childID(named: "new.txt", under: replacement) != nil)
}

@Test func storageReviewScopeLookupRejectsOutsidePrefixAndFileNodes() {
    var store = FileStore()
    let root = store.append(name: "/scoped/root", parent: FileStore.noParent, size: 0, mtime: 0, isDir: true, volID: 1)
    store.append(name: "-outside", parent: root, size: 0, mtime: 0, isDir: true, volID: 1)
    store.append(name: "file.txt", parent: root, size: 1, mtime: 0, isDir: false, volID: 1)
    #expect(store.idForDirPath("/scoped/root-outside") == nil)
    #expect(store.idForDirPath("/scoped/root/file.txt") == nil)
}

@Test func storageReviewMissingScanRootDoesNotProduceUsableTree() throws {
    let directory = try safetyDirectory(), missing = directory.appendingPathComponent("absent")
    defer { try? FileManager.default.removeItem(at: directory) }
    var serial = FileStore()
    #expect(throws: (any Error).self) {
        try Scanner(rules: ExcludeRules()).scan(rootPath: missing.path, into: &serial, volID: 1)
    }
    #expect(serial.count == 0)
    let parallel = ParallelScanner.scan(root: missing.path, rules: ExcludeRules(), volID: 2, workers: 2)
    #expect(parallel.count == 0 && parallel.rootID == FileStore.noParent)
}

@Test func storageReviewExclusionsRespectDirectoryComponentBoundaries() {
    let rules = ExcludeRules(pathPrefixes: ["/Volumes/share", "/tmp/private/"])
    #expect(rules.shouldExclude(name: "inside", path: "/Volumes/share/inside", isHidden: false))
    #expect(!rules.shouldExclude(name: "inside", path: "/Volumes/share-1/inside", isHidden: false))
    #expect(rules.shouldExclude(name: "private", path: "/tmp/private", isHidden: false))
}

private final class StorageScanBudget: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: Int
    init(_ remaining: Int) { self.remaining = remaining }
    func isCancelled() -> Bool { lock.withLock { remaining -= 1; return remaining <= 0 } }
}

@Test func storageReviewCancelledScanReturnsNoPartialTree() throws {
    let directory = try safetyDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    for i in 0..<16 {
        let nested = directory.appendingPathComponent("nested-\(i)")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data([1]).write(to: nested.appendingPathComponent("entry.txt"))
    }
    let budget = StorageScanBudget(10)
    let cancelled = ParallelScanner.scan(root: directory.path, rules: ExcludeRules(), volID: 1,
                                          workers: 2, isCancelled: { budget.isCancelled() })
    #expect(cancelled.count == 0 && cancelled.rootID == FileStore.noParent)
    let completed = ParallelScanner.scan(root: directory.path + "///", rules: ExcludeRules(), volID: 1, workers: 2)
    #expect(completed.scanCompleted && completed.count == 33)
    #expect(completed.name(of: completed.rootID) == directory.path)
}

@Test func storageReviewPartialScanIsReportedAndSymlinksAreNotDescended() throws {
    let directory = try safetyDirectory(), inaccessible = directory.appendingPathComponent("inaccessible")
    defer {
        chmod(inaccessible.path, 0o700)
        try? FileManager.default.removeItem(at: directory)
    }
    try FileManager.default.createDirectory(at: inaccessible, withIntermediateDirectories: true)
    try Data([1]).write(to: inaccessible.appendingPathComponent("hidden.txt"))
    try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("loop"), withDestinationURL: directory)
    #expect(chmod(inaccessible.path, 0) == 0)
    let partial = ParallelScanner.scan(root: directory.path, rules: ExcludeRules(), volID: 2, workers: 2)
    #expect(partial.count == 3 && !partial.scanCompleted)
    let loop = try #require(partial.childID(named: "loop", under: partial.rootID))
    #expect(!partial.isDir(of: loop))
    let inaccessibleRoot = ParallelScanner.scan(root: inaccessible.path, rules: ExcludeRules(), volID: 2, workers: 2)
    #expect(inaccessibleRoot.count == 0)
}

@Test func storageReviewDirectorySymlinkReplacementDoesNotIndexExternalTarget() throws {
    let directory = try safetyDirectory(), outside = try safetyDirectory()
    let replaced = directory.appendingPathComponent("same")
    defer {
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.removeItem(at: outside)
    }
    try FileManager.default.createDirectory(at: replaced, withIntermediateDirectories: true)
    try Data([1]).write(to: replaced.appendingPathComponent("old.txt"))
    try Data([2]).write(to: outside.appendingPathComponent("external.txt"))
    var store = FileStore()
    try Scanner(rules: ExcludeRules()).scan(rootPath: directory.path, into: &store, volID: 1)
    try FileManager.default.removeItem(at: replaced)
    try FileManager.default.createSymbolicLink(at: replaced, withDestinationURL: outside)
    // A descendant event can arrive before the parent's type-replacement event.
    LiveMonitor.reconcile(directory: replaced.path, in: &store, rules: ExcludeRules(), volID: 1)
    #expect(!(0..<store.count).contains { store.name(of: UInt32($0)) == "external.txt" })
    LiveMonitor.reconcile(directory: directory.path, in: &store, rules: ExcludeRules(), volID: 1)
    let current = try #require(store.childID(named: "same", under: store.rootID))
    #expect(!store.isDir(of: current))
    #expect(store.childIDs(of: current).isEmpty)
}

@Test func storageReviewAncestorSymlinkReplacementDoesNotIndexExternalTarget() throws {
    let directory = try safetyDirectory(), outside = try safetyDirectory()
    let replaced = directory.appendingPathComponent("same"), nested = replaced.appendingPathComponent("nested")
    defer {
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.removeItem(at: outside)
    }
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    try Data([1]).write(to: nested.appendingPathComponent("old.txt"))
    let external = outside.appendingPathComponent("nested")
    try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
    try Data([2]).write(to: external.appendingPathComponent("external.txt"))
    var store = FileStore()
    try Scanner(rules: ExcludeRules()).scan(rootPath: directory.path, into: &store, volID: 1)
    try FileManager.default.removeItem(at: replaced)
    try FileManager.default.createSymbolicLink(at: replaced, withDestinationURL: outside)
    // O_NOFOLLOW on just "nested" does not reject the replaced "same" ancestor.
    LiveMonitor.reconcile(directory: nested.path, in: &store, rules: ExcludeRules(), volID: 1)
    #expect(!(0..<store.count).contains { store.isLive(UInt32($0)) && store.name(of: UInt32($0)) == "external.txt" })
}

@Test func storageReviewIncompleteNewSubtreeRetriesWithoutDuplicateChildren() throws {
    let directory = try safetyDirectory(), added = directory.appendingPathComponent("new")
    defer {
        chmod(added.path, 0o700)
        try? FileManager.default.removeItem(at: directory)
    }
    var store = FileStore()
    try Scanner(rules: ExcludeRules()).scan(rootPath: directory.path, into: &store, volID: 1)
    try FileManager.default.createDirectory(at: added, withIntermediateDirectories: true)
    try Data([1]).write(to: added.appendingPathComponent("child.txt"))
    #expect(chmod(added.path, 0) == 0)
    #expect(LiveMonitor.reconcile(directory: directory.path, in: &store, rules: ExcludeRules(), volID: 1))
    let subtree = try #require(store.childID(named: "new", under: store.rootID))
    #expect(store.childIDs(of: subtree).isEmpty)
    #expect(chmod(added.path, 0o700) == 0)
    #expect(LiveMonitor.reconcile(directory: directory.path, in: &store, rules: ExcludeRules(), volID: 1))
    #expect(store.childIDs(of: subtree).count == 1)
    #expect(store.childID(named: "child.txt", under: subtree) != nil)
    let count = store.count
    #expect(!LiveMonitor.reconcile(directory: directory.path, in: &store, rules: ExcludeRules(), volID: 1))
    #expect(store.count == count)
}

@Test func storageReviewDeepPartialSubtreeRetriesOnlyMissingChildren() throws {
    let directory = try safetyDirectory(), added = directory.appendingPathComponent("new")
    let blocked = added.appendingPathComponent("blocked")
    defer {
        chmod(blocked.path, 0o700)
        try? FileManager.default.removeItem(at: directory)
    }
    var store = FileStore()
    try Scanner(rules: ExcludeRules()).scan(rootPath: directory.path, into: &store, volID: 1)
    try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
    try Data([1]).write(to: added.appendingPathComponent("present.txt"))
    try Data([2]).write(to: blocked.appendingPathComponent("missing.txt"))
    #expect(chmod(blocked.path, 0) == 0)
    LiveMonitor.reconcile(directory: directory.path, in: &store, rules: ExcludeRules(), volID: 1)
    let addedID = try #require(store.childID(named: "new", under: store.rootID))
    let presentID = try #require(store.childID(named: "present.txt", under: addedID))
    let blockedID = try #require(store.childID(named: "blocked", under: addedID))
    // Retry state must remain writer-owned across background compaction adoption.
    let packed = try store.storageSnapshot().compacted()
    let adopted = store.adoptCompaction(packed, expectedRevision: packed.revision)
    #expect(adopted)
    #expect(chmod(blocked.path, 0o700) == 0)
    #expect(LiveMonitor.reconcile(directory: directory.path, in: &store, rules: ExcludeRules(), volID: 1))
    #expect(store.childID(named: "present.txt", under: addedID) == presentID)
    #expect(store.childIDs(of: addedID).count == 2)
    #expect(store.childID(named: "missing.txt", under: blockedID) != nil)
}

@Test func storageReviewCacheFIFOIsRejectedWithoutWaitingForWriter() throws {
    let directory = try safetyDirectory(), fifo = directory.appendingPathComponent("index.idx")
    defer { try? FileManager.default.removeItem(at: directory) }
    #expect(mkfifo(fifo.path, 0o600) == 0)
    let finished = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
        _ = try? IndexCache.load(from: fifo)
        finished.signal()
    }
    let completedBeforeWriter = finished.wait(timeout: .now() + .milliseconds(200)) == .success
    if !completedBeforeWriter {
        // Release the old blocking open for a bounded failing regression run.
        var writer: Int32 = -1
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while writer < 0 && ContinuousClock.now < deadline {
            writer = open(fifo.path, O_WRONLY | O_NONBLOCK)
            if writer < 0 { usleep(1_000) }
        }
        if writer >= 0 { close(writer) }
        #expect(finished.wait(timeout: .now() + .seconds(2)) == .success)
    }
    #expect(completedBeforeWriter)
}

@Test func storageReviewParallelPartialScanRetriesFromParentEvent() throws {
    let directory = try safetyDirectory(), blocked = directory.appendingPathComponent("blocked")
    defer {
        chmod(blocked.path, 0o700)
        try? FileManager.default.removeItem(at: directory)
    }
    try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
    try Data([1]).write(to: blocked.appendingPathComponent("child.txt"))
    #expect(chmod(blocked.path, 0) == 0)
    var store = ParallelScanner.scan(root: directory.path, rules: .defaults, volID: 1, workers: 2)
    let child = try #require(store.childID(named: "blocked", under: store.rootID))
    #expect(!store.scanCompleted && store.childIDs(of: child).isEmpty)
    #expect(chmod(blocked.path, 0o700) == 0)
    #expect(LiveMonitor.reconcile(directory: directory.path, in: &store, rules: .defaults, volID: 1))
    #expect(store.childID(named: "child.txt", under: child) != nil)
    #expect(store.childIDs(of: child).count == 1)
    #expect(!store.subtreeIsIncomplete(child) && !store.subtreeIsIncomplete(store.rootID))
}

@Test func storageReviewUnicodeDirectoryLookupPreservesExactUTF8Identity() {
    let composed = "\u{e9}", decomposed = "e\u{301}"
    #expect(composed == decomposed && !composed.utf8.elementsEqual(decomposed.utf8))
    var store = FileStore()
    let root = store.append(name: "/", parent: FileStore.noParent, size: 0, mtime: 0, isDir: true, volID: 1)
    let first = store.append(name: composed, parent: root, size: 0, mtime: 0, isDir: true, volID: 1)
    let second = store.append(name: decomposed, parent: root, size: 0, mtime: 0, isDir: true, volID: 1)
    #expect(store.childID(named: composed, under: root) == first)
    #expect(store.childID(named: decomposed, under: root) == second)
    #expect(store.idForDirPath("/" + composed) == first)
    #expect(store.idForDirPath("/" + decomposed) == second)
    var scoped = FileStore()
    scoped.append(name: "/scoped/" + composed, parent: FileStore.noParent, size: 0, mtime: 0, isDir: true, volID: 1)
    #expect(scoped.idForDirPath("/scoped/" + decomposed) == nil)
    #expect(scoped.idForDirPath("/scoped/" + decomposed + "/") == nil)
}

@Test func storageReviewUnicodeLiveDiffRemovesOnlyMissingExactName() throws {
    let directory = try safetyDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory.appendingPathComponent("\u{e9}"), withIntermediateDirectories: true)
    var observed = FileStore()
    try Scanner(rules: .defaults).scan(rootPath: directory.path, into: &observed, volID: 1)
    let actual = observed.name(of: try #require(observed.childIDs(of: observed.rootID).first))
    let missing = actual.utf8.elementsEqual("\u{e9}".utf8) ? "e\u{301}" : "\u{e9}"
    #expect(actual == missing && !actual.utf8.elementsEqual(missing.utf8))
    var store = FileStore()
    let root = store.append(name: directory.path, parent: FileStore.noParent, size: 0, mtime: 0, isDir: true, volID: 1)
    let present = store.append(name: actual, parent: root, size: 0, mtime: 0, isDir: true, volID: 1)
    let absent = store.append(name: missing, parent: root, size: 0, mtime: 0, isDir: false, volID: 1)
    #expect(LiveMonitor.reconcile(directory: directory.path, in: &store, rules: .defaults, volID: 1))
    #expect(store.isLive(present) && !store.isLive(absent))
}

@Test func storageReviewUnicodeSubtreeDedupDoesNotSkipDistinctBytePath() {
    var store = FileStore()
    let root = store.append(name: "/unicode-synthetic-fixture", parent: FileStore.noParent, size: 0, mtime: 0, isDir: true, volID: 99)
    let composed = store.append(name: "\u{e9}", parent: root, size: 0, mtime: 0, isDir: true, volID: 1)
    let decomposed = store.append(name: "e\u{301}", parent: root, size: 0, mtime: 0, isDir: true, volID: 1)
    var indexed: Set<String> = [store.path(of: composed)], pending: [String] = []
    // Root volume differs, so reconciliation exits before any filesystem access.
    LiveMonitor.reconcileLevel(directory: store.path(of: root), in: &store, rules: .defaults, volID: 1,
                               descend: true, newlyIndexedDirs: &indexed, pushChildDirsTo: &pending)
    #expect(pending.count == 1)
    #expect(pending.first?.utf8.elementsEqual(store.path(of: decomposed).utf8) == true)
}

@Test func storageReviewUnicodeForeignNameDoesNotHideDistinctLocalEntry() throws {
    let directory = try safetyDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory.appendingPathComponent("\u{e9}"), withIntermediateDirectories: true)
    var observed = FileStore()
    try Scanner(rules: .defaults).scan(rootPath: directory.path, into: &observed, volID: 1)
    let actual = observed.name(of: try #require(observed.childIDs(of: observed.rootID).first))
    let foreignName = actual.utf8.elementsEqual("\u{e9}".utf8) ? "e\u{301}" : "\u{e9}"
    var store = FileStore()
    let root = store.append(name: directory.path, parent: FileStore.noParent, size: 0, mtime: 0, isDir: true, volID: 1)
    let foreign = store.append(name: foreignName, parent: root, size: 0, mtime: 0, isDir: true, volID: 99)
    #expect(LiveMonitor.reconcile(directory: directory.path, in: &store, rules: .defaults, volID: 1))
    let local = try #require(store.childID(named: actual, under: root))
    #expect(store.volID(of: local) == 1 && store.isLive(foreign))
    #expect(store.childIDs(of: root).count == 2)
}
