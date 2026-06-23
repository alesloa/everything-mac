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

    // TEMP DIAGNOSTIC — remove before commit. Appends a line to /tmp/ec-fsdebug.log.
    nonisolated static func dlog(_ s: String) {
        guard let data = (s + "\n").data(using: .utf8) else { return }
        let url = URL(fileURLWithPath: "/tmp/ec-fsdebug.log")
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(data); try? h.close()
        } else {
            try? data.write(to: url)
        }
    }

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
        // Copy + mutate one field rather than re-listing every field by hand, so a
        // future ExcludeRules property is carried through automatically instead of
        // being silently dropped back to its default on the scan path.
        var effective = rules
        // Also skip network (non-local) mounts. Crawling an SMB/NFS share does one
        // network round-trip per lstat and an smbfs readdir blocks in uninterruptible
        // I/O — a single mounted share with millions of files hangs the whole scan.
        effective.pathPrefixes += firmlinkBackDoors + Self.nonLocalMountPaths()
        return effective
    }

    // Mount points of non-local (network) filesystems — SMB/NFS/AFP/WebDAV shares.
    // getmntinfo with MNT_NOWAIT reads the kernel's cached mount table and never
    // itself touches the network (MNT_WAIT would refresh stats and could block on a
    // stalled mount). MNT_LOCAL is set only for filesystems stored on local media.
    static func nonLocalMountPaths() -> [String] {
        var mntbuf: UnsafeMutablePointer<statfs>? = nil
        let count = getmntinfo(&mntbuf, MNT_NOWAIT)
        guard count > 0, let mntbuf else { return [] }
        var out: [String] = []
        for i in 0..<Int(count) {
            var fs = mntbuf[i]
            if (fs.f_flags & UInt32(MNT_LOCAL)) != 0 { continue } // local → index it
            let path = withUnsafePointer(to: &fs.f_mntonname) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            out.append(path)
        }
        return out
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
        let fingerprint = effectiveRules().fingerprint()
        // Use the cache only if it was built with the SAME exclusion rules now in
        // effect. Otherwise (e.g. an upgrade that turned dev-folder skipping on, or a
        // changed exclude list) the cached index disagrees with the active rules and
        // would keep serving folders that should now be hidden — rebuild instead.
        if let (loaded, evid, savedFingerprint) = try? IndexCache.load(from: url),
           loaded.count > 0, savedFingerprint == fingerprint {
            store = loaded
            lastEventID = evid
        } else {
            await rescanAll()
            lastEventID = FSEventsGetCurrentEventId()
            try? IndexCache.save(store, to: url, lastEventID: lastEventID, rulesFingerprint: fingerprint)
        }
        startMonitor()
    }

    private func startMonitor() {
        let m = LiveMonitor(onChanged: { [weak self] changes in
            guard let self else { return }
            Task { await self.applyChanges(changes) }
        })
        let wp = watchPaths()
        Self.dlog("startMonitor paths=\(wp) sinceWhen=\(lastEventID)")
        m.start(paths: wp, sinceWhen: FSEventStreamEventId(lastEventID))
        monitor = m
    }

    // An FSEvents stream rooted at "/" only covers the boot volume's hierarchy
    // (System + firmlinked Data). Other volumes mount under /Volumes on separate
    // devices and need their own watch roots, or live updates never fire for files
    // on them (e.g. an external/secondary disk). The boot volume's own entry in
    // /Volumes is a symlink — lstat skips it (S_IFLNK), so it isn't double-watched.
    private func watchPaths() -> [String] {
        // "/" is the sealed, read-only System volume; the writable Data volume — home,
        // /Users, /private, /Applications — is mounted at /System/Volumes/Data, and its
        // live changes are NOT delivered through a "/" watch (only via slow coalesced
        // rescans every few minutes, which is why new files in the home folder took
        // minutes to appear). Watch the Data volume directly so home-folder changes are
        // instant; applyChanges maps the /System/Volumes/Data prefix back to canonical.
        var paths = ["/", "/System/Volumes/Data"]
        // Network shares are skipped (checked BEFORE lstat — stat'ing a network mount
        // point itself can block), matching the scan, which doesn't index them.
        let networkMounts = Set(Self.nonLocalMountPaths())
        if let vols = try? FileManager.default.contentsOfDirectory(atPath: "/Volumes") {
            for v in vols.sorted() {
                let p = "/Volumes/" + v
                if networkMounts.contains(p) { continue }
                var st = stat()
                if lstat(p, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR { paths.append(p) }
            }
        }
        return paths
    }

    // Apply FSEvents deltas, then notify the model to refresh visible results.
    //
    // The stream is directory-level (see LiveMonitor.start): each reported path IS the
    // directory whose contents changed, so reconcile it directly — no parent
    // derivation. Paths are deduped and processed ancestors-first (lexicographic sort)
    // so a brand-new subtree indexed by one event isn't re-listed by a sibling event
    // in the same batch. MustScanSubDirs (coalescing overflow) re-diffs the whole
    // subtree. Only an actual add/remove triggers a re-search: ambient file
    // modifications change nothing and must not peg the CPU.
    func applyChanges(_ changes: [LiveMonitor.FSChange]) {
        // Map firmlink-aliased Data-volume paths (/System/Volumes/Data/...) back to
        // canonical "/..." so home-folder changes resolve against the index.
        let changes = changes.map {
            LiveMonitor.FSChange(path: LiveMonitor.canonicalEventPath($0.path),
                                 mustScanSubtree: $0.mustScanSubtree)
        }
        Self.dlog("batch n=\(changes.count)")
        for c in changes where c.path.contains("/Users") || c.mustScanSubtree {
            Self.dlog("  recv \(c.path) mustScan=\(c.mustScanSubtree) idFound=\(store.idForDirPath(c.path) != nil)")
        }
        var deep = Set<String>()
        for c in changes where c.mustScanSubtree { deep.insert(c.path) }
        let dirs = Set(changes.map { $0.path }).sorted()
        var newlyIndexed = Set<String>()
        var changed = false
        for d in dirs {
            if newlyIndexed.contains(where: { d == $0 || d.hasPrefix($0 + "/") }) { continue }
            let didChange = deep.contains(d)
                ? LiveMonitor.reconcileTree(directory: d, in: &store, rules: rules, volID: 1, newlyIndexedDirs: &newlyIndexed)
                : LiveMonitor.reconcile(directory: d, in: &store, rules: rules, volID: 1, newlyIndexedDirs: &newlyIndexed)
            if didChange { changed = true }
        }
        guard changed else { return }
        Self.dlog("  -> CHANGED, onLiveChange fired")
        cachedQueryKey = nil
        onLiveChange?()
    }

    // Safety net for iCloud "Desktop & Documents" (FileProvider) folders: macOS does
    // NOT deliver FSEvents for these the way it does ordinary folders, so files
    // created/deleted on the Desktop or in Documents/Downloads can lag minutes behind
    // (only coarse coalesced rescans eventually catch them). Periodically re-read just
    // these few user-facing folders directly. Cost is trivial — each unchanged folder
    // is gated to a single lstat by reconcile's mtime check; a folder only gets a full
    // readdir when its contents actually changed. Shallow (one level) on purpose:
    // reconcileTree would lstat the entire subtree every tick, which is not free.
    func sweepUserFolders() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let targets = ["Desktop", "Documents", "Downloads"].map { home + "/" + $0 }
        var newlyIndexed = Set<String>()
        var changed = false
        for dir in targets {
            if LiveMonitor.reconcile(directory: dir, in: &store, rules: rules, volID: 1,
                                     newlyIndexedDirs: &newlyIndexed) { changed = true }
        }
        guard changed else { return }
        cachedQueryKey = nil
        onLiveChange?()
    }

    // Persist the current store + a fresh event id so the next launch can replay
    // only the changes that happened after this point.
    func flush() {
        lastEventID = FSEventsGetCurrentEventId()
        try? IndexCache.save(store, to: Self.cacheURL(), lastEventID: lastEventID,
                             rulesFingerprint: effectiveRules().fingerprint())
    }
}
