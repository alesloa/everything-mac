import Foundation

/// Export folder scope uses actual parent IDs in the captured FileStore, so
/// lookalike prefixes and a stale/reused numeric folder ID cannot widen export.
enum CatalogNativeScope {
    static func candidates(folderPath: String?, in store: FileStore,
                           isCancelled: @Sendable () -> Bool) throws -> [UInt32]? {
        guard let folderPath else { return nil }
        var folder: UInt32?
        for row in 0..<store.count {
            if row & 255 == 0 && isCancelled() { throw CancellationError() }
            let id = UInt32(row)
            if store.isLive(id), store.isDir(of: id), store.path(of: id).utf8.elementsEqual(folderPath.utf8) {
                folder = id; break
            }
        }
        guard let folder else { throw CatalogError.invalidScope("The selected folder is absent from the index snapshot: \(folderPath)") }
        var candidates: [UInt32] = []
        for row in 0..<store.count {
            if row & 255 == 0 && isCancelled() { throw CancellationError() }
            let id = UInt32(row)
            guard store.isLive(id), id != folder else { continue }
            var parent = store.parent(of: id), visited = 0
            while parent != FileStore.noParent && Int(parent) < store.count && visited < store.count {
                if visited & 255 == 0 && isCancelled() { throw CancellationError() }
                if parent == folder { candidates.append(id); break }
                parent = store.parent(of: parent); visited += 1
            }
        }
        return candidates
    }
}
