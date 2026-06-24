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
    // Rules the LIVE path reconciles with — the user rules plus the firmlink back-door /
    // network-mount exclusions the scan applies via effectiveRules(). Without these, a
    // live reconcile that ever sees a "/System/Volumes/Data/…" path (the Data volume's
    // firmlink alias) would index it as a SECOND copy of a file already held at its
    // canonical "/…" path — the duplicate-folder bug. Refreshed whenever rules change.
    private var liveRules = ExcludeRules.defaults

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

    func search(_ text: String, matchPath: Bool, caseInsensitive: Bool = true, wholeWord: Bool = false,
                sort: QueryEngine.SortKey, ascending: Bool, limit: Int = 5000) -> [FileRecord] {
        // Re-scan only when the query (not the sort) changed. The key folds in every
        // flag that changes which ids match — matchPath, case sensitivity, whole-word —
        // so flipping any of them invalidates the cache. engine.search already excludes
        // tombstoned ids, so no separate isLive filter pass is needed.
        let key = (matchPath ? "P" : "N") + (caseInsensitive ? "i" : "s") + (wholeWord ? "w" : "x") + "\u{1}" + text
        if key != cachedQueryKey {
            cachedIDs = engine.search(Query(text: text, matchPath: matchPath,
                                            caseInsensitive: caseInsensitive, wholeWord: wholeWord), in: store)
            cachedQueryKey = key
        }
        let sorted = engine.sortedPrefix(cachedIDs, by: sort, ascending: ascending, limit: max(1, limit), in: store)
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
        liveRules = effectiveRules()
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
        liveRules = effectiveRules()   // before the monitor starts firing live reconciles
        let url = Self.cacheURL()
        let fingerprint = effectiveRules().fingerprint()
        // Use the cache only if it was built with the SAME exclusion rules now in
        // effect. Otherwise (e.g. an upgrade that turned dev-folder skipping on, or a
        // changed exclude list) the cached index disagrees with the active rules and
        // would keep serving folders that should now be hidden — rebuild instead.
        if let (loaded, evid, savedFingerprint) = try? IndexCache.load(from: url),
           loaded.count > 0, savedFingerprint == fingerprint,
           !Self.isContaminated(loaded) {
            store = loaded
            lastEventID = evid
        } else {
            await rescanAll()
            lastEventID = FSEventsGetCurrentEventId()
            try? IndexCache.save(store, to: url, lastEventID: lastEventID, rulesFingerprint: fingerprint)
        }
        startMonitor()
    }

    // A clean scan excludes the Data volume's firmlink back-door, so a healthy index
    // never holds a "/System/Volumes/Data" entry. If a loaded cache does, it was written
    // by an older build whose live path indexed that alias as duplicate records (every
    // affected file appeared twice — once at its canonical "/…" path, once under
    // "/System/Volumes/Data/…"). Treat the cache as contaminated and rebuild once to
    // purge it; the hardened live path (see liveRules) won't let it come back.
    private static func isContaminated(_ store: FileStore) -> Bool {
        store.idForDirPath("/System/Volumes/Data") != nil
    }

    private func startMonitor() {
        let m = LiveMonitor(onChanged: { [weak self] changes in
            guard let self else { return }
            Task { await self.enqueueChanges(changes) }
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
        // "/" is the sealed, read-only System volume; the writable Data volume — home,
        // /Users, /private, /Applications — is mounted at /System/Volumes/Data, and its
        // live changes are NOT delivered through a "/" watch (only via slow coalesced
        // rescans every few minutes, which is why new files in the home folder took
        // minutes to appear). Watch the Data volume directly so home-folder changes are
        // instant; enqueueChanges maps the /System/Volumes/Data prefix back to canonical.
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

    // FSEvents delivery → coalesced reconcile. Watching the whole Data volume delivers a
    // FIREHOSE of change notifications during normal use (browser caches, app state, logs
    // — hundreds per second under load). Reconciling once per delivery hammered this
    // actor so relentlessly that the UI's own search/sort calls (which share the actor)
    // never got a turn — the window looked frozen even though typing still worked. So
    // instead of reconciling inline, accumulate the changed directories and process them
    // in one deduped, throttled drain (≈twice a second), yielding mid-drain so a queued
    // search interleaves. Each reported path IS the directory that changed; firmlink
    // Data paths are mapped back to canonical so they resolve against the index.
    private var pendingDirs: Set<String> = []
    private var pendingDeep: Set<String> = []
    private var drainScheduled = false
    private var draining = false

    func enqueueChanges(_ changes: [LiveMonitor.FSChange]) {
        for c in changes {
            let p = LiveMonitor.canonicalEventPath(c.path)
            pendingDirs.insert(p)
            if c.mustScanSubtree { pendingDeep.insert(p) }
        }
        // A drain is already pending or running — it will sweep up what we just added.
        guard !drainScheduled, !draining else { return }
        drainScheduled = true
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000) // coalesce a 0.5s burst
            await self?.drainChanges()
        }
    }

    private func drainChanges() async {
        drainScheduled = false
        guard !draining else { return }
        draining = true
        defer { draining = false }
        var processed = 0
        // Carries across the whole drain so a subtree one event just fully indexed isn't
        // re-listed by a sibling or descendant event in the same pass.
        var newlyIndexed = Set<String>()
        // Loop until the backlog is empty so changes that arrive mid-drain aren't lost.
        while !pendingDirs.isEmpty {
            let dirs = pendingDirs.sorted()          // ancestors first
            let deep = pendingDeep
            pendingDirs.removeAll(keepingCapacity: true)
            pendingDeep.removeAll(keepingCapacity: true)
            var changed = false
            for d in dirs {
                // A MustScanSubDirs (deep) event resyncs the whole live subtree under `d`;
                // a normal event resyncs just `d`. The descent is ITERATIVE — an explicit
                // stack with an `await` between levels — never a synchronous recursion,
                // which walked the whole subtree in one uninterruptible call and froze the
                // actor (search shares it). A deep event on a VOLUME ROOT ("/", which the
                // firmlinked Data volume canonicalizes to, or a /Volumes mount) would mean
                // re-walking the entire disk — millions of dirs — so it's demoted to a
                // single level; the launch event replay and File ▸ Rebuild Index cover that
                // rare drop.
                let descend = deep.contains(d) && !Self.isVolumeRoot(d)
                var stack = [d]
                while let dir = stack.popLast() {
                    if LiveMonitor.reconcileLevel(directory: dir, in: &store, rules: liveRules, volID: 1,
                                                  descend: descend, newlyIndexedDirs: &newlyIndexed,
                                                  pushChildDirsTo: &stack) { changed = true }
                    processed += 1
                    // Suspend periodically so a queued search/sort runs instead of waiting
                    // for the whole drain — this is what keeps the UI responsive under churn.
                    if processed % 64 == 0 { await Task.yield() }
                }
            }
            if changed {
                cachedQueryKey = nil
                onLiveChange?()
            }
        }
    }

    // A MustScanSubDirs on a volume root means FSEvents lost track of an entire volume, so
    // a deep re-walk from here would be the whole disk. drainChanges resyncs only the top
    // level in that case. "/" covers the boot + firmlinked Data volume (Data paths are
    // canonicalized to "/"); "/Volumes/<name>" is an external mount root.
    private static func isVolumeRoot(_ path: String) -> Bool {
        if path == "/" || path == "/System/Volumes/Data" { return true }
        if path.hasPrefix("/Volumes/") { return !path.dropFirst("/Volumes/".count).contains("/") }
        return false
    }

    // Safety net for iCloud "Desktop & Documents" (FileProvider) folders: macOS does
    // NOT deliver FSEvents for these the way it does ordinary folders, so files
    // created/deleted on the Desktop or in Documents/Downloads can lag minutes behind
    // (only coarse coalesced rescans eventually catch them). Periodically re-read just
    // these few user-facing folders directly. Cost is trivial — each unchanged folder
    // is gated to a single lstat by reconcile's mtime check; a folder only gets a full
    // readdir when its contents actually changed. Shallow (one level) on purpose:
    // a deep subtree walk would lstat the entire subtree every tick, which is not free.
    func sweepUserFolders() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let targets = ["Desktop", "Documents", "Downloads"].map { home + "/" + $0 }
        var newlyIndexed = Set<String>()
        var changed = false
        for dir in targets {
            if LiveMonitor.reconcile(directory: dir, in: &store, rules: liveRules, volID: 1,
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
