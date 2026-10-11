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
