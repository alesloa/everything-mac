import Foundation
import CoreServices
import IndexCore

struct NetworkShareStatus: Sendable, Equatable, Identifiable {
    let share: NetworkShare
    let mountPath: String?
    let scanning: Bool
    let count: Int
    var paused = false
    var queued = false
    var lastRefreshed: Date?
    var refreshInterval: TimeInterval = NetworkShareRefreshPolicy.defaultInterval
    var id: String { share.id }
    var isOffline: Bool { mountPath == nil }
}

// Owns filesystem work and mutations. Searches read immutable snapshots through
// a separate service, so even a stalled directory listing or cache write cannot
// queue ahead of a query. Publish only after a coherent batch of changes.
actor IndexActor {
    typealias DiskScanner = @Sendable (ExcludeRules, @escaping @Sendable () -> Bool,
                                      @escaping @Sendable (Int) -> Void) -> FileStore
    typealias StreamingDiskScanner = @Sendable (ExcludeRules, @escaping @Sendable () -> Bool,
        @escaping @Sendable (Int) -> Void, @escaping @Sendable (FileStore) -> Void) -> FileStore
    typealias ShareScanner = @Sendable (String, ExcludeRules, UInt32,
                                       @escaping @Sendable () -> Bool,
                                       @escaping @Sendable (Int) -> Void) -> FileStore
    private var store = FileStore()
    nonisolated let searchIndex = SearchIndex()
    nonisolated private let activityJournal: IndexActivityJournal
    private var activityShareRoots: [String: String] = [:]
    private let cacheWriter = IndexCacheWriter()
    private var cacheRevision: UInt64 = 0
    private var compactionID: UUID?
    private var storeGeneration: UInt64 = 0
    private var storeFingerprint: UInt64?
    private var storeRules: ExcludeRules?
    private var rules = ExcludeRules.defaults
    // Rules the LIVE path reconciles with — the user rules plus the firmlink back-door /
    // network-mount exclusions the scan applies via effectiveRules(). Without these, a
    // live reconcile that ever sees a "/System/Volumes/Data/…" path (the Data volume's
    // firmlink alias) would index it as a SECOND copy of a file already held at its
    // canonical "/…" path — the duplicate-folder bug. Refreshed whenever rules change.
    private var liveRules = ExcludeRules.defaults

    private var monitor: LiveMonitor?
    private var lastEventID: UInt64 = UInt64(kFSEventStreamEventIdSinceNow)
    private var onLiveChange: (@Sendable () -> Void)?
    private var onProgress: (@Sendable (Int, UUID) -> Void)?
    private var onShareStatus: (@Sendable ([NetworkShareStatus]) -> Void)?

    // Network scans publish complete replacements after reconnects and scheduled
    // refreshes. Offline shares retain their last-known searchable snapshots.
    private var scanningShares: [String: Int] = [:]
    private var shareCounts: [String: Int] = [:]
    private var mountingShares: Set<String> = []
    private var shareScanIDs: [String: UUID] = [:]
    private var shareScanCancellations: [String: IndexScanCancellation] = [:]
    // Keep physical workers counted until they actually return: cancelling a
    // blocked smbfs syscall cannot interrupt it, and must not spawn more walkers.
    private var shareWorkers: [String: UUID] = [:]
    private var pendingShareRefresh: Set<String> = []
    private var observedShareMountPaths: [String: String] = [:]
    private var shareLastAttempt: [String: Date] = [:]
    private var shareLastRefresh: [String: Date] = [:]
    private var shareRefreshPolicies: [String: NetworkShareRefreshPolicy] = [:]
    private static let maximumConcurrentShareScans = 2
    private var rebuildID: UUID?
    private var rebuildCancellation: IndexScanCancellation?
    private var previousReplayCheckpointBlocked: Bool?
    private var preparedCache: (FileStore, UInt64, UInt64)?
    private let preferences: UserDefaults
    private let configuredCacheURL: URL?
    private let diskScanner: StreamingDiskScanner
    private var progressiveScanCount = 0
    private var scanProgressCount = 0
    private let shareScanner: ShareScanner
    private let networkMounts: @Sendable () -> [MountTable.Mount]
    private let refreshClock: @Sendable () -> Date

    init(rules configuredRules: ExcludeRules? = nil, preferencesSuiteName: String? = nil,
         cacheURL: URL? = nil, diskScanner: DiskScanner? = nil,
         streamingDiskScanner: StreamingDiskScanner? = nil,
         shareScanner: ShareScanner? = nil,
         networkMounts: @escaping @Sendable () -> [MountTable.Mount] = { MountTable.networkMounts() },
         refreshClock: @escaping @Sendable () -> Date = { Date() },
         activityCapacity: Int = IndexActivityJournal.defaultCapacity,
         activityClock: @escaping @Sendable () -> Date = { Date() },
         onProgress: (@Sendable (Int, UUID) -> Void)? = nil) {
        activityJournal = IndexActivityJournal(capacity: activityCapacity, clock: activityClock)
        let preferences = preferencesSuiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
        self.preferences = preferences
        configuredCacheURL = cacheURL
        if let streamingDiskScanner { self.diskScanner = streamingDiskScanner }
        else if let diskScanner {
            self.diskScanner = { rules, cancelled, progress, _ in diskScanner(rules, cancelled, progress) }
        } else {
            self.diskScanner = { rules, cancelled, progress, snapshot in
                ParallelScanner.scanWholeDisk(rules: rules, isCancelled: cancelled,
                                              progress: progress, onSnapshot: snapshot)
            }
        }
        self.shareScanner = shareScanner ?? { path, rules, volID, isCancelled, progress in
            ParallelScanner.scan(root: path, rules: rules, volID: volID, workers: 4,
                                 isCancelled: isCancelled, progress: progress)
        }
        self.networkMounts = networkMounts
        self.refreshClock = refreshClock
        if let data = preferences.data(forKey: "pref.networkShareRefreshPolicies"),
           let policies = try? JSONDecoder().decode([String: NetworkShareRefreshPolicy].self, from: data) {
            shareRefreshPolicies = policies
        }
        self.onProgress = onProgress
        if let configuredRules { rules = configuredRules; return }
        if let data = preferences.data(forKey: "excludeRules"),
           let r = try? JSONDecoder().decode(ExcludeRules.self, from: data) {
            rules = r
        }
    }

    nonisolated var totalCount: Int { searchIndex.count }

    // Memory-only reads bypass a writer blocked in a filesystem call.
    nonisolated func activitySnapshot() -> IndexActivitySnapshot { activityJournal.snapshot() }
    nonisolated func clearActivity() { activityJournal.clear() }

    // ~/Library/Application Support/Everything-Mac/index.idx
    static func cacheURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Everything-Mac", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("index.idx")
    }

    private func cacheLocation() -> URL { configuredCacheURL ?? Self.cacheURL() }

    // Validate on the actor, and keep the loaded store for startUp so a large cache
    // is neither decoded on the UI thread nor decoded twice during onboarding.
    func hasUsableCache() -> Bool {
        guard let cache = loadActivityCache() else { return false }
        preparedCache = cache
        return true
    }

    nonisolated func search(_ text: String, matchPath: Bool, caseInsensitive: Bool = true,
                            wholeWord: Bool = false, fuzzy: Bool = false,
                            sort: QueryEngine.SortKey, ascending: Bool, limit: Int = 5000) async -> [FileRecord] {
        await searchIndex.search(Query(text: text, matchPath: matchPath, caseInsensitive: caseInsensitive,
                                       wholeWord: wholeWord, fuzzy: fuzzy),
                                 sort: sort, ascending: ascending, limit: limit)
    }

    private func publishStore() {
        searchIndex.publish(store)
        let root = store.rootID == FileStore.noParent ? [] : [store.path(of: store.rootID)]
        let shares = rules.networkShares.compactMap { share -> String? in
            guard let path = activityShareRoots[share.source], let id = store.idForDirPath(path),
                  store.volID(of: id) == share.volID else { return nil }
            return store.path(of: id)
        }
        activityJournal.publishIndex(count: searchIndex.count, roots: root + shares.sorted())
        onLiveChange?()
        scheduleCompaction()
    }

    // Packing and mapping never run on the filesystem writer or reader lock.
    // Stable slots let adoption retain updates made during detached compaction.
    private func scheduleCompaction() {
        guard compactionID == nil, rebuildID == nil, store.needsCompaction else { return }
        let id = UUID(), generation = storeGeneration
        let snapshot = store.storageSnapshot(), revision = snapshot.revision
        compactionID = id
        Task {
            let compacted = await Task.detached(priority: .utility) { try? snapshot.compacted() }.value
            self.finishCompaction(compacted, id: id, generation: generation, revision: revision)
        }
    }

    private func finishCompaction(_ compacted: FileStore?, id: UUID, generation: UInt64, revision: UInt64) {
        guard compactionID == id else { return }
        compactionID = nil
        guard generation == storeGeneration, rebuildID == nil, let compacted,
              store.adoptCompaction(compacted, expectedRevision: revision) else { return }
        // Storage changed, not records or event checkpoints. Readers with old
        // snapshots keep their old mapping and any cached candidate sets alive.
        searchIndex.publish(store)
        scheduleCompaction()
    }

    func currentRules() -> ExcludeRules { rules }

    func setRules(_ r: ExcludeRules) {
        if rules != r {
            if let id = rebuildID {
                // Source: setRules is the operation which cancelled this worker.
                activityJournal.finishScan(id: id, outcome: .scanCancelled, detail: "Index rules changed.")
            }
            rebuildCancellation?.cancel()
            if progressiveScanCount > 0 { restoreAcceptedPublication() }
            invalidateShareScans()
            preparedCache = nil
        }
        rules = r
        liveRules = effectiveRules()
        publishShareStatus()
        if let data = try? JSONEncoder().encode(r) {
            preferences.set(data, forKey: "excludeRules")
        }
    }

    // macOS presents one unified filesystem at "/": the read-only System volume
    // and the Data volume are joined via firmlinks, and external volumes mount
    // under /Volumes. A single recursive scan of "/" covers the entire disk and
    // every mounted volume exactly once — EXCEPT the Data volume is also visible
    // at /System/Volumes/Data (and siblings), which would duplicate every user
    // file. Exclude those firmlink back-doors. User rules are merged in.
    private func effectiveRules(excludingNetworkMounts: Bool = true) -> ExcludeRules {
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
        effective.pathPrefixes += firmlinkBackDoors
        if rules.excludeBootVolume { effective.pathPrefixes += Self.startupVolumeAliases() }
        if excludingNetworkMounts { effective.pathPrefixes += Self.nonLocalMountPaths() }
        return effective
    }

    // Mount availability changes what can be scanned, not the user's exclusions.
    // An offline share must not invalidate the cache holding its last-known files.
    private func cacheFingerprint() -> UInt64 {
        effectiveRules(excludingNetworkMounts: false).fingerprint()
    }

    private func invalidateShareScans() {
        for id in shareScanIDs.values {
            // Source: the writer explicitly invalidated these active scan generations.
            activityJournal.finishScan(id: id, outcome: .scanCancelled, detail: "Share scan invalidated.")
        }
        for cancellation in shareScanCancellations.values { cancellation.cancel() }
        shareScanCancellations.removeAll()
        shareScanIDs.removeAll()
        scanningShares.removeAll()
        observedShareMountPaths.removeAll()
        pendingShareRefresh.removeAll()
    }

    // Mount points of non-local filesystems — network shares and automounter stubs.
    static func nonLocalMountPaths() -> [String] { MountTable.nonLocalMounts().map(\.path) }

    // /Volumes exposes the startup disk as a symlink to /. Exclude the alias
    // itself as well as its contents, without resolving or reading network mounts.
    static func startupVolumeAliases(in directory: String = "/Volumes", target: String = "/") -> [String] {
        let manager = FileManager.default
        let networkPaths = Set(nonLocalMountPaths())
        return (try? manager.contentsOfDirectory(atPath: directory))?.sorted().compactMap { name in
            let path = directory + "/" + name
            guard !networkPaths.contains(path) else { return nil }
            guard let destination = try? manager.destinationOfSymbolicLink(atPath: path),
                  destination.utf8.elementsEqual(target.utf8) else { return nil }
            return path
        } ?? []
    }

    // Rebuild the whole index from "/". The walk runs OFF the actor on a pool of
    // worker threads (ParallelScanner). Searches keep using the existing snapshot
    // while the replacement builds; publish the finished store atomically.
    @discardableResult
    func rescanAll(scanID id: UUID = UUID()) async -> Bool {
        guard !Task.isCancelled else { return false }
        // An overflow can arrive during an older rebuild. Superseding it must
        // carry that block forward until a replacement snapshot is accepted.
        previousReplayCheckpointBlocked = previousReplayCheckpointBlocked == true || replayCheckpointBlocked
        if let previousID = rebuildID {
            // Source: this rescanAll invocation replaces the previous active scan.
            activityJournal.finishScan(id: previousID, outcome: .scanCancelled, detail: "Replaced by a newer scan.")
        }
        rebuildCancellation?.cancel()
        if progressiveScanCount > 0 { restoreAcceptedPublication() }
        let cancellation = IndexScanCancellation()
        rebuildCancellation = cancellation
        rebuildID = id
        progressiveScanCount = 0
        scanProgressCount = 0
        activityJournal.startScan(id: id, path: rules.localScanRoot)
        replayCheckpointBlocked = false
        invalidateShareScans()
        publishShareStatus()
        let scanEventID = FSEventsGetCurrentEventId()
        let fingerprint = cacheFingerprint()
        let effective = effectiveRules()
        let scanner = diskScanner
        let previous = store.storageSnapshot()
        // A startup-disk toggle changes only the local scan root. Keep cached
        // shares through that rebuild even while the server is disconnected.
        var previousRules = storeRules
        previousRules?.excludeBootVolume = rules.excludeBootVolume
        let retainedShares = storeFingerprint == fingerprint || previousRules == rules ? rules.networkShares : []
        let worker = Task.detached(priority: .userInitiated) {
            var scanned = scanner(effective, { cancellation.isCancelled }, { count in
                Task { await self.scanProgress(count, scanID: id) }
            }, { snapshot in
                Task { await self.publishScanSnapshot(snapshot, scanID: id) }
            })
            if !cancellation.isCancelled, scanned.count > 0 {
                ShareIndexMutation.retainKnownShares(retainedShares, from: previous, in: &scanned,
                                                     isCancelled: { cancellation.isCancelled })
            }
            if !cancellation.isCancelled, let compacted = try? scanned.storageSnapshot().compacted() {
                scanned.adoptCompaction(compacted, expectedRevision: scanned.revision)
            }
            return scanned
        }
        let newStore = await withTaskCancellationHandler { await worker.value } onCancel: {
            cancellation.cancel()
            worker.cancel()
            // Source: task cancellation retires this result even if a syscall has not returned.
            self.activityJournal.finishScan(id: id, outcome: .scanCancelled)
        }
        guard rebuildID == id else { return false }
        rebuildID = nil
        rebuildCancellation = nil
        // Partial local scans are deliberate without Full Disk Access. A cancelled
        // walk or an unreadable root must not replace the last searchable snapshot.
        guard !cancellation.isCancelled, !Task.isCancelled, newStore.count > 0 else {
            if progressiveScanCount > 0 { restoreAcceptedPublication() }
            activityJournal.finishScan(id: id,
                outcome: cancellation.isCancelled || Task.isCancelled ? .scanCancelled : .scanFailed,
                detail: cancellation.isCancelled || Task.isCancelled ? nil : "Scanner returned no entries.")
            replayCheckpointBlocked = replayCheckpointBlocked || previousReplayCheckpointBlocked == true
            previousReplayCheckpointBlocked = nil
            enqueueChanges([])
            return false
        }
        previousReplayCheckpointBlocked = nil
        store = newStore
        storeGeneration &+= 1
        lastEventID = scanEventID
        storeFingerprint = fingerprint
        storeRules = rules
        activityJournal.finishScan(id: id, outcome: newStore.scanCompleted ? .scanCompleted : .scanIncomplete,
            detail: newStore.scanCompleted ? nil : "Scanner marked the result incomplete.", count: newStore.count)
        publishStore()
        if monitor != nil {
            // The new stream replays everything since scanEventID, including
            // events the old stream queued or reported dropped while the walk ran.
            replayCheckpointBlocked = false
            pendingDirs.removeAll()
            pendingDeep.removeAll()
            pendingEventID = 0
            startMonitor()
        }
        enqueueChanges([])
        onProgress?(store.count, id)
        shareCounts = [:]
        for share in rules.networkShares { shareCounts[share.source] = store.liveCount(volID: share.volID) }
        checkNetworkShares()
        reconnectShares()
        return true
    }

    private func scanProgress(_ count: Int, scanID: UUID) {
        guard rebuildID == scanID, rebuildCancellation?.isCancelled == false, count >= scanProgressCount else { return }
        scanProgressCount = count
        activityJournal.scanProgress(id: scanID, count: count)
        onProgress?(count, scanID)
    }

    private func publishScanSnapshot(_ snapshot: FileStore, scanID: UUID) {
        // A replacement scan retains the complete known index until acceptance.
        // A cold scan has no known files, so coherent discovered batches are useful.
        guard store.count == 0, rebuildID == scanID, rebuildCancellation?.isCancelled == false,
              snapshot.count > progressiveScanCount else { return }
        progressiveScanCount = snapshot.count
        searchIndex.publish(snapshot)
        let roots = snapshot.rootID == FileStore.noParent ? [] : [snapshot.path(of: snapshot.rootID)]
        activityJournal.publishIndex(count: snapshot.count, roots: roots)
        scanProgress(snapshot.count, scanID: scanID)
        onLiveChange?()
    }

    private func restoreAcceptedPublication() {
        searchIndex.publish(store)
        let roots = store.rootID == FileStore.noParent ? [] : [store.path(of: store.rootID)]
        activityJournal.publishIndex(count: searchIndex.count, roots: roots)
        progressiveScanCount = 0
        onLiveChange?()
    }

    // Launch path: load the cache if present (FSEvents replays any changes made
    // while we were closed), otherwise do a full scan and save a fresh cache.
    // Then start the live monitor from the saved event id.
    func startUp(scanID: UUID = UUID(), onLiveChange: @escaping @Sendable () -> Void,
                 onProgress: @escaping @Sendable (Int, UUID) -> Void,
                 onShareStatus: @escaping @Sendable ([NetworkShareStatus]) -> Void) async {
        self.onLiveChange = onLiveChange
        self.onProgress = onProgress
        self.onShareStatus = onShareStatus
        liveRules = effectiveRules()   // before the monitor starts firing live reconciles
        let fingerprint = cacheFingerprint()
        // Use the cache only if it was built with the SAME exclusion rules now in
        // effect. Otherwise (e.g. an upgrade that turned dev-folder skipping on, or a
        // changed exclude list) the cached index disagrees with the active rules and
        // would keep serving folders that should now be hidden — rebuild instead.
        let cache = preparedCache ?? loadActivityCache()
        preparedCache = nil
        if let (loaded, evid, savedFingerprint) = cache,
           loaded.count > 0, savedFingerprint == fingerprint,
           !Self.isContaminated(loaded) {
            store = loaded
            lastEventID = evid
            storeFingerprint = savedFingerprint
            storeRules = rules
            publishStore()
            for share in rules.networkShares { shareCounts[share.source] = store.liveCount(volID: share.volID) }
            checkNetworkShares()
            reconnectShares()
        } else {
            await rescanAll(scanID: scanID)
            await flush()
        }
        startMonitor()
    }

    // MARK: - Network shares

    // The existing mount-table timer also schedules refreshes while a share stays
    // mounted. Reading this table uses MNT_NOWAIT and never contacts a server.
    func checkNetworkShares() {
        guard rebuildID == nil else { publishShareStatus(); return }
        let mounts = networkMounts(), now = refreshClock()
        for share in rules.networkShares {
            let source = share.source
            guard let mount = mounts.first(where: { $0.source == source }) else {
                retireShareScan(source)
                pendingShareRefresh.remove(source)
                observedShareMountPaths[source] = nil
                continue
            }
            let moved = observedShareMountPaths[source].map { !$0.utf8.elementsEqual(mount.path.utf8) } ?? true
            if moved { retireShareScan(source) }
            observedShareMountPaths[source] = mount.path
            let policy = currentShareRefreshPolicy(for: share)
            guard !policy.paused else { continue }
            let elapsed = shareLastAttempt[source].map { now.timeIntervalSince($0) }
            let due = elapsed.map { $0 < 0 || $0 >= policy.interval } ?? true
            if (moved || due), shareScanIDs[source] == nil { pendingShareRefresh.insert(source) }
        }
        dispatchShareRefreshes(mounts: mounts, now: now)
        publishShareStatus()
    }

    func currentShareRefreshPolicy(for share: NetworkShare) -> NetworkShareRefreshPolicy {
        shareRefreshPolicies[share.source] ?? NetworkShareRefreshPolicy()
    }

    func setShareRefreshPolicy(_ policy: NetworkShareRefreshPolicy, for share: NetworkShare) {
        guard rules.networkShares.contains(where: { $0.source == share.source }) else { return }
        let previous = currentShareRefreshPolicy(for: share)
        shareRefreshPolicies[share.source] = policy
        if let data = try? JSONEncoder().encode(shareRefreshPolicies) {
            preferences.set(data, forKey: "pref.networkShareRefreshPolicies")
        }
        if policy.paused {
            retireShareScan(share.source)
            pendingShareRefresh.remove(share.source)
        } else if previous.paused {
            pendingShareRefresh.insert(share.source)
        }
        checkNetworkShares()
    }

    // A manual refresh is allowed while scheduling is paused. Its result still
    // replaces the share only after the entire snapshot passes validation.
    func refreshShare(_ share: NetworkShare) {
        guard rebuildID == nil, rules.networkShares.contains(where: { $0.source == share.source }),
              shareScanIDs[share.source] == nil,
              networkMounts().contains(where: { $0.source == share.source }) else { return }
        pendingShareRefresh.insert(share.source)
        dispatchShareRefreshes(mounts: networkMounts(), now: refreshClock())
        publishShareStatus()
    }

    func cancelShareRefresh(_ share: NetworkShare) {
        retireShareScan(share.source)
        pendingShareRefresh.remove(share.source)
        shareLastAttempt[share.source] = refreshClock()
        publishShareStatus()
    }

    private func retireShareScan(_ source: String) {
        if let id = shareScanIDs[source] {
            // Source: this writer action retires the currently active share scan.
            activityJournal.finishScan(id: id, outcome: .scanCancelled)
        }
        shareScanCancellations.removeValue(forKey: source)?.cancel()
        shareScanIDs[source] = nil
        scanningShares[source] = nil
    }

    private func dispatchShareRefreshes(mounts: [MountTable.Mount], now: Date) {
        guard rebuildID == nil else { return }
        for share in rules.networkShares where pendingShareRefresh.contains(share.source) {
            guard shareWorkers.count < Self.maximumConcurrentShareScans else { break }
            guard shareWorkers[share.source] == nil,
                  let mount = mounts.first(where: { $0.source == share.source }) else { continue }
            pendingShareRefresh.remove(share.source)
            shareLastAttempt[share.source] = now
            observedShareMountPaths[share.source] = mount.path
            scanShare(share, at: mount.path)
        }
    }

    // Mount every configured share that is currently unreachable. Called on launch,
    // on wake and from Settings — never on the periodic check, which would fight a
    // user who just ejected the share on purpose.
    func reconnectShares() {
        let mounted = Set(networkMounts().map(\.source))
        for share in rules.networkShares where !mounted.contains(share.source) {
            reconnectShare(share)
        }
    }

    // Settings may request a connection for an edited share before applying its
    // indexing rules. Mount only that share; checkNetworkShares still indexes only
    // the configured rules after the connection succeeds.
    func reconnectShare(_ share: NetworkShare) {
        guard let url = share.url, !mountingShares.contains(share.source),
              !networkMounts().contains(where: { $0.source == share.source }) else { return }
        mountingShares.insert(share.source)
        Task {
            let ok = await Task.detached(priority: .utility) { NetworkMounter.mount(url) }.value
            self.finishMount(share.source, mounted: ok)
        }
    }

    private func finishMount(_ source: String, mounted: Bool) {
        mountingShares.remove(source)
        if mounted { checkNetworkShares() }
    }

    private func scanShare(_ share: NetworkShare, at mountPath: String) {
        let scanID = UUID()
        let cancellation = IndexScanCancellation()
        shareWorkers[share.source] = scanID
        shareScanIDs[share.source] = scanID
        shareScanCancellations[share.source] = cancellation
        scanningShares[share.source] = 0
        activityJournal.startScan(id: scanID, path: mountPath)
        let userRules = rules
        let volID = share.volID, scanner = shareScanner
        Task {
            let sub = await Task.detached(priority: .utility) {
                scanner(mountPath, userRules, volID, { cancellation.isCancelled }) { count in
                    Task { await self.shareScanProgress(share.source, scanID: scanID, count: count) }
                }
            }.value
            self.finishShareScan(share, scanID: scanID, at: mountPath, with: sub)
        }
    }

    private func shareScanProgress(_ source: String, scanID: UUID, count: Int) {
        guard shareScanIDs[source] == scanID else { return }
        scanningShares[source] = count
        activityJournal.scanProgress(id: scanID, count: count)
        publishShareStatus()
    }

    // A share that vanished mid-scan yields a truncated tree: keep the previous
    // entries instead. A share removed from the rules while scanning is dropped.
    private func finishShareScan(_ share: NetworkShare, scanID: UUID, at mountPath: String, with sub: FileStore) {
        // A rebuild or rule change invalidates the old scan. Its completion and
        // progress must never overwrite a newer scan or reintroduce excluded files.
        guard shareWorkers[share.source] == scanID else { return }
        shareWorkers[share.source] = nil
        guard shareScanIDs[share.source] == scanID else {
            checkNetworkShares()
            return
        }
        shareLastAttempt[share.source] = refreshClock()
        shareScanIDs[share.source] = nil
        shareScanCancellations[share.source] = nil
        scanningShares[share.source] = nil
        defer { checkNetworkShares() }
        guard rules.networkShares.contains(share),
              let currentMountPath = networkMounts().first(where: { $0.source == share.source })?.path,
              currentMountPath.utf8.elementsEqual(mountPath.utf8) else {
            activityJournal.finishScan(id: scanID, outcome: .scanCancelled,
                detail: "Configured share or mounted path changed.")
            return
        }
        guard ShareIndexMutation.replace(share, at: mountPath, with: sub, in: &store) else {
            let detail: String
            // Sources: these labels describe the returned scanner fields and graft validation.
            if sub.count == 0 { detail = "Scanner returned no entries." }
            else if !sub.scanCompleted { detail = "Scanner marked the result incomplete." }
            else { detail = "Scanner result could not replace the indexed share." }
            activityJournal.finishScan(id: scanID, outcome: sub.scanCompleted ? .scanFailed : .scanIncomplete,
                                       detail: detail, count: sub.count)
            return
        }
        shareCounts[share.source] = sub.count
        activityShareRoots[share.source] = mountPath
        shareLastRefresh[share.source] = refreshClock()
        activityJournal.finishScan(id: scanID, outcome: .scanCompleted, count: sub.count)
        publishStore()
        Task { await flush() }
    }

    func networkShareStatuses() -> [NetworkShareStatus] {
        let mounts = networkMounts()
        return rules.networkShares.map { share in
            let policy = currentShareRefreshPolicy(for: share)
            return NetworkShareStatus(share: share,
                mountPath: mounts.first { $0.source == share.source }?.path,
                scanning: scanningShares[share.source] != nil,
                count: scanningShares[share.source] ?? shareCounts[share.source] ?? 0,
                paused: policy.paused, queued: pendingShareRefresh.contains(share.source),
                lastRefreshed: shareLastRefresh[share.source], refreshInterval: policy.interval)
        }
    }

    private func publishShareStatus() {
        let statuses = networkShareStatuses()
        activityJournal.publishShares(statuses.map { status in
            IndexActivityShare(id: status.id, name: status.share.name, mountPath: status.mountPath,
                indexedPath: activityShareRoots[status.id], indexedCount: shareCounts[status.id],
                observedCount: shareScanIDs[status.id].flatMap { activityJournal.scanProgressCount(id: $0) },
                scanning: status.scanning, paused: status.paused, queued: status.queued,
                lastRefreshed: status.lastRefreshed)
        })
        onShareStatus?(statuses)
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
        monitor?.stop()
        monitorGeneration &+= 1
        historyReplayed = false
        let generation = monitorGeneration
        let m = LiveMonitor(onChanged: { [weak self] changes in
            guard let self else { return }
            Task { await self.receiveLiveChanges(changes, generation: generation) }
        })
        m.start(paths: watchPaths(), sinceWhen: FSEventStreamEventId(lastEventID))
        monitor = m
    }

    private var monitorGeneration = 0
    private var historyReplayed = false
    private var overflowRebuildStarted = false

    // A volume-wide overflow blocks the replay checkpoint until a full rebuild.
    // A live overflow is covered by the next launch's short replay. An overflow
    // during that replay would recur at every launch, so one rebuild per session
    // restarts the stream from a fresh checkpoint.
    func receiveLiveChanges(_ changes: [LiveMonitor.FSChange], generation: Int) {
        // A replaced stream's queued deliveries are replayed by its successor.
        guard generation == monitorGeneration else { return }
        let replaying = !historyReplayed
        if changes.contains(where: \.historyDone) { historyReplayed = true }
        guard enqueueChanges(changes), replaying, !overflowRebuildStarted, rebuildID == nil else { return }
        overflowRebuildStarted = true
        Task { if await rescanAll() { await flush() } }
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
        var paths = rules.excludeBootVolume ? ["/Volumes"] : ["/", "/System/Volumes/Data"]
        // Network shares are skipped (checked BEFORE lstat — stat'ing a network mount
        // point itself can block), matching the scan, which doesn't index them.
        let networkMounts = Set(Self.nonLocalMountPaths())
        if let vols = try? FileManager.default.contentsOfDirectory(atPath: "/Volumes") {
            for v in vols.sorted() {
                let p = "/Volumes/" + v
                if networkMounts.contains(p) { continue }
                if liveRules.shouldExclude(name: v, path: p, isHidden: v.hasPrefix(".")) { continue }
                var st = stat()
                if lstat(p, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR { paths.append(p) }
            }
        }
        return paths
    }

    // Coalesce the FSEvents firehose into directory batches. The mutable writer
    // remains serial; searches bypass it and use the last published snapshot.
    // Canonicalize Data-volume aliases before resolving directories in the store.
    private var pendingDirs: Set<String> = []
    private var pendingDeep: Set<String> = []
    private var pendingEventID: UInt64 = 0
    private var replayCheckpointBlocked = false
    private var drainScheduled = false
    private var draining = false

    // Returns whether a change reported a volume-wide overflow.
    @discardableResult
    func enqueueChanges(_ changes: [LiveMonitor.FSChange]) -> Bool {
        var volumeOverflow = false
        for c in changes {
            pendingEventID = max(pendingEventID, c.eventID)
            // FSEvents delivers directories with a trailing slash; the index and the
            // volume-root checks work with the bare path.
            let raw = c.path.count > 1 && c.path.hasSuffix("/") ? String(c.path.dropLast()) : c.path
            let p = LiveMonitor.canonicalEventPath(raw)
            pendingDirs.insert(p)
            if c.mustScanSubtree { pendingDeep.insert(p) }
            // A volume-wide overflow is only reconciled shallowly. Keep replaying
            // from the previous safe checkpoint until a full rebuild covers it.
            if c.mustScanSubtree && Self.isVolumeRoot(p) {
                // Source: FSEvents' MustScanSubDirs flag requests a volume-wide replay.
                activityJournal.record(.replayIncomplete, path: p,
                    detail: "FSEvents requested a volume-wide rescan; this live pass checks one directory level.")
                replayCheckpointBlocked = true
                volumeOverflow = true
            }
        }
        // A drain is already pending or running — it will sweep up what we just added.
        guard rebuildID == nil, !drainScheduled, !draining else { return volumeOverflow }
        drainScheduled = true
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000) // coalesce a 0.5s burst
            await self?.drainChanges()
        }
        return volumeOverflow
    }

    private func drainChanges() async {
        drainScheduled = false
        guard rebuildID == nil, !draining else { return }
        draining = true
        defer {
            draining = false
            if !pendingDirs.isEmpty { enqueueChanges([]) }
        }
        var processed = 0
        // Carries across the whole drain so a subtree one event just fully indexed isn't
        // re-listed by a sibling or descendant event in the same pass.
        var newlyIndexed = Set<String>()
        // Loop until the backlog is empty so changes that arrive mid-drain aren't lost.
        while !pendingDirs.isEmpty {
            let generation = storeGeneration
            let dirs = pendingDirs.sorted()          // ancestors first
            let deep = pendingDeep
            let eventID = pendingEventID
            pendingEventID = 0
            pendingDirs.removeAll(keepingCapacity: true)
            pendingDeep.removeAll(keepingCapacity: true)
            // A mount or unmount shows up as a /Volumes change. Refresh the live
            // exclusions first so a freshly mounted share is never crawled inline.
            if dirs.contains("/Volumes") {
                liveRules = effectiveRules()
                checkNetworkShares()
            }
            var changed = false
            for d in dirs {
                // A MustScanSubDirs (deep) event resyncs the whole live subtree under `d`;
                // a normal event resyncs just `d`. An explicit stack and periodic yield
                // let mount/rule changes interleave. Queries use a separate snapshot.
                // A deep event on a VOLUME ROOT ("/", which the
                // firmlinked Data volume canonicalizes to, or a /Volumes mount) would mean
                // re-walking the entire disk — millions of dirs — so it's demoted to a
                // single level; the launch event replay and File ▸ Rebuild Index cover that
                // rare drop.
                let descend = deep.contains(d) && !Self.isVolumeRoot(d)
                var stack = [d]
                while let dir = stack.popLast() {
                    // A rebuild may start or complete while this drain yields.
                    // Reconcile this batch against the replacement store afterward.
                    if rebuildID != nil || generation != storeGeneration {
                        pendingDirs.formUnion(dirs)
                        pendingDeep.formUnion(deep)
                        pendingEventID = max(pendingEventID, eventID)
                        return
                    }
                    if LiveMonitor.reconcileLevel(directory: dir, in: &store, rules: liveRules, volID: 1,
                                                  descend: descend, newlyIndexedDirs: &newlyIndexed,
                                                  pushChildDirsTo: &stack, observe: recordObservation) { changed = true }
                    processed += 1
                    // Publish progress in coherent batches and give actor control
                    // operations a turn; searching itself never waits on this yield.
                    if processed % 64 == 0 {
                        if changed { publishStore(); changed = false }
                        await Task.yield()
                    }
                }
            }
            if changed {
                publishStore()
            }
            if !replayCheckpointBlocked { lastEventID = max(lastEventID, eventID) }
        }
    }

    // A MustScanSubDirs on a volume root means FSEvents lost track of an entire volume, so
    // a deep re-walk from here would be the whole disk. drainChanges resyncs only the top
    // level in that case. "/" covers the boot + firmlinked Data volume (Data paths are
    // canonicalized to "/"); "/Volumes/<name>" is an external mount root.
    private static func isVolumeRoot(_ path: String) -> Bool {
        if path == "/" || path == "/System/Volumes/Data" || path == "/Volumes" { return true }
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
        guard rebuildID == nil, !rules.excludeBootVolume else { return }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let targets = ["Desktop", "Documents", "Downloads"].map { home + "/" + $0 }
        var newlyIndexed = Set<String>()
        var changed = false
        for dir in targets {
            if LiveMonitor.reconcile(directory: dir, in: &store, rules: liveRules, volID: 1,
                                     newlyIndexedDirs: &newlyIndexed, observe: recordObservation) { changed = true }
        }
        guard changed else { return }
        publishStore()
    }

    // Persist on a separate writer with the last fully reconciled event id.
    func flush() async {
        // Quitting permission onboarding must not create an empty cache that
        // masquerades as a completed first scan on the next launch.
        guard store.count > 0, let fingerprint = storeFingerprint else { return }
        // Keep the last safely applied checkpoint; the current system event id
        // can include directories still waiting in our coalesced event queue.
        cacheRevision &+= 1
        let url = cacheLocation()
        activityJournal.recordCache(.cacheSaveStarted, path: url.path)
        do {
            let saved = try await cacheWriter.save(store.storageSnapshot(), to: url, lastEventID: lastEventID,
                                                   rulesFingerprint: fingerprint, revision: cacheRevision)
            let metadata = saved ? Self.cacheMetadata(url) : (nil, nil)
            activityJournal.recordCache(saved ? .cacheSaved : .cacheSaveSuperseded, path: url.path,
                                         byteCount: metadata.0, modifiedAt: metadata.1)
        } catch {
            activityJournal.recordCache(.cacheSaveFailed, path: url.path, detail: error.localizedDescription)
        }
    }

    private func recordObservation(_ observation: ReconcileObservation) {
        activityJournal.recordObservation(observation)
    }

    private func loadActivityCache() -> (FileStore, UInt64, UInt64)? {
        let url = cacheLocation()
        activityJournal.recordCache(.cacheLoadStarted, path: url.path)
        do {
            let cache = try IndexCache.load(from: url)
            // Sources: validation uses the decoded cache count, fingerprint and root lookup.
            let reason: String?
            if cache.0.count == 0 { reason = "Cache contains no entries." }
            else if cache.2 != cacheFingerprint() { reason = "Cache exclusion rules differ from the current rules." }
            else if Self.isContaminated(cache.0) { reason = "Cache contains the excluded Data-volume alias." }
            else { reason = nil }
            let metadata = Self.cacheMetadata(url)
            activityJournal.recordCache(reason == nil ? .cacheLoaded : .cacheRejected, path: url.path, detail: reason,
                                         byteCount: metadata.0, modifiedAt: metadata.1)
            return reason == nil ? cache : nil
        } catch {
            activityJournal.recordCache(.cacheLoadFailed, path: url.path, detail: error.localizedDescription)
            return nil
        }
    }

    private static func cacheMetadata(_ url: URL) -> (UInt64?, Date?) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return (nil, nil) }
        // Source: FileManager's attributes of the actual cache file supply both values.
        return ((attributes[.size] as? NSNumber)?.uint64Value, attributes[.modificationDate] as? Date)
    }
}
