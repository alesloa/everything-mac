import Foundation
import Observation
import IndexCore

@MainActor @Observable final class DuplicateFinderModel {
    private(set) var running = false
    private(set) var progress: DuplicateProgress?
    private(set) var report: DuplicateReport?
    private(set) var comparison: FolderComparisonReport?
    private var task: Task<Void, Never>?
    private var generation = UUID()

    func find(_ scope: DuplicateScope, method: DuplicateMethod, options: DuplicateOptions) {
        prepare()
        let request = generation
        task = Task {
            let result = await DuplicateFinder().find(in: scope, method: method, options: options,
                progress: progressCallback(request))
            guard generation == request else { return }
            report = result
            running = false
            task = nil
        }
    }

    func compare(_ left: String, _ right: String, options: DuplicateOptions) {
        prepare()
        let request = generation
        task = Task {
            let result = await DuplicateFinder().compareFolders(left, right, options: options,
                progress: progressCallback(request))
            guard generation == request else { return }
            comparison = result
            running = false
            task = nil
        }
    }

    func cancel() { task?.cancel() }

    func stop() {
        generation = UUID()
        task?.cancel()
        task = nil
        running = false
    }

    private func prepare() {
        stop()
        report = nil; comparison = nil; progress = nil
        running = true
    }

    private func progressCallback(_ request: UUID) -> @Sendable (DuplicateProgress) -> Void {
        { [weak self] value in
            Task { @MainActor in
                guard let self, self.generation == request, self.running else { return }
                self.progress = value
            }
        }
    }
}
