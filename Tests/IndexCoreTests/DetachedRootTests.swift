import Foundation
import Testing
@testable import IndexCore

@Test func detachedNetworkRootsKeepThePrimaryRootAndSurviveCacheAndCompaction() throws {
    var store = FileStore()
    let root = store.append(name: "/Volumes", parent: FileStore.noParent, size: 0, mtime: 0, isDir: true, volID: 1)
    let local = store.append(name: "Enabled", parent: root, size: 0, mtime: 0, isDir: true, volID: 1)
    store.append(name: "local.txt", parent: local, size: 1, mtime: 1, isDir: false, volID: 1)
    var share = FileStore()
    let shareRoot = share.append(name: "/Users/fixture/Network", parent: FileStore.noParent,
                                 size: 17, mtime: 23, isDir: true, volID: 2)
    let child = share.append(name: "Nested", parent: shareRoot, size: 0, mtime: 0, isDir: true, volID: 2)
    share.append(name: "network.txt", parent: child, size: 42, mtime: 7, isDir: false, volID: 2)
    let mergedResult = store.merge(share, asChildOf: FileStore.noParent, volID: 2)
    let merged = try #require(mergedResult)
    #expect(store.rootID == root && store.size(of: merged) == 17 && store.mtime(of: merged) == 23)
    #expect(store.idForDirPath("/Volumes/Enabled") == local)
    #expect(store.idForDirPath("/Users/fixture/Network") == merged)
    #expect(store.idForDirPath("/Users/fixture/Network/Nested") != nil)
    #expect(store.idForDirPath("/Users/fixture") == nil)
    let compacted = try store.storageSnapshot().compacted()
    let adopted = store.adoptCompaction(compacted, expectedRevision: store.revision)
    #expect(adopted)
    #expect(store.rootID == root && store.idForDirPath("/Users/fixture/Network") == merged)
    var second = FileStore()
    second.append(name: "/Network/Second", parent: FileStore.noParent, size: 0, mtime: 0, isDir: true, volID: 3)
    let secondResult = store.merge(second, asChildOf: FileStore.noParent, volID: 3)
    let secondRoot = try #require(secondResult)
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("detached-roots-\(UUID().uuidString).idx")
    defer { try? FileManager.default.removeItem(at: url) }
    try IndexCache.save(store, to: url, lastEventID: 0, rulesFingerprint: 0)
    var cached = try IndexCache.load(from: url).0
    #expect(cached.rootID == root && cached.idForDirPath("/Volumes/Enabled") == local)
    #expect(cached.idForDirPath("/Users/fixture/Network") == merged && cached.idForDirPath("/Network/Second") == secondRoot)
    let hits = QueryEngine().search(Query(text: "network.txt"), in: cached)
    #expect(hits.count == 1 && cached.path(of: hits[0]) == "/Users/fixture/Network/Nested/network.txt")
    cached.markSubtreeDeleted(merged)
    #expect(cached.idForDirPath("/Users/fixture/Network") == nil && cached.idForDirPath("/Volumes/Enabled") == local)
    let pruned = try cached.storageSnapshot().compacted()
    let prunedAdopted = cached.adoptCompaction(pruned, expectedRevision: cached.revision)
    #expect(prunedAdopted)
    #expect(cached.idForDirPath("/Users/fixture/Network") == nil && cached.idForDirPath("/Network/Second") == secondRoot)
}
