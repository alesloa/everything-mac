import Foundation
import Testing
@testable import IndexCore

private func fixture() -> FileStore {
    var store = FileStore()
    let root = store.append(name: "/", parent: FileStore.noParent, size: 0, mtime: 0, isDir: true, volID: 1)
    let directory = store.append(name: "Docs", parent: root, size: 0, mtime: 100, isDir: true, volID: 1)
    store.append(name: "Résumé.pdf", parent: directory, size: 42, mtime: 123, isDir: false, volID: 1)
    store.append(name: "old.txt", parent: directory, size: 12, mtime: 321, isDir: false, volID: 1)
    return store
}
private func cacheURL() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("mapped-store-\(UUID().uuidString).idx")
}

@Test func mappedSnapshotsRetainBaseAndIsolateOverlayMutations() throws {
    let original = fixture(), url = cacheURL()
    defer { try? FileManager.default.removeItem(at: url) }
    try IndexCache.save(original, to: url, lastEventID: 7, rulesFingerprint: 9)
    var writer = try IndexCache.load(from: url).0
    let snapshot = writer.storageSnapshot(), base = writer.baseIdentity
    writer.markDeleted(3)
    let appended = writer.append(name: "new.txt", parent: 1, size: 888, mtime: 999, isDir: false, volID: 1)
    #expect(writer.baseIdentity == base)
    #expect(writer.baseCount == 4 && writer.overlayCount == 1)
    #expect(snapshot.count == 4 && snapshot.isLive(3))
    #expect(writer.count == 5 && !writer.isLive(3))
    #expect(writer.path(of: appended) == "/Docs/new.txt")
    #expect(writer.size(of: appended) == 888 && writer.mtime(of: appended) == 999)
    #expect(writer.liveCount(volID: 1) == 4)
    #expect(writer.childIDs(of: 1) == [2, 4])
    #expect(snapshot.name(of: 2) == "Résumé.pdf")
    #expect(QueryEngine().search(Query(text: "Résumé"), in: snapshot) == [2])
}

@Test func delayedCompactionRebasesAppendsAndDeletesWithoutChangingIDs() async throws {
    var writer = fixture()
    writer.markDeleted(3)
    writer.setReconcileMtime(1, 4321)
    let source = writer.storageSnapshot(), revision = source.revision
    let task = Task.detached { try source.compacted() }
    let added = writer.append(name: "while-packing.txt", parent: 1, size: 99, mtime: 7, isDir: false, volID: 1)
    writer.markDeleted(2)
    let adopted1 = writer.adoptCompaction(try await task.value, expectedRevision: revision)
    #expect(adopted1)
    #expect(writer.baseCount == 4 && writer.overlayCount == 1)
    #expect(writer.path(of: added) == "/Docs/while-packing.txt")
    #expect(!writer.isLive(2) && !writer.isLive(3) && writer.isLive(added))
    #expect(writer.deletedCount == 2)
    #expect(writer.childIDs(of: 1) == [added])
    #expect(writer.reconcileMtime(of: 1) == 4321)
    let old = source
    #expect(old.isLive(2) && !old.isLive(3) && old.count == 4)
    let before = writer.revision
    let second = try writer.storageSnapshot().compacted()
    let adopted2 = writer.adoptCompaction(second, expectedRevision: before)
    #expect(adopted2)
    #expect(writer.baseCount == 5 && writer.overlayCount == 0)
    #expect(writer.path(of: added) == "/Docs/while-packing.txt" && writer.deletedCount == 2)
}

@Test func compactionRejectsOtherStoreAndWrongRevision() throws {
    var writer = fixture()
    let foreign = try fixture().compacted()
    let adopted3 = writer.adoptCompaction(foreign, expectedRevision: writer.revision)
    #expect(!adopted3)
    let own = try writer.storageSnapshot().compacted()
    let adopted4 = writer.adoptCompaction(own, expectedRevision: writer.revision + 1)
    #expect(!adopted4)
}

@Test func mappedNetworkGraftsAndRecursiveDeletesRemainStableAfterReload() throws {
    var writer = fixture()
    let compacted = try writer.storageSnapshot().compacted()
    let adopted5 = writer.adoptCompaction(compacted, expectedRevision: writer.revision)
    #expect(adopted5)
    var share = FileStore()
    let root = share.append(name: "/Volumes/Shared", parent: FileStore.noParent, size: 0, mtime: 0, isDir: true, volID: 77)
    let child = share.append(name: "Nested", parent: root, size: 0, mtime: 0, isDir: true, volID: 77)
    share.append(name: "remote.md", parent: child, size: 3, mtime: 9, isDir: false, volID: 77)
    let merged = writer.merge(share, asChildOf: 0, volID: 77)
    let graft = try #require(merged)
    #expect(writer.path(of: graft + 2) == "/Shared/Nested/remote.md")
    let snapshot = writer.storageSnapshot()
    writer.markSubtreeDeleted(graft)
    #expect(writer.liveCount(volID: 77) == 0 && snapshot.liveCount(volID: 77) == 3)
    let url = cacheURL()
    defer { try? FileManager.default.removeItem(at: url) }
    try IndexCache.save(writer, to: url, lastEventID: 100, rulesFingerprint: 55)
    let (loaded, event, fingerprint) = try IndexCache.load(from: url)
    #expect(loaded.count == 7 && loaded.deletedCount == 3)
    #expect(loaded.path(of: graft + 2) == "/Shared/Nested/remote.md")
    #expect(loaded.volID(of: graft + 2) == 77)
    #expect(event == 100 && fingerprint == 55)
}

@Test func atomicCacheReplacementLeavesOldMappedSnapshotsReadable() throws {
    let url = cacheURL()
    defer { try? FileManager.default.removeItem(at: url) }
    var first = fixture()
    try IndexCache.save(first, to: url, lastEventID: 1, rulesFingerprint: 2)
    let old = try IndexCache.load(from: url).0.storageSnapshot()
    first.markDeleted(3)
    first.append(name: "replacement.dat", parent: 1, size: 1234, mtime: 5, isDir: false, volID: 1)
    try IndexCache.save(first, to: url, lastEventID: 3, rulesFingerprint: 4)
    let new = try IndexCache.load(from: url).0
    try FileManager.default.removeItem(at: url)
    #expect(old.count == 4 && old.isLive(3) && old.name(of: 3) == "old.txt")
    #expect(new.count == 5 && !new.isLive(3) && new.path(of: 4) == "/Docs/replacement.dat")
    #expect(QueryEngine().matches(Query(text: "rplcmnt", fuzzy: true), in: new).map(\.id) == [4])
}

@Test func legacyEMS1CacheRemainsMappedAndSearchable() throws {
    var data = fixture().serializedBinary()
    // Drop EMS2 mask column to reproduce the existing released cache format.
    data[3] = Character("1").asciiValue!
    data.removeLast(8 + 4 * MemoryLayout<UInt64>.stride)
    let loaded = try #require(FileStore(binary: data))
    #expect(loaded.baseCount == 4 && loaded.overlayCount == 0)
    #expect(loaded.nameMask(of: 2) == fixture().nameMask(of: 2))
    #expect(loaded.path(of: 2) == "/Docs/Résumé.pdf")
}

@Test func mappedCacheRejectsCorruptArrayLengthsParentsAndFlags() throws {
    let valid = fixture().serializedBinary()
    #expect(FileStore(binary: valid + Data([0])) == nil)
    for length in [0, 3, 4, 11, 20, valid.count - 1] {
        #expect(FileStore(binary: valid.prefix(length)) == nil)
    }
    var enormous = valid
    withUnsafeBytes(of: UInt64.max) { enormous.replaceSubrange(4..<12, with: $0) }
    #expect(FileStore(binary: enormous) == nil)
    // Locate fixed arrays without assuming name arena byte lengths.
    var cursor = 4, starts: [Int] = []
    for stride in [1, 4, 2, 4, 8, 8, 1, 4, 1, 8] {
        let count = valid.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: cursor, as: UInt64.self) }
        cursor += 8; starts.append(cursor); cursor += Int(count) * stride
    }
    var parentCycle = valid
    withUnsafeBytes(of: UInt32(2)) { parentCycle.replaceSubrange((starts[3] + 8)..<(starts[3] + 12), with: $0) }
    #expect(FileStore(binary: parentCycle) == nil)
    var badLive = valid; badLive[starts[8]] = 255
    #expect(FileStore(binary: badLive) == nil)
    var badFlag = valid; badFlag[starts[6]] = 255
    #expect(FileStore(binary: badFlag) == nil)
}

@Test func mappedBaseDerivedCacheInstallsOnlyCompleteValues() throws {
    let store = try fixture().compacted()
    let cancelled: Int? = store.cachedBaseValue(key: "test") { nil }
    #expect(cancelled == nil)
    let complete: Int? = store.cachedBaseValue(key: "test") { 42 }
    let reused: Int? = store.cachedBaseValue(key: "test") { 99 }
    #expect(complete == 42 && reused == 42)
}

@Test func clonedMappingSurvivesSourceTruncationWhenFilesystemSupportsClones() throws {
    let url = cacheURL()
    defer { try? FileManager.default.removeItem(at: url) }
    try IndexCache.save(fixture(), to: url, lastEventID: 1, rulesFingerprint: 2)
    let bytes = try StoreBytes(file: url)
    // Non-APFS filesystems fall back to the documented atomic replacement mode.
    guard bytes.isIsolatedMapping else { return }
    let mapped = try #require(FileStore(storage: bytes, offset: 20))
    let handle = try FileHandle(forWritingTo: url)
    try handle.truncate(atOffset: 0)
    try handle.close()
    #expect(mapped.name(of: 2) == "Résumé.pdf" && mapped.size(of: 2) == 42)
    #expect(mapped.path(of: 3) == "/Docs/old.txt")
}

@Test func olderCompactionCannotResurrectDeletionsPersistedByANewerBase() throws {
    var writer = fixture()
    let old = try writer.storageSnapshot().compacted()
    writer.markDeleted(3)
    let newer = try writer.storageSnapshot().compacted()
    let accepted = writer.adoptCompaction(newer, expectedRevision: newer.revision)
    let rejected = writer.adoptCompaction(old, expectedRevision: old.revision)
    #expect(accepted && !rejected)
    #expect(!writer.isLive(3) && writer.deletedCount == 1)
}
