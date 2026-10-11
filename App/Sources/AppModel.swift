import SwiftUI
import AppKit
import IndexCore
import Combine

@MainActor
final class AppModel: ObservableObject {
    @Published var query = ""
    @Published var results: [FileRecord] = [] {
        didSet {
            let recordsByID = Dictionary(results.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            selectedRecords = selectedRecords.compactMap { selected in
                guard let current = recordsByID[selected.id],
                      current.path.utf8.elementsEqual(selected.path.utf8) else { return nil }
                return current
            }
            if selectedID != nil && selected == nil {
                selectedID = selectedRecords.first?.id
            }
        }
    }
    @Published var total = 0
    @Published var indexRevision: UInt64 = 0
    @Published var totalMatches: Int?
    @Published var resultSnapshotID: UUID?
    @Published var sortKey: QueryEngine.SortKey = .relevance
    @Published var ascending = true
    @Published var matchPath = false
    // Live search modifiers (Everything's Match Case / Match Whole Word). Persisted
    // and threaded into every search; not part of ExcludeRules, so changing them
    // re-runs the query instantly without re-indexing.
    @Published var caseSensitive = false
    @Published var wholeWord = false
    @Published var fuzzy = true
    @Published var regex = false
    @Published var diacriticInsensitive = false
    @Published var matchPrefix = false
    @Published var matchSuffix = false
    @Published var ignorePunctuation = false
    @Published var ignoreWhitespace = false
    @Published var searchFilter: SearchFilter = .all
    @Published var searchError: String?
    @Published var activePanel: AppFeaturePanel?
    @Published var previewVisible = false
    @Published var thumbnailView = false
    @Published var previewAllowsNetwork = false
    @Published var folderScope: FolderScope?
    @Published var folderSidebarVisible = false
    @Published var indexedFolderTotals = false
    @Published var indexedTotalsColumnOverride: Bool?
    lazy var folderDetails = FolderDetailsModel(index: index.searchIndex)
    @Published var selectedRecords: [FileRecord] = []
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

    var actionRecords: [FileRecord] {
        selectedRecords.isEmpty ? selected.map { [$0] } ?? [] : selectedRecords
    }

    let index: IndexActor
    let preferences: UserDefaults
    let workspace: SearchWorkspaceController
    private var task: Task<Void, Never>?
    private var liveTask: Task<Void, Never>?
    private var flushTimer: Task<Void, Never>?
    private var cloudSweepTimer: Task<Void, Never>?
    private var fdaPollTask: Task<Void, Never>?
    private var shareCheckTimer: Task<Void, Never>?
    private var bootstrapped = false
    private var indexStarted = false
    private var searchSeq = 0
    private var searchTask: Task<SearchReport, Never>?
    private var rebuildTask: Task<Void, Never>?
    private var activeScanID: UUID?
    private weak var backgroundOwner: AppModel?
    private var backgroundSubscriptions: Set<AnyCancellable> = []
    private var loadedCatalogStore: CatalogStore?

    var catalogStore: CatalogStore {
        if let backgroundOwner { return backgroundOwner.catalogStore }
        if let loadedCatalogStore { return loadedCatalogStore }
        let store = CatalogStore(nativeIndex: index.searchIndex)
        loadedCatalogStore = store
        return store
    }

    init(index: IndexActor = IndexActor(), preferences: UserDefaults = .standard,
         workspace: SearchWorkspaceController? = nil) {
        self.index = index
        self.preferences = preferences
        self.workspace = workspace ?? SearchWorkspaceController(library:
            preferences === UserDefaults.standard ? .shared : WorkspaceLibrary(preferences: preferences))
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

    // Windows have independent search state while one owner starts and updates
    // the shared index. Only the owner runs filesystem timers and rebuilds.
    func prepareWindow(with background: AppModel) {
        guard !bootstrapped else { return }
        bootstrapped = true
        backgroundOwner = background
        loadPrefs()
        total = background.total; scanning = background.scanning; shares = background.shares
        rules = background.rules; fdaGranted = background.fdaGranted
        awaitingFullDiskAccess = background.awaitingFullDiskAccess
        background.$total.sink { [weak self] value in self?.total = value }
            .store(in: &backgroundSubscriptions)
        background.$scanning.sink { [weak self] value in self?.scanning = value }
            .store(in: &backgroundSubscriptions)
        background.$shares.sink { [weak self] value in self?.shares = value }
            .store(in: &backgroundSubscriptions)
        background.$rules.sink { [weak self] value in self?.rules = value }
            .store(in: &backgroundSubscriptions)
        background.$fdaGranted.sink { [weak self] value in self?.fdaGranted = value }
            .store(in: &backgroundSubscriptions)
        background.$awaitingFullDiskAccess.sink { [weak self] value in self?.awaitingFullDiskAccess = value }
            .store(in: &backgroundSubscriptions)
        background.$indexRevision.sink { [weak self] revision in
            self?.indexRevision = revision
            self?.refreshFolderDetailsIfNeeded()
            Task { @MainActor [weak self] in await self?.runSearch() }
        }.store(in: &backgroundSubscriptions)
    }

    func continueWithoutFullDiskAccess() {
        if let backgroundOwner { backgroundOwner.continueWithoutFullDiskAccess(); return }
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
                indexDidChange()
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
        workspaceStateChanged()
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
        let query: Query
        do { query = try resolvedWorkspaceQuery() }
        catch {
            // Source: the saved-query expansion's actual error for this workspace.
            searchError = error.localizedDescription; results = []; totalMatches = 0; resultSnapshotID = nil; return
        }
        if let error = query.validationError {
            // Source: the parser's validation error for the owner's entered query.
            searchError = error.localizedDescription
            results = []
            totalMatches = 0; resultSnapshotID = nil
            return
        }
        searchError = nil
        let sort = sortKey, ascending = ascending, limit = resultLimit, scope = folderScope
        let worker = Task {
            await index.searchIndex.searchReport(query, sort: sort, ascending: ascending, limit: limit, scope: scope)
        }
        searchTask = worker
        let r = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
        // Only the most recently started search may publish — stops a slower
        // in-flight search (e.g. from a live-refresh tick) clobbering newer
        // results with a stale sort order.
        if mySeq == searchSeq && !Task.isCancelled && !worker.isCancelled {
            results = r.records
            totalMatches = r.totalMatches
            resultSnapshotID = r.snapshotID
            recordCompletedWorkspaceSearch()
        }
    }

    // Coalesce bursts of FSEvents into at most one refresh per 200ms.
    func liveRefresh() {
        liveTask?.cancel()
        liveTask = Task {
            try? await Task.sleep(nanoseconds: 200_000_000)
            if Task.isCancelled { return }
            if !scanning { total = index.totalCount }
            indexDidChange()
            await runSearch()
        }
    }

    private func indexDidChange() {
        indexRevision &+= 1
        loadedCatalogStore?.refreshNative()
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

    func setFolderScope(_ scope: FolderScope?) {
        folderScope = scope
        workspaceStateChanged()
        Task { await runSearch() }
    }

    func setFolderTotals(_ visible: Bool) {
        indexedFolderTotals = visible
        indexedTotalsColumnOverride = visible
        savePrefs()
        refreshFolderDetailsIfNeeded()
    }

    func indexedColumnsChanged(_ visible: Bool) {
        indexedTotalsColumnOverride = nil
        guard indexedFolderTotals != visible else { return }
        indexedFolderTotals = visible
        savePrefs()
        refreshFolderDetailsIfNeeded()
    }

    func refreshFolderDetailsIfNeeded() {
        if indexedFolderTotals || folderSidebarVisible { folderDetails.refresh() }
        else { folderDetails.cancel() }
    }

    func selectRecords(_ records: [FileRecord]) {
        let recordsByID = Dictionary(results.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        selectedRecords = records.filter { selected in
            recordsByID[selected.id]?.path.utf8.elementsEqual(selected.path.utf8) == true
        }
        selectedID = selectedRecords.first?.id
        updateQuickLookSelection()
    }

    func updateQuickLookSelection() {
        guard let window = NSApp.mainWindow ?? NSApp.keyWindow,
              SearchWindowRegistry.shared.model(for: window) === self else { return }
        QuickLookController.shared.updateSelection(actionRecords, allowsNetwork: previewAllowsNetwork)
    }

    var currentQuery: Query {
        let base = Query(text: query, matchPath: matchPath,
              caseInsensitive: !caseSensitive, wholeWord: wholeWord, fuzzy: fuzzy,
              regex: regex, diacriticInsensitive: diacriticInsensitive,
              matchPrefix: matchPrefix, matchSuffix: matchSuffix,
              ignorePunctuation: ignorePunctuation, ignoreWhitespace: ignoreWhitespace)
        return searchFilter.applying(to: base)
    }

    var featureQueryResult: Result<Query, Error> {
        do {
            let resolved = try resolvedWorkspaceQuery()
            if let error = resolved.validationError { throw error }
            return .success(resolved)
        } catch { return .failure(error) }
    }

    // MARK: - Search preference persistence (UserDefaults)

    func loadPrefs() {
        let d = preferences
        matchPath = d.bool(forKey: "pref.matchPath")
        caseSensitive = d.bool(forKey: "pref.caseSensitive")
        wholeWord = d.bool(forKey: "pref.wholeWord")
        let hasFuzzyPref = d.object(forKey: "pref.fuzzy") != nil
        fuzzy = hasFuzzyPref ? d.bool(forKey: "pref.fuzzy") : true
        regex = d.bool(forKey: "pref.regex")
        diacriticInsensitive = d.bool(forKey: "pref.diacriticInsensitive")
        matchPrefix = d.bool(forKey: "pref.matchPrefix")
        matchSuffix = d.bool(forKey: "pref.matchSuffix")
        ignorePunctuation = d.bool(forKey: "pref.ignorePunctuation")
        ignoreWhitespace = d.bool(forKey: "pref.ignoreWhitespace")
        if let name = d.string(forKey: "pref.searchFilter"), let filter = SearchFilter(rawValue: name) {
            searchFilter = filter
        }
        previewVisible = d.bool(forKey: "pref.previewVisible")
        thumbnailView = d.bool(forKey: "pref.thumbnailView")
        previewAllowsNetwork = d.bool(forKey: "pref.previewAllowsNetwork")
        folderSidebarVisible = d.bool(forKey: "pref.folderSidebarVisible")
        indexedFolderTotals = d.bool(forKey: "pref.indexedFolderTotals")
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
        d.set(regex, forKey: "pref.regex")
        d.set(diacriticInsensitive, forKey: "pref.diacriticInsensitive")
        d.set(matchPrefix, forKey: "pref.matchPrefix")
        d.set(matchSuffix, forKey: "pref.matchSuffix")
        d.set(ignorePunctuation, forKey: "pref.ignorePunctuation")
        d.set(ignoreWhitespace, forKey: "pref.ignoreWhitespace")
        d.set(searchFilter.rawValue, forKey: "pref.searchFilter")
        d.set(previewVisible, forKey: "pref.previewVisible")
        d.set(thumbnailView, forKey: "pref.thumbnailView")
        d.set(previewAllowsNetwork, forKey: "pref.previewAllowsNetwork")
        d.set(folderSidebarVisible, forKey: "pref.folderSidebarVisible")
        d.set(indexedFolderTotals, forKey: "pref.indexedFolderTotals")
        d.set(resultLimit, forKey: "pref.resultLimit")
        d.set(Self.sortKeyName(sortKey), forKey: "pref.sortKey")
        d.set(ascending, forKey: "pref.ascending")
        workspaceStateChanged()
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
        if let backgroundOwner { backgroundOwner.rebuildIndex(); return }
        guard !scanning else { return }
        beginRebuild(rules: nil)
    }

    func applyRules(_ newRules: ExcludeRules) {
        if let backgroundOwner { backgroundOwner.applyRules(newRules); return }
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
            indexDidChange()
            await runSearch()
        }
    }
}
