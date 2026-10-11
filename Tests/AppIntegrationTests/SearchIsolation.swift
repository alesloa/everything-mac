import Foundation
import IndexCore

// Compiles against the actual app actor. This deliberate synchronous stall would
// hold every query for two seconds if search/count were actor-isolated again.
extension IndexActor {
    func simulateBlockedIndexing(entered: DispatchSemaphore, release: DispatchSemaphore) {
        entered.signal()
        _ = release.wait(timeout: .now() + 5)
    }
}

@main
struct SearchIsolation {
    static func main() async throws {
        let index = IndexActor()
        var store = FileStore()
        let root = store.append(name: "/", parent: FileStore.noParent, size: 0, mtime: 0, isDir: true, volID: 1)
        store.append(name: "FinalReport.pdf", parent: root, size: 1, mtime: 0, isDir: false, volID: 1)
        index.searchIndex.publish(store)
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let blocked = Task.detached { await index.simulateBlockedIndexing(entered: entered, release: release) }
        precondition(entered.wait(timeout: .now() + 5) == .success)
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { release.signal() }
        let clock = ContinuousClock(), started = clock.now
        precondition(index.totalCount == 2)
        let hits = await index.search("fnlrpt", matchPath: false, fuzzy: true,
                                      sort: .relevance, ascending: true)
        let elapsed = started.duration(to: clock.now)
        release.signal()
        await blocked.value
        precondition(hits.map(\.name) == ["FinalReport.pdf"])
        precondition(elapsed < .milliseconds(500), "Search waited behind indexing: \(elapsed)")
        print("PASS: search and count while the real IndexActor is blocked: \(elapsed)")
    }
}
