import Testing
import Foundation
@testable import IndexCore

@Test func searchOnOneMillionRecordsIsFast() {
    var s = FileStore()
    let root = s.append(name: "/", parent: FileStore.noParent, size: 0, mtime: 0, isDir: true, volID: 1)
    for i in 0..<1_000_000 {
        _ = s.append(name: "file\(i).txt", parent: root, size: UInt64(i), mtime: Int64(i), isDir: false, volID: 1)
    }
    let engine = QueryEngine()
    let clock = ContinuousClock()
    var hits = 0
    let elapsed = clock.measure {
        hits = engine.search(Query(text: "file12345"), in: s).count
    }
    print("[perf] 1M-record name search: \(elapsed), hits=\(hits)")
    #expect(hits >= 1)            // "file12345" appears in file12345.txt and file123456.txt etc.
    // Ceiling is generous to accommodate debug builds (no optimizations).
    // Release build (`swift test -c release`) measures ~14 ms on Apple Silicon.
    // 5 s gives headroom for slow CI machines in debug mode while still catching
    // catastrophic regressions (unoptimized run was ~1.5 s on Apple Silicon).
    #expect(elapsed < .seconds(5))
}

// Manual whole-disk scan benchmark. Skipped unless SCAN_BENCH is set, because it
// walks the entire real filesystem (slow, environment-dependent). Run with:
//   SCAN_BENCH=1 swift test -c release --filter parallelScanWholeDiskBenchmark
@Test func parallelScanWholeDiskBenchmark() {
    guard ProcessInfo.processInfo.environment["SCAN_BENCH"] != nil else { return }
    let rules = ExcludeRules(
        names: [".git", "node_modules"],
        pathPrefixes: ["/private/var/folders", "/System/Volumes/Data",
                       "/System/Volumes/Preboot", "/System/Volumes/VM",
                       "/System/Volumes/Update", "/System/Volumes/xarts",
                       "/System/Volumes/iSCPreboot", "/System/Volumes/Hardware"],
        excludeHidden: false)
    let clock = ContinuousClock()
    var store = FileStore()
    let elapsed = clock.measure {
        store = ParallelScanner.scanWholeDisk(rules: rules)
    }
    print("[perf] parallel whole-disk scan: \(elapsed), records=\(store.count)")
    #expect(store.count > 100_000)
}

// Loads the real on-disk index cache and times searches against it (incl. the
// worst case: a single common letter matching millions). Skipped unless CACHE_BENCH
// points at an index.idx. Run with:
//   CACHE_BENCH="$HOME/Library/Application Support/Everything-Mac/index.idx" \
//     swift test -c release --filter searchRealCacheBenchmark
@Test func searchRealCacheBenchmark() throws {
    guard let path = ProcessInfo.processInfo.environment["CACHE_BENCH"] else { return }
    let loadClock = ContinuousClock()
    var store = FileStore()
    let loadElapsed = try loadClock.measure {
        store = try IndexCache.load(from: URL(fileURLWithPath: path)).0
    }
    print("[perf] cache load (incl. index rebuild): \(loadElapsed), records=\(store.count)")
    let engine = QueryEngine()
    for q in ["s", "st", "storybud", "rxpros"] {
        let clock = ContinuousClock()
        var hits = 0
        let e = clock.measure { hits = engine.search(Query(text: q), in: store).count }
        print("[perf]   search '\(q)': \(e), hits=\(hits)")
    }

    // Break down the WORST case the UI actually triggers: empty query (= all
    // records) then sort by each column, exactly as IndexActor.search does. This
    // is what lags when the user clicks a sort header with millions of rows shown.
    let clk = ContinuousClock()
    // New flow: search returns live-only ids (no separate isLive filter pass).
    var liveIDs: [UInt32] = []
    let searchE = clk.measure { liveIDs = engine.search(Query(text: ""), in: store) }
    print("[perf] empty search (live ids, incl. tombstone skip): \(searchE), n=\(liveIDs.count)")
    // A sort-only click reuses these ids — just this sortedPrefix runs again.
    for key in [QueryEngine.SortKey.name, .size, .mtime, .kind] {
        var top: [UInt32] = []
        let e = clk.measure { top = engine.sortedPrefix(liveIDs, by: key, ascending: true, limit: 5000, in: store) }
        print("[perf] sort-click re-sort by \(key) (limit 5000): \(e), got=\(top.count)")
    }
    var top: [UInt32] = []
    _ = clk.measure { top = engine.sortedPrefix(liveIDs, by: .name, ascending: true, limit: 5000, in: store) }
    let mapE = clk.measure {
        _ = top.map { id in
            FileRecord(id: id, name: store.name(of: id), path: store.path(of: id),
                       parent: store.parent(of: id), size: store.size(of: id),
                       mtime: store.mtime(of: id), isDir: store.isDir(of: id), volID: store.volID(of: id))
        }
    }
    print("[perf] map 5000 → FileRecord (incl. path build): \(mapE)")
    #expect(store.count > 100_000)
}
