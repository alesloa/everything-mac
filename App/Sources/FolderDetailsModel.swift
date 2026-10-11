import SwiftUI
import IndexCore

@MainActor final class FolderDetailsModel: ObservableObject {
    @Published private(set) var snapshot: FolderSnapshot?
    private let index: SearchIndex
    private var task: Task<Void, Never>?
    private var request = UUID()

    init(index: SearchIndex) { self.index = index }

    func refresh() {
        task?.cancel()
        let request = UUID()
        self.request = request
        task = Task { [weak self, index] in
            let next = await index.folderSnapshot()
            guard !Task.isCancelled, let self, self.request == request else { return }
            self.snapshot = next
        }
    }

    func cancel() { task?.cancel(); task = nil }
    deinit { task?.cancel() }
}
