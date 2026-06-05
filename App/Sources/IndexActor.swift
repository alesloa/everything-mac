import Foundation
import CoreServices
import IndexCore

// Serializes all store access. Mutations (scan, reconcile) and reads (search)
// never race because they run on this actor. The full-disk scan is COOPERATIVE:
// it yields every few thousand files so queued reads (search, totalCount) and
// progress callbacks interleave — the UI stays responsive and results stream in
// as the index builds instead of the actor blocking for the whole scan.
actor IndexActor {
    private var store = FileStore()
    private let engine = QueryEngine()
    private var rules = ExcludeRules.defaults

    // Matched ids for the last query (text + matchPath), so a sort-only change
    // re-sorts these instead of re-scanning millions of records. Invalidated
    // whenever the store mutates (rescan / live reconcile).
    private var cachedQueryKey: String?
    private var cachedIDs: [UInt32] = []

    private var monitor: LiveMonitor?
    private var lastEventID: UInt64 = UInt64(kFSEventStreamEventIdSinceNow)
    private var onLiveChange: (@Sendable () -> Void)?
    private var onProgress: (@Sendable (Int) -> Void)?

    init() {
        if let data = UserDefaults.standard.data(forKey: "excludeRules"),
           let r = try? JSONDecoder().decode(ExcludeRules.self, from: data) {
            rules = r
        }
    }

    var totalCount: Int { store.count }

    // ~/Library/Application Support/Everything-Mac/index.idx
    static func cacheURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Everything-Mac", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("index.idx")
    }

    func search(_ text: String, matchPath: Bool, sort: QueryEngine.SortKey, ascending: Bool) -> [FileRecord] {
        // Re-scan only when the query (not the sort) changed. engine.search already
        // excludes tombstoned ids, so no separate isLive filter pass is needed.
        let key = (matchPath ? "P\u{1}" : "N\u{1}") + text
        if key != cachedQueryKey {
            cachedIDs = engine.search(Query(text: text, matchPath: matchPath), in: store)
            cachedQueryKey = key
        }
        let sorted = engine.sortedPrefix(cachedIDs, by: sort, ascending: ascending, limit: 5000, in: store)
        return sorted.map { id in
            FileRecord(id: id, name: store.name(of: id), path: store.path(of: id),
                       parent: store.parent(of: id),
                       size: store.size(of: id), mtime: store.mtime(of: id),
                       isDir: store.isDir(of: id), volID: store.volID(of: id))
        }
    }

    func path(of id: UInt32) -> String { store.path(of: id) }

    func currentRules() -> ExcludeRules { rules }

    func setRules(_ r: ExcludeRules) {
        rules = r
        if let data = try? JSONEncoder().encode(r) {
            UserDefaults.standard.set(data, forKey: "excludeRules")
        }
    }

    // macOS presents one unified filesystem at "/": the read-only System volume
    // and the Data volume are joined via firmlinks, and external volumes mount
    // under /Volumes. A single recursive scan of "/" covers the entire disk and
    // every mounted volume exactly once — EXCEPT the Data volume is also visible
    // at /System/Volumes/Data (and siblings), which would duplicate every user
    // file. Exclude those firmlink back-doors. User rules are merged in.
    private func effectiveRules() -> ExcludeRules {
        let firmlinkBackDoors = [
            "/System/Volumes/Data",
            "/System/Volumes/Preboot",
            "/System/Volumes/VM",
            "/System/Volumes/Update",
            "/System/Volumes/xarts",
            "/System/Volumes/iSCPreboot",
            "/System/Volumes/Hardware",
        ]
        return ExcludeRules(names: rules.names,
                            pathPrefixes: rules.pathPrefixes + firmlinkBackDoors,
                            excludeHidden: rules.excludeHidden)
    }

    // Rebuild the whole index from "/". The walk runs OFF the actor on a pool of
    // worker threads (ParallelScanner), so the actor stays free to serve searches
    // against the existing index while the new one builds — no scan↔search
    // contention, all cores busy. The finished store is swapped in atomically.
    func rescanAll() async {
        let effective = effectiveRules()
        let prog = onProgress
        let newStore = await Task.detached(priority: .userInitiated) {
            ParallelScanner.scanWholeDisk(rules: effective) { count in prog?(count) }
        }.value
        store = newStore
        cachedQueryKey = nil
        onProgress?(store.count)
    }

    // Launch path: load the cache if present (FSEvents replays any changes made
    // while we were closed), otherwise do a full scan and save a fresh cache.
    // Then start the live monitor from the saved event id.
    func startUp(onLiveChange: @escaping @Sendable () -> Void,
                 onProgress: @escaping @Sendable (Int) -> Void) async {
        self.onLiveChange = onLiveChange
        self.onProgress = onProgress
        let url = Self.cacheURL()
        if let (loaded, evid) = try? IndexCache.load(from: url), loaded.count > 0 {
            store = loaded
            lastEventID = evid
        } else {
            await rescanAll()
            lastEventID = FSEventsGetCurrentEventId()
            try? IndexCache.save(store, to: url, lastEventID: lastEventID)
        }
        startMonitor()
    }

    private func startMonitor() {
        let m = LiveMonitor(onDirsChanged: { [weak self] dirs in
            guard let self else { return }
            Task { await self.applyChanges(dirs) }
        })
        m.start(paths: watchPaths(), sinceWhen: FSEventStreamEventId(lastEventID))
        monitor = m
    }

    // An FSEvents stream rooted at "/" only covers the boot volume's hierarchy
    // (System + firmlinked Data). Other volumes mount under /Volumes on separate
    // devices and need their own watch roots, or live updates never fire for files
    // on them (e.g. an external/secondary disk). The boot volume's own entry in
    // /Volumes is a symlink — lstat skips it (S_IFLNK), so it isn't double-watched.
    private func watchPaths() -> [String] {
        var paths = ["/"]
        if let vols = try? FileManager.default.contentsOfDirectory(atPath: "/Volumes") {
            for v in vols.sorted() {
                let p = "/Volumes/" + v
                var st = stat()
                if lstat(p, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR { paths.append(p) }
            }
        }
        return paths
    }

    // Apply FSEvents deltas: re-scan each changed directory level, diff against
    // the store, append new entries (recursing into new subtrees) and tombstone
    // removed ones, then notify the model to refresh visible results.
    func applyChanges(_ dirs: [String]) {
        for d in dirs {
            LiveMonitor.reconcile(directory: d, in: &store, rules: rules, volID: 1)
        }
        cachedQueryKey = nil
        onLiveChange?()
    }

    // Persist the current store + a fresh event id so the next launch can replay
    // only the changes that happened after this point.
    func flush() {
        lastEventID = FSEventsGetCurrentEventId()
        try? IndexCache.save(store, to: Self.cacheURL(), lastEventID: lastEventID)
    }
}
