import Foundation

/// A per-search union of folder branches with optional branches subtracted.
/// Empty includes mean the entire published index. Included folders contribute
/// their descendants; excluded folders remove themselves and their descendants.
public struct FolderSearchScope: Sendable, Equatable {
    public var included: [FolderScope]
    public var excluded: [FolderScope]

    public init(included: [FolderScope] = [], excluded: [FolderScope] = []) {
        self.included = Self.uniquePaths(included)
        self.excluded = Self.uniquePaths(excluded)
    }

    private static func uniquePaths(_ scopes: [FolderScope]) -> [FolderScope] {
        var seen = Set<[UInt8]>()
        return scopes.filter { seen.insert(Array($0.path.utf8)).inserted }
    }
}

/// Resolve once against this immutable publication, then walk each candidate's
/// ancestry once regardless of how many branches the user selected. Paths keep
/// exact UTF-8 spelling; persisted numeric IDs are only verified hints.
struct ResolvedFolderSearchScope: Sendable {
    let includesAll: Bool
    let included: Set<UInt32>
    let excluded: Set<UInt32>
    let missingIncludedPaths: [String]

    var isUnrestricted: Bool { includesAll && excluded.isEmpty }

    init(_ selection: FolderSearchScope, in store: FileStore,
         isCancelled: @Sendable () -> Bool) throws {
        if isCancelled() { throw CancellationError() }
        let scopes = selection.included + selection.excluded
        var resolved: [[UInt8]: UInt32] = [:]
        var unresolved = Set(scopes.map { Array($0.path.utf8) })
        for scope in scopes {
            if isCancelled() { throw CancellationError() }
            let path = Array(scope.path.utf8)
            if let id = scope.id, store.isLive(id), store.isDir(of: id),
               try Self.pathBytes(of: id, in: store, isCancelled: isCancelled) == path {
                resolved[path] = id
                unresolved.remove(path)
            }
        }
        // A single directory pass resolves all remaining paths, rather than
        // rescanning the index for every selected root. Comparing the basename
        // first avoids reconstructing unrelated full paths on large indexes.
        if !unresolved.isEmpty {
            let wantedNames = Set(unresolved.map(Self.lastComponent))
            for row in 0..<store.count {
                if row & 255 == 0 && isCancelled() { throw CancellationError() }
                let id = UInt32(row)
                guard store.isLive(id), store.isDir(of: id),
                      wantedNames.contains(Self.lastComponent(Array(store.name(of: id).utf8))),
                      let path = try Self.pathBytes(of: id, in: store, isCancelled: isCancelled),
                      unresolved.remove(path) != nil else { continue }
                resolved[path] = id
                if unresolved.isEmpty { break }
            }
        }
        includesAll = selection.included.isEmpty
        included = Set(selection.included.compactMap { resolved[Array($0.path.utf8)] })
        excluded = Set(selection.excluded.compactMap { resolved[Array($0.path.utf8)] })
        var missing = Set<[UInt8]>()
        missingIncludedPaths = selection.included.compactMap {
            let bytes = Array($0.path.utf8)
            return resolved[bytes] == nil && missing.insert(bytes).inserted ? $0.path : nil
        }
        if isCancelled() { throw CancellationError() }
    }

    func contains(_ id: UInt32, in store: FileStore,
                  isCancelled: @Sendable () -> Bool) throws -> Bool {
        guard store.isLive(id), !excluded.contains(id), includesAll || !included.isEmpty else { return false }
        var allowed = includesAll
        var parent = store.parent(of: id), visited = 0
        while parent != FileStore.noParent {
            if visited & 255 == 255 && isCancelled() { throw CancellationError() }
            guard visited < store.count, store.isLive(parent), store.isDir(of: parent) else { return false }
            if excluded.contains(parent) { return false }
            if included.contains(parent) { allowed = true }
            parent = store.parent(of: parent)
            visited += 1
        }
        return allowed
    }

    func filter<Element>(_ values: [Element], id: (Element) -> UInt32, in store: FileStore,
                         isCancelled: @Sendable () -> Bool) throws -> [Element] {
        if isCancelled() { throw CancellationError() }
        if isUnrestricted { return values }
        if !includesAll && included.isEmpty { return [] }
        var filtered: [Element] = []
        for (offset, value) in values.enumerated() {
            if offset & 255 == 0 && isCancelled() { throw CancellationError() }
            if try contains(id(value), in: store, isCancelled: isCancelled) { filtered.append(value) }
        }
        if isCancelled() { throw CancellationError() }
        return filtered
    }

    func candidates(in store: FileStore, isCancelled: @Sendable () -> Bool) throws -> [UInt32]? {
        if isCancelled() { throw CancellationError() }
        if isUnrestricted { return nil }
        if !includesAll && included.isEmpty { return [] }
        var ids: [UInt32] = []
        for row in 0..<store.count {
            if row & 255 == 0 && isCancelled() { throw CancellationError() }
            let id = UInt32(row)
            if try contains(id, in: store, isCancelled: isCancelled) { ids.append(id) }
        }
        if isCancelled() { throw CancellationError() }
        return ids
    }

    private static func lastComponent(_ path: [UInt8]) -> [UInt8] {
        if path == [47] { return path }
        return path.lastIndex(of: 47).map { Array(path[($0 + 1)...]) } ?? path
    }

    private static func pathBytes(of id: UInt32, in store: FileStore,
                                  isCancelled: @Sendable () -> Bool) throws -> [UInt8]? {
        var components: [[UInt8]] = [], current = id
        while current != FileStore.noParent {
            if components.count & 255 == 0 && isCancelled() { throw CancellationError() }
            guard components.count < store.count, store.isLive(current), store.isDir(of: current) else { return nil }
            components.append(Array(store.name(of: current).utf8))
            current = store.parent(of: current)
        }
        var path: [UInt8] = []
        let slashRoot = components.last == [47]
        for (offset, component) in components.reversed().enumerated() {
            if offset & 255 == 0 && isCancelled() { throw CancellationError() }
            if offset > (slashRoot ? 1 : 0) { path.append(47) }
            path.append(contentsOf: component)
        }
        return path
    }
}
