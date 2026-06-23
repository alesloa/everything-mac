import SwiftUI
import IndexCore
import Combine

@MainActor
final class AppModel: ObservableObject {
    @Published var query = ""
    @Published var results: [FileRecord] = []
    @Published var total = 0
    @Published var sortKey: QueryEngine.SortKey = .name
    @Published var ascending = true
    @Published var matchPath = false
    // Live search modifiers (Everything's Match Case / Match Whole Word). Persisted
    // and threaded into every search; not part of ExcludeRules, so changing them
    // re-runs the query instantly without re-indexing.
    @Published var caseSensitive = false
    @Published var wholeWord = false
    // Max rows handed to the table — the old hardcoded 5000 cap, now user-tunable.
    @Published var resultLimit = 5000
    @Published var rules: ExcludeRules = .defaults
    @Published var scanning = false
    @Published var selectedID: UInt32?
    // Bumped to ask the focused window to put the cursor in the search field (⌘F /
    // File ▸ Find). A counter, not a Bool, so repeated requests always fire onChange.
    @Published var focusSearchSignal = 0

    // The currently-selected result, resolved by stable store id against the live
    // result set. nil once the file drops out of results, which auto-disables the
    // selection-dependent menu items.
    var selected: FileRecord? { selectedID.flatMap { id in results.first { $0.id == id } } }

    let index = IndexActor()
    private var task: Task<Void, Never>?
    private var liveTask: Task<Void, Never>?
    private var flushTimer: Task<Void, Never>?
    private var cloudSweepTimer: Task<Void, Never>?
    private var searchSeq = 0

    func bootstrap() {
        loadPrefs()   // before the first runSearch so the initial query uses saved options
        Task {
            await index.startUp(
                onLiveChange: { [weak self] in
                    Task { @MainActor in self?.liveRefresh() }
                },
                onProgress: { [weak self] count in
                    Task { @MainActor in self?.onScanProgress(count) }
                }
            )
            scanning = false
            total = await index.totalCount
            rules = await index.currentRules()
            await runSearch()
            startFlushTimer()
            startCloudSweep()
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

    // Driven by the off-actor scan: flips into "indexing" mode and streams the
    // running count to the status bar as the new index builds.
    func onScanProgress(_ count: Int) {
        scanning = true
        total = count
        // No live search here: during the initial build the actor serves the OLD
        // index, so re-searching every tick just churns. Results refresh once when
        // the scan completes (bootstrap/applyRules call runSearch afterward).
    }

    func queryChanged() {
        savePrefs()   // also captures a Match-path toggle (shares this entry point)
        task?.cancel()
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
        searchSeq &+= 1
        let mySeq = searchSeq
        let r = await index.search(query, matchPath: matchPath, caseInsensitive: !caseSensitive,
                                   wholeWord: wholeWord, sort: sortKey, ascending: ascending, limit: resultLimit)
        // Only the most recently started search may publish — stops a slower
        // in-flight search (e.g. from a live-refresh tick) clobbering newer
        // results with a stale sort order.
        if mySeq == searchSeq && !Task.isCancelled { results = r }
    }

    // Coalesce bursts of FSEvents into at most one refresh per 200ms.
    func liveRefresh() {
        liveTask?.cancel()
        liveTask = Task {
            try? await Task.sleep(nanoseconds: 200_000_000)
            if Task.isCancelled { return }
            total = await index.totalCount
            await runSearch()
        }
    }

    private func startFlushTimer() {
        flushTimer = Task {
            while !Task.isCancelled {
                // 10 min, not 60s: a whole-disk index is millions of records, and
                // flush() JSON-encodes the entire store on the actor (search waits).
                // FSEvents replays anything missed since the last flush on relaunch,
                // so a long interval only costs a little reconcile work after a crash.
                try? await Task.sleep(nanoseconds: 600_000_000_000) // 10 min
                if Task.isCancelled { return }
                await index.flush()
            }
        }
    }

    func focusSearch() { focusSearchSignal &+= 1 }

    // MARK: - Search preference persistence (UserDefaults)

    func loadPrefs() {
        let d = UserDefaults.standard
        matchPath = d.bool(forKey: "pref.matchPath")
        caseSensitive = d.bool(forKey: "pref.caseSensitive")
        wholeWord = d.bool(forKey: "pref.wholeWord")
        let lim = d.integer(forKey: "pref.resultLimit")
        resultLimit = lim > 0 ? lim : 5000
        if let sk = d.string(forKey: "pref.sortKey") { sortKey = Self.sortKey(from: sk) }
        if d.object(forKey: "pref.ascending") != nil { ascending = d.bool(forKey: "pref.ascending") }
    }

    func savePrefs() {
        let d = UserDefaults.standard
        d.set(matchPath, forKey: "pref.matchPath")
        d.set(caseSensitive, forKey: "pref.caseSensitive")
        d.set(wholeWord, forKey: "pref.wholeWord")
        d.set(resultLimit, forKey: "pref.resultLimit")
        d.set(Self.sortKeyName(sortKey), forKey: "pref.sortKey")
        d.set(ascending, forKey: "pref.ascending")
    }

    // SortKey has no rawValue (the byte comparators don't need one); map it by hand
    // for persistence.
    static func sortKeyName(_ k: QueryEngine.SortKey) -> String {
        switch k {
        case .name:  return "name"
        case .path:  return "path"
        case .size:  return "size"
        case .mtime: return "mtime"
        case .kind:  return "kind"
        }
    }
    static func sortKey(from s: String) -> QueryEngine.SortKey {
        switch s {
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
        Task {
            scanning = true
            await index.rescanAll()
            await index.flush()
            scanning = false
            total = await index.totalCount
            await runSearch()
        }
    }

    func applyRules(_ newRules: ExcludeRules) {
        Task {
            await index.setRules(newRules)
            rules = newRules
            scanning = true
            await index.rescanAll()
            // Persist the freshly-rebuilt index with the new rules' fingerprint, so the
            // next launch sees a matching cache instead of rescanning again.
            await index.flush()
            scanning = false
            total = await index.totalCount
            await runSearch()
        }
    }
}
