import Foundation

/// A single shared job gate bounds actual I/O even when panels are repeatedly
/// closed/reopened. A cancelled job retains its permit until all admitted workers
/// return from syscalls. Waiting jobs are removed immediately on cancellation.
actor ContentSearchJobGate {
    static let shared = ContentSearchJobGate()
    private var occupied = false
    private var waiting: [(UUID, SearchCancellation, CheckedContinuation<Void, Error>)] = []

    func acquire(_ id: UUID, cancellation: SearchCancellation) async throws {
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if cancellation.isCancelled || Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else if !occupied { occupied = true; continuation.resume() }
                else { waiting.append((id, cancellation, continuation)) }
            }
        } onCancel: {
            cancellation.cancel()
            Task { await self.cancel(id) }
        }
    }
    private func cancel(_ id: UUID) {
        guard let index = waiting.firstIndex(where: { $0.0 == id }) else { return }
        waiting.remove(at: index).2.resume(throwing: CancellationError())
    }
    func release() {
        while !waiting.isEmpty {
            let item = waiting.removeFirst()
            if item.1.isCancelled { item.2.resume(throwing: CancellationError()); continue }
            item.2.resume(); return
        }
        occupied = false
    }
}

public enum ContentSearchService {
    /// Updates contain a bounded cumulative result snapshot. A slow consumer
    /// receives the latest complete snapshot rather than an unbounded event queue.
    public static func events(index: SearchIndex, request: ContentSearchRequest) -> AsyncStream<ContentSearchProgress> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let cancellation = SearchCancellation()
            let worker = Task.detached(priority: .utility) {
                var progress = ContentSearchProgress()
                var acquired = false
                do {
                    let options = try request.options.validated()
                    guard !request.literal.isEmpty, request.literal.unicodeScalars.count <= 1_024,
                          ContentSearchMatcher(literal: request.literal, options: options).valid else {
                        throw ContentSearchValidationError.invalidLiteral
                    }
                    if request.restrictToFilenameQuery {
                        guard let query = request.filenameQuery else { throw ContentSearchValidationError.missingQuery }
                        if let error = query.validationError { throw error }
                    }
                    try await ContentSearchJobGate.shared.acquire(UUID(), cancellation: cancellation)
                    acquired = true
                    let store = index.readSnapshot()
                    let candidates = try candidates(request: request, store: store, cancellation: cancellation)
                    progress.candidates = candidates.count
                    continuation.yield(progress)
                    await search(candidates: candidates, store: store, request: request, options: options,
                                 cancellation: cancellation, progress: &progress, continuation: continuation)
                } catch is CancellationError {
                    progress.cancelled = true
                } catch {
                    if !cancellation.isCancelled { progress.failure = error.localizedDescription }
                }
                if acquired { await ContentSearchJobGate.shared.release() }
                progress.cancelled = progress.cancelled || cancellation.isCancelled || Task.isCancelled
                progress.finished = true
                continuation.yield(progress)
                continuation.finish()
            }
            continuation.onTermination = { @Sendable _ in cancellation.cancel(); worker.cancel() }
        }
    }

    private static func candidates(request: ContentSearchRequest, store: FileStore,
                                   cancellation: SearchCancellation) throws -> [UInt32] {
        let isCancelled: @Sendable () -> Bool = { cancellation.isCancelled || Task.isCancelled }
        var scope = try CatalogNativeScope.candidates(folderPath: request.folderPath, folderSelection: request.folderSelection,
                                                     in: store, isCancelled: isCancelled)
        if let picked = request.pickedFolderPath {
            let pickedIDs = try CatalogNativeScope.candidates(folderPath: picked, in: store, isCancelled: isCancelled) ?? []
            if let current = scope {
                let allowed = Set(pickedIDs)
                scope = current.filter { allowed.contains($0) }
            } else { scope = pickedIDs }
        }
        let ids: [UInt32]
        if request.restrictToFilenameQuery {
            guard let query = request.filenameQuery, query.validationError == nil else {
                throw ContentSearchValidationError.missingQuery
            }
            // QueryEngine searches the entire immutable snapshot; no UI row cap
            // and no substitute empty query can broaden a missing/invalid query.
            ids = QueryEngine().search(query.refreshingRelativeDates(), in: store,
                                       candidates: scope, isCancelled: isCancelled)
        } else { ids = scope ?? Array(0..<UInt32(store.count)) }
        var supported: [UInt32] = []
        for (position, id) in ids.enumerated() {
            if position & 255 == 0 && isCancelled() { throw CancellationError() }
            guard store.isLive(id), !store.isDir(of: id), request.options.fileKind.supports(store.name(of: id)) else { continue }
            supported.append(id)
        }
        if isCancelled() { throw CancellationError() }
        return supported
    }

    private static func search(candidates: [UInt32], store: FileStore, request: ContentSearchRequest,
                               options: ContentSearchOptions, cancellation: SearchCancellation,
                               progress: inout ContentSearchProgress,
                               continuation: AsyncStream<ContentSearchProgress>.Continuation) async {
        let clock = ContinuousClock()
        var lastUpdate = clock.now
        await withTaskGroup(of: ContentSearchFileResult.self) { group in
            var next = 0
            func enqueue(_ id: UInt32) {
                let path = store.path(of: id)
                group.addTask {
                    ContentSearchReader.search(path: path, literal: request.literal, options: options,
                        isCancelled: { cancellation.isCancelled || Task.isCancelled })
                }
            }
            while next < min(options.concurrency, candidates.count), !cancellation.isCancelled {
                enqueue(candidates[next]); next += 1
            }
            while let result = await group.next() {
                progress.completed += 1; progress.bytesRead += result.bytesRead
                if result.searched { progress.searched += 1 } else { progress.skipped += 1 }
                if let hit = result.hit {
                    progress.matchingFiles += 1
                    if progress.results.count < options.maxResults { progress.results.append(hit) }
                }
                if let error = result.error, progress.errors.count < 100 { progress.errors.append(error) }
                if clock.now - lastUpdate >= .milliseconds(100) {
                    continuation.yield(progress); lastUpdate = clock.now
                }
                if cancellation.isCancelled || Task.isCancelled { group.cancelAll() }
                else if next < candidates.count { enqueue(candidates[next]); next += 1 }
            }
        }
        progress.results.sort {
            let order = $0.path.localizedStandardCompare($1.path)
            return order == .orderedSame ? $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) : order == .orderedAscending
        }
    }
}
