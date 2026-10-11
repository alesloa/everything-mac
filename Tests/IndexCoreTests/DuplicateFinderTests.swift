import Testing
import Foundation
import Darwin
import CryptoKit
@testable import IndexCore

private struct DuplicateFixture {
    let root: URL
    init() throws {
        let resolved = try #require(realpath(FileManager.default.temporaryDirectory.path, nil))
        defer { free(resolved) }
        root = URL(fileURLWithPath: String(cString: resolved))
            .appendingPathComponent("duplicate-fixture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    func file(_ relative: String, _ bytes: Data) throws -> URL {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: url)
        return url
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
}

@Test func duplicateNamesAndActualSizesAreCandidatesWithoutContentClaims() async throws {
    let fixture = try DuplicateFixture(); defer { fixture.remove() }
    _ = try fixture.file("one/report.txt", Data("abc".utf8))
    _ = try fixture.file("two/report.txt", Data("xyz".utf8))
    _ = try fixture.file("three/other.txt", Data("abc".utf8))
    _ = try fixture.file("four/report.txt", Data("longer".utf8))
    let result = await DuplicateFinder().find(in: .folder(fixture.root.path), method: .nameAndSize)
    #expect(result.groups.count == 1)
    #expect(result.groups[0].files.count == 2)
    #expect(result.groups[0].size == 3)
    #expect(result.groups[0].sha256 == nil)
    #expect(result.hashedFiles == 0)
}

@Test func duplicateContentsUseChunkedSHA256AndPreserveUnicodeNestedPaths() async throws {
    let fixture = try DuplicateFixture(); defer { fixture.remove() }
    let data = Data((0..<4097).map { UInt8($0 % 251) })
    let first = try fixture.file("嵌套/é space.txt", data)
    let second = try fixture.file("second/renamed.bin", data)
    _ = try fixture.file("different.bin", Data(repeating: 4, count: data.count))
    _ = try fixture.file("unique-size.bin", Data([1]))
    let result = await DuplicateFinder().find(in: .folder(fixture.root.path),
        options: DuplicateOptions(workers: 2, chunkBytes: 97))
    #expect(result.groups.count == 1)
    #expect(Set(result.groups[0].files.map(\.path)) == Set([first.path, second.path]))
    #expect(result.groups[0].sha256 == SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
    #expect(result.inspectedFiles == 4)
    #expect(result.hashedFiles == 3)
}

@Test func duplicateQueryUsesEverySnapshotMatchAndRestatsStaleCachedSizes() async throws {
    let fixture = try DuplicateFixture(); defer { fixture.remove() }
    let first = try fixture.file("match-one", Data("abc".utf8))
    let second = try fixture.file("match-two", Data("abc".utf8))
    _ = try fixture.file("exclude", Data("abc".utf8))
    var store = FileStore()
    let root = store.append(name: fixture.root.path, parent: FileStore.noParent, size: 0, mtime: 0, isDir: true, volID: 1)
    store.append(name: first.lastPathComponent, parent: root, size: 1, mtime: 0, isDir: false, volID: 1)
    store.append(name: second.lastPathComponent, parent: root, size: 999, mtime: 0, isDir: false, volID: 1)
    store.append(name: "exclude", parent: root, size: 3, mtime: 0, isDir: false, volID: 1)
    let result = await DuplicateFinder().find(in: .query(snapshot: store, query: Query(text: "match")))
    #expect(result.groups.count == 1)
    #expect(result.groups[0].size == 3)
    #expect(result.inspectedFiles == 2)
    #expect(result.hashedFiles == 2)
    // Duplicate selection deduplicates actual path bytes rather than inflating a group.
    let selected = await DuplicateFinder().find(in: .paths([first.path, first.path, second.path]))
    #expect(selected.groups[0].files.count == 2)
}

@Test func duplicateEmptyFilesAreVerified() async throws {
    let fixture = try DuplicateFixture(); defer { fixture.remove() }
    _ = try fixture.file("empty-a", Data())
    _ = try fixture.file("empty-b", Data())
    let result = await DuplicateFinder().find(in: .folder(fixture.root.path))
    #expect(result.groups.count == 1)
    #expect(result.groups[0].sha256 == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
}

@Test func duplicateQuerySnapshotIsUncappedAndRemainsImmutableAfterPublication() async throws {
    let fixture = try DuplicateFixture(); defer { fixture.remove() }
    let first = try fixture.file("match-z-one", Data("abc".utf8))
    let second = try fixture.file("match-z-two", Data("abc".utf8))
    var store = FileStore()
    let root = store.append(name: fixture.root.path, parent: FileStore.noParent, size: 0, mtime: 0, isDir: true, volID: 1)
    for row in 0..<5001 {
        store.append(name: "match-a-\(row)", parent: root, size: 0, mtime: 0, isDir: true, volID: 1)
    }
    store.append(name: first.lastPathComponent, parent: root, size: 1, mtime: 0, isDir: false, volID: 1)
    store.append(name: second.lastPathComponent, parent: root, size: 999, mtime: 0, isDir: false, volID: 1)
    let index = SearchIndex(); index.publish(store)
    let snapshot = index.readSnapshot()
    let display = await index.search(Query(text: "match"), sort: .name, limit: 5000)
    #expect(!display.contains { $0.path == first.path || $0.path == second.path })
    index.publish(FileStore())
    let result = await DuplicateFinder().find(in: .query(snapshot: snapshot, query: Query(text: "match")))
    #expect(result.groups.count == 1)
    #expect(result.groups.first?.files.count == 2)
    #expect(result.inspectedFiles == 2)
}

@Test func duplicateQueryFolderScopeUsesExactAncestryAndMissingFolderDoesNotWiden() async throws {
    let fixture = try DuplicateFixture(); defer { fixture.remove() }
    _ = try fixture.file("chosen/one", Data("same".utf8))
    _ = try fixture.file("chosen/nested/two", Data("same".utf8))
    _ = try fixture.file("chosen-extra/three", Data("same".utf8))
    var store = FileStore()
    try Scanner(rules: ExcludeRules()).scan(rootPath: fixture.root.path, into: &store, volID: 1)
    let chosen = fixture.root.appendingPathComponent("chosen").path
    let result = await DuplicateFinder().find(in: .query(snapshot: store, query: Query(text: ""), folderPath: chosen))
    #expect(result.groups.first?.files.count == 2)
    #expect(result.inspectedFiles == 2)
    let missing = fixture.root.appendingPathComponent("missing").path
    let unavailable = await DuplicateFinder().find(in: .query(snapshot: store, query: Query(text: ""), folderPath: missing))
    #expect(unavailable.groups.isEmpty)
    #expect(unavailable.inspectedFiles == 0)
    #expect(unavailable.skipped.first?.path == missing)
}

@Test func duplicateSkipsSymlinkAncestorsDirectoriesSpecialAndUnavailableFiles() async throws {
    let fixture = try DuplicateFixture(); defer { fixture.remove() }
    let real = try fixture.file("real/one", Data("same".utf8))
    _ = try fixture.file("real/two", Data("same".utf8))
    let link = fixture.root.appendingPathComponent("link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real.deletingLastPathComponent())
    let fifo = fixture.root.appendingPathComponent("pipe")
    #expect(mkfifo(fifo.path, 0o600) == 0)
    let result = await DuplicateFinder().find(in: .folder(fixture.root.path))
    #expect(result.inspectedFiles == 2)
    #expect(result.groups.count == 1)
    #expect(result.skipped.contains { $0.path == link.path && $0.reason == .symbolicLink })
    #expect(result.skipped.contains { $0.path == fifo.path && $0.reason == .specialFile })
    let invalid = await DuplicateFinder().find(in: .paths([link.appendingPathComponent("one").path,
        fixture.root.appendingPathComponent("missing").path]))
    #expect(invalid.groups.isEmpty)
    #expect(invalid.inspectedFiles == 0)
    #expect(invalid.skipped.count == 2)
}

@Test func duplicateRejectsInPlaceChangesDuringHashing() async throws {
    let fixture = try DuplicateFixture(); defer { fixture.remove() }
    let first = try fixture.file("one", Data(repeating: 3, count: 8192))
    _ = try fixture.file("two", Data(repeating: 3, count: 8192))
    let mutation = DuplicateOnce()
    let result = await DuplicateFinder().find(in: .folder(fixture.root.path), method: .contents,
        options: DuplicateOptions(workers: 1, chunkBytes: 64), progress: { _ in }) { event in
            if case .chunkRead(let path, _) = event, path == first.path, mutation.claim() {
                try? Data(repeating: 9, count: 8192).write(to: first)
            }
        }
    #expect(result.groups.isEmpty)
    #expect(result.skipped.contains { $0.path == first.path && $0.reason == .changed })
}

@Test func duplicateRejectsReplacedPathsAfterHashingBeforePublishing() async throws {
    let fixture = try DuplicateFixture(); defer { fixture.remove() }
    let first = try fixture.file("one", Data("same".utf8))
    _ = try fixture.file("two", Data("same".utf8))
    let result = await DuplicateFinder().find(in: .folder(fixture.root.path), method: .contents,
        options: .init(), progress: { _ in }) { event in
            if case .beforeFinalValidation = event { try? Data("same".utf8).write(to: first, options: .atomic) }
        }
    #expect(result.groups.isEmpty)
    #expect(result.skipped.contains { $0.path == first.path && $0.reason == .changed })
}

@Test func duplicateCancellationStopsChunkReadsAndPublishesNoPartialGroups() async throws {
    let fixture = try DuplicateFixture(); defer { fixture.remove() }
    _ = try fixture.file("one", Data(repeating: 3, count: 8192))
    _ = try fixture.file("two", Data(repeating: 3, count: 8192))
    let gate = DuplicateReadGate()
    let worker = Task {
        await DuplicateFinder().find(in: .folder(fixture.root.path), method: .contents,
            options: DuplicateOptions(workers: 1, chunkBytes: 64), progress: { _ in }) { event in
                if case .chunkRead = event { gate.waitOnce() }
            }
    }
    while !gate.started { try await Task.sleep(for: .milliseconds(1)) }
    worker.cancel()
    gate.release()
    let result = await worker.value
    #expect(result.cancelled)
    #expect(result.groups.isEmpty)
    #expect(result.hashedFiles == 0)
}

@Test func duplicateFolderComparisonUsesActualRelativePathsAndVerifiedHashes() async throws {
    let fixture = try DuplicateFixture(); defer { fixture.remove() }
    _ = try fixture.file("left/nested/é.txt", Data("same".utf8))
    _ = try fixture.file("right/nested/é.txt", Data("same".utf8))
    _ = try fixture.file("left/changed", Data("aaaa".utf8))
    _ = try fixture.file("right/changed", Data("bbbb".utf8))
    _ = try fixture.file("left/size", Data("a".utf8))
    _ = try fixture.file("right/size", Data("ab".utf8))
    _ = try fixture.file("left/only-left", Data("same".utf8))
    _ = try fixture.file("right/only-right", Data("same".utf8))
    let result = await DuplicateFinder().compareFolders(fixture.root.appendingPathComponent("left").path,
        fixture.root.appendingPathComponent("right").path, options: DuplicateOptions(chunkBytes: 2))
    let byPath = Dictionary(uniqueKeysWithValues: result.entries.map { ($0.relativePath, $0) })
    #expect(result.entries.count == 5)
    #expect(byPath["nested/é.txt"]?.status == .sameContents)
    #expect(byPath["nested/é.txt"]?.sha256 != nil)
    #expect(byPath["changed"]?.status == .differentContents)
    #expect(byPath["size"]?.status == .differentContents)
    #expect(byPath["only-left"]?.status == .onlyLeft)
    #expect(byPath["only-right"]?.status == .onlyRight)
    #expect(result.hashedFiles == 4)
    #expect(result.inspectedFiles == 8)
}

@Test func duplicateFolderComparisonDoesNotInventAbsenceWhenFolderIsUnavailable() async throws {
    let fixture = try DuplicateFixture(); defer { fixture.remove() }
    _ = try fixture.file("left/present", Data("abc".utf8))
    let result = await DuplicateFinder().compareFolders(fixture.root.appendingPathComponent("left").path,
        fixture.root.appendingPathComponent("missing").path)
    #expect(result.entries.count == 1)
    #expect(result.entries[0].status == .unverified)
    #expect(result.skipped.count == 1)
}

@Test func duplicateFolderComparisonRechecksOppositeSideBeforeClaimingAbsence() async throws {
    let fixture = try DuplicateFixture(); defer { fixture.remove() }
    _ = try fixture.file("left/new-file", Data("abc".utf8))
    try FileManager.default.createDirectory(at: fixture.root.appendingPathComponent("right"), withIntermediateDirectories: true)
    let target = fixture.root.appendingPathComponent("right/new-file")
    let result = await DuplicateFinder().compareFolders(fixture.root.appendingPathComponent("left").path,
        fixture.root.appendingPathComponent("right").path, options: .init(), progress: { _ in }) { event in
            if case .beforeFinalValidation = event { try? Data("abc".utf8).write(to: target) }
        }
    #expect(result.entries.first?.status == .unverified)
    // The newly-created opposite path was not enumerated and is never presented as an observed path.
    #expect(result.entries.first?.rightPath == nil)
}

private final class DuplicateOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false
    func claim() -> Bool { lock.withLock { if claimed { return false }; claimed = true; return true } }
}

private final class DuplicateReadGate: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var reading = false
    var started: Bool { lock.withLock { reading } }
    func waitOnce() {
        let first = lock.withLock { if reading { return false }; reading = true; return true }
        if first { semaphore.wait() }
    }
    func release() { semaphore.signal() }
}
