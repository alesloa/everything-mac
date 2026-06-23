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
    @Published var rules: ExcludeRules = .defaults
    @Published var scanning = false

    let index = IndexActor()
    private var task: Task<Void, Never>?
    private var liveTask: Task<Void, Never>?
    private var flushTimer: Task<Void, Never>?
    private var searchSeq = 0

    func bootstrap() {
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
        task?.cancel()
        task = Task {
            try? await Task.sleep(nanoseconds: 40_000_000) // debounce 40ms
            if Task.isCancelled { return }
            await runSearch()
        }
    }

    func runSearch() async {
        searchSeq &+= 1
        let mySeq = searchSeq
        let r = await index.search(query, matchPath: matchPath, sort: sortKey, ascending: ascending)
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
