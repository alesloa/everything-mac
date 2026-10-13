import SwiftUI
import IndexCore

@MainActor final class FolderDetailsModel: ObservableObject {
    @Published private(set) var snapshot: FolderSnapshot?
    private let index: SearchIndex
    private let loadSnapshot: @Sendable (SearchIndex) async -> FolderSnapshot?
    private var task: Task<Void, Never>?
    private var request = UUID()

    init(index: SearchIndex,
         loadSnapshot: @escaping @Sendable (SearchIndex) async -> FolderSnapshot? = { await $0.folderSnapshot() }) {
        self.index = index
        self.loadSnapshot = loadSnapshot
    }

    func refresh() {
        task?.cancel()
        let request = UUID()
        self.request = request
        task = Task { [weak self, index, loadSnapshot] in
            let next = await loadSnapshot(index)
            guard !Task.isCancelled, let self, self.request == request else { return }
            self.snapshot = next
        }
    }

    func cancel() { task?.cancel(); task = nil }
    deinit { task?.cancel() }
}
