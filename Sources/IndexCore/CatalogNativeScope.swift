import Foundation

/// Native search tools share the live search's exact-path, parent-ID scope.
enum CatalogNativeScope {
    static func resolve(folderPath: String?, folderSelection: FolderSearchScope? = nil,
                        in store: FileStore, isCancelled: @Sendable () -> Bool) throws -> ResolvedFolderSearchScope? {
        let selection = folderSelection ?? folderPath.map { FolderSearchScope(included: [FolderScope(path: $0)]) }
        guard let selection else { return nil }
        let resolved = try ResolvedFolderSearchScope(selection, in: store, isCancelled: isCancelled)
        if folderSelection == nil, let missing = resolved.missingIncludedPaths.first {
            // Source: the requested path and its absence from this captured index.
            throw CatalogError.invalidScope("The selected folder is absent from the index snapshot: \(missing)")
        }
        return resolved
    }

    static func candidates(folderPath: String?, folderSelection: FolderSearchScope? = nil,
                           in store: FileStore, isCancelled: @Sendable () -> Bool) throws -> [UInt32]? {
        try resolve(folderPath: folderPath, folderSelection: folderSelection, in: store, isCancelled: isCancelled)?
            .candidates(in: store, isCancelled: isCancelled)
    }
}
