import Testing
import Foundation
@testable import IndexCore

@Test func cacheRoundTrips() throws {
    var store = FileStore()
    let root = store.append(name: "/", parent: FileStore.noParent, size: 0, mtime: 0, isDir: true, volID: 1)
    _ = store.append(name: "a.txt", parent: root, size: 42, mtime: 7, isDir: false, volID: 1)

    let url = FileManager.default.temporaryDirectory.appendingPathComponent("ec-\(UUID().uuidString).idx")
    defer { try? FileManager.default.removeItem(at: url) }

    try IndexCache.save(store, to: url, lastEventID: 99, rulesFingerprint: 0xABCD)
    let (loaded, eventID, fingerprint) = try IndexCache.load(from: url)

    #expect(loaded.count == store.count)
    #expect(loaded.name(of: 1) == "a.txt")
    #expect(loaded.size(of: 1) == 42)
    #expect(eventID == 99)
    #expect(fingerprint == 0xABCD)
}

/// A cache written with one rules fingerprint must report that fingerprint on load,
/// so the actor can rebuild when the active exclusion rules no longer match it.
@Test func cachePreservesRulesFingerprint() throws {
    var store = FileStore()
    _ = store.append(name: "/", parent: FileStore.noParent, size: 0, mtime: 0, isDir: true, volID: 1)
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("ec-\(UUID().uuidString).idx")
    defer { try? FileManager.default.removeItem(at: url) }

    let fp = ExcludeRules.defaults.fingerprint()
    try IndexCache.save(store, to: url, lastEventID: 1, rulesFingerprint: fp)
    let (_, _, loadedFP) = try IndexCache.load(from: url)
    #expect(loadedFP == fp)
    // A different ruleset fingerprints differently, so the mismatch is detectable.
    let other = ExcludeRules(names: [], pathPrefixes: [], excludeHidden: true)
    #expect(other.fingerprint() != fp)
}

/// Round-trip a Scanner-built store over a small temp tree. Asserts that
/// path(of:) for a known file survives the round-trip identical, proving all
/// parallel arrays (including `live` tombstones) serialize correctly.
@Test func cacheRoundTripsScannedStore() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("ec-cache-\(UUID().uuidString)")
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    try fm.createDirectory(at: root.appendingPathComponent("sub"), withIntermediateDirectories: true)
    try "hello".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
    try "world".write(to: root.appendingPathComponent("sub/b.txt"), atomically: true, encoding: .utf8)

    var store = FileStore()
    let scanner = Scanner(rules: ExcludeRules())
    try scanner.scan(rootPath: root.path, into: &store, volID: 1)

    // Tombstone one entry to verify `live` survives round-trip.
    // Find "a.txt" and delete it.
    var aTxtID: UInt32? = nil
    for i in 0..<UInt32(store.count) {
        if store.name(of: i) == "a.txt" { aTxtID = i; break }
    }
    let deletedID = try #require(aTxtID, "a.txt must be in the index")
    store.markDeleted(deletedID)

    // Find "b.txt" to assert its path survives.
    var bTxtID: UInt32? = nil
    for i in 0..<UInt32(store.count) {
        if store.name(of: i) == "b.txt" { bTxtID = i; break }
    }
    let bID = try #require(bTxtID, "b.txt must be in the index")
    let expectedPath = store.path(of: bID)

    let url = fm.temporaryDirectory.appendingPathComponent("ec-\(UUID().uuidString).idx")
    defer { try? fm.removeItem(at: url) }

    try IndexCache.save(store, to: url, lastEventID: 1234, rulesFingerprint: 7)
    let (loaded, eventID, _) = try IndexCache.load(from: url)

    #expect(loaded.count == store.count)
    #expect(eventID == 1234)
    // path(of:) for b.txt must be identical after round-trip.
    #expect(loaded.path(of: bID) == expectedPath)
    // Tombstone must survive: a.txt should not be live.
    #expect(!loaded.isLive(deletedID))
    // b.txt must still be live.
    #expect(loaded.isLive(bID))
}
