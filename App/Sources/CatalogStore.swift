import AppKit
import Foundation
import Observation
import IndexCore

// Scope/export names implement the owner's requested catalog and export controls.
enum CatalogSearchScope: String, CaseIterable, Identifiable {
    case catalogs, catalogsAndNative
    var id: String { rawValue }
    var label: String { self == .catalogs ? "Catalogs only" : "Catalogs and live index" }
}
enum CatalogExportScope: String, CaseIterable, Identifiable, Sendable {
    case selected, shown, allMatching
    var id: String { rawValue }
    var label: String {
        switch self { case .selected: "Selected rows"; case .shown: "Shown rows"; case .allMatching: "All matching rows" }
    }
}
struct CatalogDescriptor: Identifiable {
    let id: UUID
    // Name and count come from the imported file and its validated snapshot.
    let name: String
    let count: Int
}

@MainActor @Observable final class CatalogStore {
    private(set) var catalogs: [CatalogDescriptor] = []
    private(set) var rows: [CatalogSearchHit] = []
    private(set) var matchCount = 0
    private(set) var isSearching = false
    private(set) var isWorking = false
    // Error text comes from the thrown parser, filesystem, or OS operation error.
    var errorMessage: String?
    var scope: CatalogSearchScope = .catalogs { didSet { search() } }
    var catalogID: UUID? { didSet { search() } }
    var query = Query(text: "") { didSet { search() } }
    var sort: CatalogSort = .name { didSet { search() } }
    var ascending = true { didSet { search() } }
    var resultLimit = 5000 { didSet { search() } }
    var selection: Set<CatalogResultID> = []
    private(set) var mappings: [UUID: CatalogPathMapping] = [:]
    @ObservationIgnored private var snapshots: [UUID: FileCatalogSnapshot] = [:]
    @ObservationIgnored private let nativeIndex: SearchIndex?
    @ObservationIgnored private let directory: URL
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var searchCancellation: CatalogWorkCancellation?
    @ObservationIgnored private var operationTask: Task<Void, Never>?
    @ObservationIgnored private var operationCancellation: CatalogWorkCancellation?
    @ObservationIgnored private var searchRevision = UUID()

    init(nativeIndex: SearchIndex? = nil, directory: URL? = nil) {
        self.nativeIndex = nativeIndex
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Everything-Mac/Catalogs", isDirectory: true)
        restore()
    }

    func configure(query: Query, resultLimit: Int) {
        self.resultLimit = resultLimit; self.query = query
    }
    func refreshNative() { if scope == .catalogsAndNative { search() } }
    func cancelWork() { operationCancellation?.cancel(); operationTask?.cancel() }
    private func selectedSnapshots() -> [FileCatalogSnapshot] {
        catalogs.filter { catalogID == nil || $0.id == catalogID }.compactMap { snapshots[$0.id] }
    }

    func search() {
        searchCancellation?.cancel(); searchTask?.cancel()
        let cancellation = CatalogWorkCancellation(), revision = UUID()
        searchCancellation = cancellation; searchRevision = revision
        let selected = selectedSnapshots(), index = scope == .catalogsAndNative ? nativeIndex : nil
        let query = query, sort = sort, ascending = ascending, limit = resultLimit
        isSearching = true
        searchTask = Task { [weak self] in
            do {
                let page = try await Task.detached(priority: .userInitiated) {
                    try CatalogSearch.search(selected, native: index?.readSnapshot(), query: query,
                        sort: sort, ascending: ascending, limit: limit, isCancelled: { cancellation.isCancelled })
                }.value
                guard let self, self.searchRevision == revision, !cancellation.isCancelled else { return }
                rows = page.hits; matchCount = page.totalMatches
                selection.formIntersection(Set(rows.map(\.id))); isSearching = false
            } catch {
                guard let self, self.searchRevision == revision else { return }
                if !(error is CancellationError) { errorMessage = error.localizedDescription; rows = []; matchCount = 0 }
                isSearching = false
            }
        }
    }

    func importCatalog(_ source: URL) {
        guard !isWorking else { return }
        let cancellation = beginOperation(), id = UUID(), directory = directory
        let destination = directory.appendingPathComponent(id.uuidString + ".efcatalog")
        operationTask = Task { [weak self] in
            do {
                let snapshot = try await Task.detached(priority: .utility) {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    do { return try CatalogIO.importFile(from: source, to: destination, id: id, isCancelled: { cancellation.isCancelled }) }
                    catch { try? FileManager.default.removeItem(at: destination); throw error }
                }.value
                guard let self else { return }
                snapshots[id] = snapshot
                catalogs.append(CatalogDescriptor(id: id, name: snapshot.sourceName, count: snapshot.count))
                isWorking = false; search()
            } catch { self?.finishOperation(error) }
        }
    }

    func removeCatalog(_ id: UUID) {
        guard !isWorking, let snapshot = snapshots[id] else { return }
        let cancellation = beginOperation(), url = snapshot.url
        operationTask = Task { [weak self] in
            do {
                try await Task.detached(priority: .utility) {
                    if cancellation.isCancelled { throw CancellationError() }
                    try FileManager.default.removeItem(at: url)
                }.value
                guard let self else { return }
                snapshots[id] = nil; catalogs.removeAll { $0.id == id }; mappings[id] = nil
                if catalogID == id { catalogID = nil }
                isWorking = false; persistMappings(); search()
            } catch { self?.finishOperation(error) }
        }
    }

    func setMapping(for id: UUID, prefix: String, root: URL) {
        mappings[id] = CatalogPathMapping(sourcePrefix: prefix, localRoot: root); persistMappings()
    }
    func clearMapping(for id: UUID) { mappings[id] = nil; persistMappings() }
    func canOpen(_ hit: CatalogSearchHit) -> Bool { hit.nativeRecord != nil || mappings[hit.record.id.catalog] != nil }

    func open(_ hit: CatalogSearchHit) {
        let mapping = mappings[hit.record.id.catalog]
        // Native paths originate in the immutable index snapshot. Catalog paths
        // originate in imported data and require the owner's explicit mapping.
        guard hit.nativeRecord != nil || mapping != nil else { return }
        Task { [weak self] in
            do {
                let url = try await Task.detached(priority: .userInitiated) {
                    let url = try mapping.map { try $0.resolve(hit.record.path) } ?? URL(fileURLWithPath: hit.record.path)
                    guard FileManager.default.fileExists(atPath: url.path) else {
                        throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: url.path])
                    }
                    return url
                }.value
                guard NSWorkspace.shared.open(url) else {
                    throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: url.path])
                }
            } catch { self?.errorMessage = error.localizedDescription }
        }
    }

    func export(to url: URL, format: CatalogFormat, scope exportScope: CatalogExportScope) {
        guard !isWorking else { return }
        let cancellation = beginOperation(), selected = selectedSnapshots()
        let index = scope == .catalogsAndNative ? nativeIndex : nil, query = query
        let records = (exportScope == .selected ? rows.filter { selection.contains($0.id) } : rows).map(\.record)
        operationTask = Task { [weak self] in
            do {
                _ = try await Task.detached(priority: .utility) {
                    if exportScope == .allMatching {
                        return try CatalogIO.exportMatching(selected, native: index?.readSnapshot(), query: query,
                            to: url, format: format, isCancelled: { cancellation.isCancelled })
                    }
                    return try CatalogIO.exportRows(records, to: url, format: format, isCancelled: { cancellation.isCancelled })
                }.value
                self?.isWorking = false
            } catch { self?.finishOperation(error) }
        }
    }

    private func beginOperation() -> CatalogWorkCancellation {
        let cancellation = CatalogWorkCancellation()
        operationCancellation = cancellation; isWorking = true; errorMessage = nil
        return cancellation
    }
    private func finishOperation(_ error: Error) {
        isWorking = false
        if !(error is CancellationError) { errorMessage = error.localizedDescription }
    }
    private func restore() {
        let directory = directory, cancellation = beginOperation()
        operationTask = Task { [weak self] in
            do {
                let restored = try await Task.detached(priority: .utility) {
                    if cancellation.isCancelled { throw CancellationError() }
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                    var snapshots: [FileCatalogSnapshot] = []
                    var failures: [String] = []
                    for url in urls where url.pathExtension == "efcatalog" {
                        if cancellation.isCancelled { throw CancellationError() }
                        do {
                            snapshots.append(try CatalogIO.load(from: url, isCancelled: { cancellation.isCancelled }))
                        } catch {
                            if error is CancellationError || cancellation.isCancelled { throw CancellationError() }
                            // Source: the saved file's actual path and its parser/filesystem error.
                            failures.append("\(url.path): \(error.localizedDescription)")
                        }
                    }
                    let mappingURL = directory.appendingPathComponent("mappings.json")
                    var mappings: [UUID: CatalogPathMapping] = [:]
                    if FileManager.default.fileExists(atPath: mappingURL.path) {
                        do {
                            mappings = try JSONDecoder().decode([UUID: CatalogPathMapping].self, from: Data(contentsOf: mappingURL))
                        } catch {
                            if error is CancellationError || cancellation.isCancelled { throw CancellationError() }
                            failures.append("\(mappingURL.path): \(error.localizedDescription)")
                        }
                    }
                    if cancellation.isCancelled { throw CancellationError() }
                    return (snapshots, mappings, failures)
                }.value
                guard let self else { return }
                if cancellation.isCancelled { throw CancellationError() }
                for snapshot in restored.0 {
                    snapshots[snapshot.id] = snapshot
                    if !catalogs.contains(where: { $0.id == snapshot.id }) {
                        catalogs.append(CatalogDescriptor(id: snapshot.id, name: snapshot.sourceName, count: snapshot.count))
                    }
                }
                mappings = restored.1
                errorMessage = restored.2.isEmpty ? nil : restored.2.joined(separator: "\n")
                isWorking = false; search()
            } catch { self?.finishOperation(error) }
        }
    }
    private func persistMappings() {
        // The owner's mapping preferences are small; atomic Foundation writes
        // avoid partial settings. Catalog bytes never run through this path.
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(mappings).write(to: directory.appendingPathComponent("mappings.json"), options: .atomic)
        } catch { errorMessage = error.localizedDescription }
    }
}

final class CatalogWorkCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
}
