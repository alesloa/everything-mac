import SwiftUI
import AppKit
import IndexCore
import Combine

@MainActor
final class AppModel: ObservableObject {
    @Published var query = ""
    @Published var results: [FileRecord] = [] {
        didSet {
            if selectedID != nil && selected == nil {
                selectedID = nil
            }
        }
    }
    @Published var total = 0
    @Published var sortKey: QueryEngine.SortKey = .relevance
    @Published var ascending = true
    @Published var matchPath = false
    // Live search modifiers (Everything's Match Case / Match Whole Word). Persisted
    // and threaded into every search; not part of ExcludeRules, so changing them
    // re-runs the query instantly without re-indexing.
    @Published var caseSensitive = false
    @Published var wholeWord = false
    @Published var fuzzy = true
    // Max rows handed to the table — the old hardcoded 5000 cap, now user-tunable.
    @Published var resultLimit = 5000
    @Published var rules: ExcludeRules = .defaults
    @Published var scanning = false
    @Published var shares: [NetworkShareStatus] = []
    @Published var selectedID: UInt32? {
        didSet { selectedPath = selectedID.flatMap { id in results.first { $0.id == id }?.path } }
    }
    private var selectedPath: String?
    // Bumped to ask the focused window to put the cursor in the search field (⌘F /
    // File ▸ Find). A counter, not a Bool, so repeated requests always fire onChange.
    @Published var focusSearchSignal = 0
    @Published var fdaGranted = true
    // True while the first-launch onboarding is shown instead of the search UI.
    @Published var awaitingFullDiskAccess = false

    // IDs are stable within one store, but a rebuild can reuse them. Resolve both
    // ID and path so selection-dependent commands retain the same file target.
    var selected: FileRecord? {
        guard let id = selectedID, let path = selectedPath else { return nil }
        return results.first { $0.id == id && $0.path.utf8.elementsEqual(path.utf8) }
    }

    let index: IndexActor
    private let preferences: UserDefaults
    private var task: Task<Void, Never>?
    private var liveTask: Task<Void, Never>?
    private var flushTimer: Task<Void, Never>?
    private var cloudSweepTimer: Task<Void, Never>?
    private var fdaPollTask: Task<Void, Never>?
    private var shareCheckTimer: Task<Void, Never>?
    private var bootstrapped = false
    private var indexStarted = false
    private var searchSeq = 0
    private var searchTask: Task<[FileRecord], Never>?
    private var rebuildTask: Task<Void, Never>?
    private var activeScanID: UUID?

    init(index: IndexActor = IndexActor(), preferences: UserDefaults = .standard) {
        self.index = index
        self.preferences = preferences
    }

    func bootstrap() {
        guard !bootstrapped else { return }
        bootstrapped = true
        loadPrefs()   // before the first runSearch so the initial query uses saved options
        fdaGranted = FullDiskAccess.isGranted()
        // Scanning without Full Disk Access makes macOS prompt for every protected
        // folder, and those modal dialogs get in the way of granting it. On a fresh
        // install, hold the scan until the user decides.
        if !fdaGranted {
            Task {
                if await index.hasUsableCache() {
                    startIndex()
                } else {
                    awaitingFullDiskAccess = true
                    pollFullDiskAccess()
                }
            }
            return
        }
        startIndex()
    }

    func continueWithoutFullDiskAccess() {
        fdaPollTask?.cancel()
        awaitingFullDiskAccess = false
        startIndex()
    }

    private func pollFullDiskAccess() {
        fdaPollTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return }
                if FullDiskAccess.isGranted() {
                    fdaGranted = true
                    awaitingFullDiskAccess = false
                    startIndex()
                    return
                }
            }
        }
    }

    private func startIndex() {
        guard !indexStarted else { return }
        indexStarted = true
        let scanID = UUID()
        activeScanID = scanID
        scanning = true
        Task {
            await index.startUp(
                scanID: scanID,
                onLiveChange: { [weak self] in
                    Task { @MainActor in self?.liveRefresh() }
                },
                onProgress: { [weak self] count, id in
                    Task { @MainActor in self?.onScanProgress(count, scanID: id) }
                },
                onShareStatus: { [weak self] status in
                    Task { @MainActor in self?.shares = status }
                }
            )
            let currentRules = await index.currentRules()
            if activeScanID == scanID {
                activeScanID = nil
                scanning = false
                total = index.totalCount
                rules = currentRules
                await runSearch()
            }
            startFlushTimer()
            startCloudSweep()
            startShareCheck()
        }
        // A sleep is when a NAS connection is most likely lost: reconnect on wake.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            Task { await self.index.reconnectShares() }
        }
    }

    func reconnectShares() { Task { await index.reconnectShares() } }
    func reconnectShare(_ share: NetworkShare) { Task { await index.reconnectShare(share) } }

    // FSEvents never fire for network shares, and a mount can come and go without
    // touching /Volumes in a way we see, so poll the mount table as a safety net.
    private func startShareCheck() {
        shareCheckTimer = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000) // 30s
                if Task.isCancelled { return }
                await index.checkNetworkShares()
            }
        }
    }

    // iCloud "Desktop & Documents" folders don't emit FSEvents, so poll them directly
    // every 2s as a safety net (see IndexActor.sweepUserFolders — near-zero cost).
    private func startCloudSweep() {
        cloudSweepTimer = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000) // 2s
                if Task.isCancelled { return }
                await index.sweepUserFolders()
            }
        }
    }

    // Progress belongs to a particular rebuild. Main-actor callbacks already in
    // flight may arrive after that rebuild finished or was superseded.
    func onScanProgress(_ count: Int, scanID: UUID) {
        guard scanning, activeScanID == scanID else { return }
        total = count
        // No live search here: during the initial build the actor serves the OLD
        // index, so re-searching every tick just churns. Results refresh once when
        // the scan completes (bootstrap/applyRules call runSearch afterward).
    }

    func queryChanged() {
        savePrefs()   // also captures a Match-path toggle (shares this entry point)
        task?.cancel()
        searchTask?.cancel()
        searchSeq &+= 1
        task = Task {
            try? await Task.sleep(nanoseconds: 40_000_000) // debounce 40ms
            if Task.isCancelled { return }
            await runSearch()
        }
    }

    // A live search option (case / whole-word / result limit) changed: persist it and
    // re-run immediately (no debounce — these come from a deliberate click, not typing).
    func searchOptionsChanged() { savePrefs(); Task { await runSearch() } }

    // Persisted sort change from a column header or the View menu.
    func setSort(_ key: QueryEngine.SortKey, ascending asc: Bool) {
        sortKey = key; ascending = asc; savePrefs(); Task { await runSearch() }
    }

    func runSearch() async {
        guard !Task.isCancelled else { return }
        searchTask?.cancel()
        searchSeq &+= 1
        let mySeq = searchSeq
        let query = query, matchPath = matchPath, caseInsensitive = !caseSensitive
        let wholeWord = wholeWord, fuzzy = fuzzy, sort = sortKey, ascending = ascending, limit = resultLimit
        let worker = Task {
            await index.search(query, matchPath: matchPath, caseInsensitive: caseInsensitive,
                               wholeWord: wholeWord, fuzzy: fuzzy, sort: sort, ascending: ascending, limit: limit)
        }
        searchTask = worker
        let r = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
        // Only the most recently started search may publish — stops a slower
        // in-flight search (e.g. from a live-refresh tick) clobbering newer
        // results with a stale sort order.
        if mySeq == searchSeq && !Task.isCancelled && !worker.isCancelled { results = r }
    }

    // Coalesce bursts of FSEvents into at most one refresh per 200ms.
    func liveRefresh() {
        liveTask?.cancel()
        liveTask = Task {
            try? await Task.sleep(nanoseconds: 200_000_000)
            if Task.isCancelled { return }
            if !scanning { total = index.totalCount }
            await runSearch()
        }
    }

    private func startFlushTimer() {
        flushTimer = Task {
            while !Task.isCancelled {
                // Save every ten minutes on the separate cache writer. Queries
                // keep reading their snapshot throughout serialization and disk IO.
                try? await Task.sleep(nanoseconds: 600_000_000_000) // 10 min
                if Task.isCancelled { return }
                await index.flush()
            }
        }
    }

    func focusSearch() { focusSearchSignal &+= 1 }

    // MARK: - Search preference persistence (UserDefaults)

    func loadPrefs() {
        let d = preferences
        matchPath = d.bool(forKey: "pref.matchPath")
        caseSensitive = d.bool(forKey: "pref.caseSensitive")
        wholeWord = d.bool(forKey: "pref.wholeWord")
        let hasFuzzyPref = d.object(forKey: "pref.fuzzy") != nil
        fuzzy = hasFuzzyPref ? d.bool(forKey: "pref.fuzzy") : true
        let lim = d.integer(forKey: "pref.resultLimit")
        resultLimit = lim > 0 ? lim : 5000
        if hasFuzzyPref {
            if let sk = d.string(forKey: "pref.sortKey") { sortKey = Self.sortKey(from: sk) }
            if d.object(forKey: "pref.ascending") != nil { ascending = d.bool(forKey: "pref.ascending") }
        }
    }

    func savePrefs() {
        let d = preferences
        d.set(matchPath, forKey: "pref.matchPath")
        d.set(caseSensitive, forKey: "pref.caseSensitive")
        d.set(wholeWord, forKey: "pref.wholeWord")
        d.set(fuzzy, forKey: "pref.fuzzy")
        d.set(resultLimit, forKey: "pref.resultLimit")
        d.set(Self.sortKeyName(sortKey), forKey: "pref.sortKey")
        d.set(ascending, forKey: "pref.ascending")
    }

    // SortKey has no rawValue (the byte comparators don't need one); map it by hand
    // for persistence.
    static func sortKeyName(_ k: QueryEngine.SortKey) -> String {
        switch k {
        case .relevance: return "relevance"
        case .name:  return "name"
        case .path:  return "path"
        case .size:  return "size"
        case .mtime: return "mtime"
        case .kind:  return "kind"
        }
    }
    static func sortKey(from s: String) -> QueryEngine.SortKey {
        switch s {
        case "relevance": return .relevance
        case "path":  return .path
        case "size":  return .size
        case "mtime": return .mtime
        case "kind":  return .kind
        default:      return .name
        }
    }

    // Force a full whole-disk rescan (File ▸ Rebuild Index). Same shape as applyRules
    // but without changing the exclude rules — for when the index drifts or the user
    // wants to be sure it's fresh. Persists the result so the next launch matches.
    func rebuildIndex() {
        guard !scanning else { return }
        beginRebuild(rules: nil)
    }

    func applyRules(_ newRules: ExcludeRules) {
        beginRebuild(rules: newRules)
    }

    private func beginRebuild(rules newRules: ExcludeRules?) {
        let scanID = UUID()
        activeScanID = scanID
        rebuildTask?.cancel()
        // Disable Rebuild synchronously: two commands in one main-actor turn must
        // not enqueue two complete walks before either task sets this flag.
        scanning = true
        if let newRules { rules = newRules }
        rebuildTask = Task {
            guard !Task.isCancelled, activeScanID == scanID else { return }
            if let newRules { await index.setRules(newRules) }
            guard !Task.isCancelled, activeScanID == scanID else { return }
            let completed = await index.rescanAll(scanID: scanID)
            guard !Task.isCancelled, activeScanID == scanID else { return }
            // Persist the freshly-rebuilt index with the new rules' fingerprint, so the
            // next launch sees a matching cache instead of rescanning again.
            if completed { await index.flush() }
            guard !Task.isCancelled, activeScanID == scanID else { return }
            activeScanID = nil
            rebuildTask = nil
            scanning = false
            total = index.totalCount
            await runSearch()
        }
    }
}
