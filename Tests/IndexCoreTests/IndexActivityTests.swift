import Foundation
import Testing
@testable import IndexCore

private final class ActivityFixtureClock: @unchecked Sendable {
    private let lock = NSLock()
    private var tick: TimeInterval = 0
    func next() -> Date { lock.withLock { tick += 1; return Date(timeIntervalSince1970: tick) } }
}

@Test func activityJournalKeepsOrderedBoundedImmutableSnapshots() {
    let clock = ActivityFixtureClock()
    let journal = IndexActivityJournal(capacity: 3, clock: { clock.next() })
    for number in 1...3 { journal.record(.added, path: "/fixture/\(number)") }
    let old = journal.snapshot()
    for number in 4...7 { journal.record(.removed, path: "/fixture/\(number)") }
    let current = journal.snapshot()
    #expect(old.events.map(\.path) == ["/fixture/1", "/fixture/2", "/fixture/3"])
    #expect(current.events.map(\.path) == ["/fixture/5", "/fixture/6", "/fixture/7"])
    #expect(current.events.map(\.id) == [5, 6, 7])
    #expect(current.events.map(\.timestamp) == [5, 6, 7].map { Date(timeIntervalSince1970: Double($0)) })
    #expect(current.capacity == 3 && current.droppedEventCount == 4)
    journal.publishIndex(count: 42, roots: ["/fixture"])
    journal.clear()
    #expect(journal.snapshot().events.isEmpty)
    #expect(journal.snapshot().indexedCount == 42 && journal.snapshot().indexedRoots == ["/fixture"])
    journal.record(.added, path: "/fixture/new")
    #expect(journal.snapshot().events.first?.id == 8)
}

@Test func activityJournalRetiredScansCannotReportStaleProgressOrSuccess() {
    let journal = IndexActivityJournal(capacity: 8)
    let old = UUID(), current = UUID()
    journal.startScan(id: old, path: "/old")
    journal.scanProgress(id: old, count: 17)
    journal.finishScan(id: old, outcome: .scanCancelled)
    journal.startScan(id: current, path: "/current")
    journal.scanProgress(id: old, count: 99_999)
    journal.finishScan(id: old, outcome: .scanCompleted, count: 99_999)
    journal.scanProgress(id: current, count: 3)
    #expect(journal.snapshot().activeScans.map(\.observedCount) == [3])
    #expect(journal.snapshot().events.map(\.kind) == [.scanStarted, .scanCancelled, .scanStarted])
    journal.clear()
    #expect(journal.snapshot().activeScans.map(\.id) == [current])
    journal.finishScan(id: current, outcome: .scanCompleted, count: 3)
    #expect(journal.snapshot().activeScans.isEmpty)
    #expect(journal.snapshot().events.first?.count == 3)
}

@Test func activityFilterUsesRecordedPathsAndComponentBoundaries() {
    let journal = IndexActivityJournal()
    journal.record(.added, path: "/Volumes/share/first")
    journal.record(.removed, path: "/Volumes/share-other/file")
    journal.record(.cacheSaved, path: "/Volumes/share/index.idx")
    journal.record(.metadata, path: "/Volumes/share/café", detail: "Observed fixture metadata")
    let snapshot = journal.snapshot()
    #expect(snapshot.events(category: .files, root: "/Volumes/share").map(\.kind) == [.added, .metadata])
    #expect(snapshot.events(root: "/Volumes/share", containing: "CAFÉ").map(\.path) == ["/Volumes/share/café"])
    #expect(snapshot.events(root: "/").count == 4)
}

@Test func activityJournalConcurrentWritersKeepCapacityAndUniqueSequence() {
    let journal = IndexActivityJournal(capacity: 32)
    DispatchQueue.concurrentPerform(iterations: 4) { worker in
        for number in 0..<200 { journal.record(.added, path: "/\(worker)/\(number)") }
    }
    let snapshot = journal.snapshot()
    #expect(snapshot.events.count == 32 && snapshot.droppedEventCount == 768)
    #expect(Set(snapshot.events.map(\.id)).count == 32)
    #expect(snapshot.events.map(\.id) == Array(769...800).map(UInt64.init))
}

private func activityDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("activity-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

@Test func activityReconcileReportsRealRenameAsSeparateAddedAndRemovedEntries() throws {
    let directory = try activityDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let original = directory.appendingPathComponent("before.txt"), renamed = directory.appendingPathComponent("after.txt")
    try Data([1]).write(to: original)
    var store = ParallelScanner.scan(root: directory.path, rules: .defaults, volID: 1, workers: 2)
    try FileManager.default.moveItem(at: original, to: renamed)
    var observations: [ReconcileObservation] = []
    #expect(LiveMonitor.reconcile(directory: directory.path, in: &store, rules: .defaults, volID: 1,
                                  observe: { observations.append($0) }))
    #expect(observations.filter { $0.kind == .added }.map(\.path) == [renamed.path])
    #expect(observations.filter { $0.kind == .removed }.map(\.path) == [original.path])
    #expect(store.childID(named: "after.txt", under: store.rootID) != nil)
    #expect(store.childID(named: "before.txt", under: store.rootID) == nil)
}

@Test func activityMetadataObservationKeepsContentOnlyGateAndReportsExistingStat() throws {
    let directory = try activityDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("metadata.txt")
    try Data([1]).write(to: file)
    var store = ParallelScanner.scan(root: directory.path, rules: .defaults, volID: 1, workers: 2)
    _ = LiveMonitor.reconcile(directory: directory.path, in: &store, rules: .defaults, volID: 1)
    // Rewriting an existing inode does not advance its parent directory mtime.
    let handle = try FileHandle(forWritingTo: file)
    try handle.write(contentsOf: Data([1, 2, 3, 4]))
    try handle.close()
    var observations: [ReconcileObservation] = []
    #expect(!LiveMonitor.reconcile(directory: directory.path, in: &store, rules: .defaults, volID: 1,
                                   observe: { observations.append($0) }))
    #expect(observations.isEmpty)
    try Data([1]).write(to: directory.appendingPathComponent("trigger.txt"))
    _ = LiveMonitor.reconcile(directory: directory.path, in: &store, rules: .defaults, volID: 1,
                               observe: { observations.append($0) })
    let observation = try #require(observations.first { $0.kind == .metadata && $0.path == file.path })
    #expect(observation.priorSize == 1 && observation.size == 4)
    let journal = IndexActivityJournal()
    journal.recordObservation(observation)
    #expect(journal.snapshot().events.first?.metadata?.size == 4)
    #expect(journal.snapshot().events.first?.metadata?.priorSize == 1)
    let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
    #expect(observation.modificationTime == Int64((attributes[.modificationDate] as! Date).timeIntervalSince1970))
}

@Test func activityIncompleteReadReportsActualPOSIXFailureAndPreservesEntries() throws {
    let directory = try activityDirectory(), restricted = directory.appendingPathComponent("restricted")
    try FileManager.default.createDirectory(at: restricted, withIntermediateDirectories: true)
    try Data([1]).write(to: restricted.appendingPathComponent("retained.txt"))
    defer {
        chmod(restricted.path, 0o700)
        try? FileManager.default.removeItem(at: directory)
    }
    var store = ParallelScanner.scan(root: directory.path, rules: .defaults, volID: 1, workers: 2)
    #expect(chmod(restricted.path, 0) == 0)
    var observations: [ReconcileObservation] = []
    #expect(!LiveMonitor.reconcile(directory: restricted.path, in: &store, rules: .defaults, volID: 1,
                                   observe: { observations.append($0) }))
    let observation = try #require(observations.first { $0.kind == .incomplete })
    #expect(observation.path == restricted.path)
    #expect(observation.failure == NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES)).localizedDescription)
    let child = try #require(store.idForDirPath(restricted.path))
    #expect(store.childID(named: "retained.txt", under: child) != nil)
}
