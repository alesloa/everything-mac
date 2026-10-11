import Foundation
import AppKit
import IndexCore

@main struct CatalogAppSafety {
    @MainActor static func settle(_ store: CatalogStore) async throws {
        for _ in 0..<500 {
            if !store.isWorking && !store.isSearching { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw CocoaError(.userCancelled)
    }
    @MainActor static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("catalog-app-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var native = FileStore()
        native.append(name: "/native-file.txt", parent: FileStore.noParent, size: 1, mtime: 1, isDir: false, volID: 1)
        let index = SearchIndex(); index.publish(native)
        let store = CatalogStore(nativeIndex: index, directory: directory.appendingPathComponent("saved"))
        try await settle(store)
        let source = directory.appendingPathComponent("offline.efu")
        try Data("Filename,Size\nC:\\Archive\\catalog-file.txt,\n".utf8).write(to: source)
        store.importCatalog(source); try await settle(store)
        precondition(store.catalogs.count == 1 && store.rows.count == 1 && store.rows[0].record.size == nil)
        let catalog = store.rows[0]
        precondition(!store.canOpen(catalog), "Imported paths must require an explicit mapping")
        store.scope = .catalogsAndNative; try await settle(store)
        precondition(store.rows.count == 2 && store.matchCount == 2)
        precondition(Set(store.rows.map(\.id)).count == 2, "Native numeric IDs must not collide with catalog rows")
        let oldNative = try store.rows.first(where: { $0.nativeRecord != nil }).unwrap()
        store.selection = [oldNative.id]
        var rebuilt = FileStore()
        rebuilt.append(name: "/replacement.txt", parent: FileStore.noParent, size: 2, mtime: 1, isDir: false, volID: 1)
        index.publish(rebuilt); store.refreshNative(); try await settle(store)
        precondition(store.selection.isEmpty, "Reused native IDs must not redirect the catalog browser selection")
        store.resultLimit = 1; try await settle(store)
        let exported = directory.appendingPathComponent("all.csv")
        store.export(to: exported, format: .csv, scope: .allMatching); try await settle(store)
        let copy = try CatalogIO.importFile(from: exported, to: directory.appendingPathComponent("copy.efcatalog"))
        precondition(copy.count == 2, "All matching export must ignore the displayed row limit")
        let mappingRoot = directory.appendingPathComponent("root")
        try FileManager.default.createDirectory(at: mappingRoot, withIntermediateDirectories: true)
        store.setMapping(for: catalog.record.id.catalog, prefix: "C:\\Archive", root: mappingRoot)
        precondition(store.canOpen(catalog))
        let reopened = CatalogStore(nativeIndex: index, directory: directory.appendingPathComponent("saved"))
        try await settle(reopened)
        precondition(reopened.catalogs.count == 1 && reopened.mappings[catalog.record.id.catalog] != nil)
        reopened.removeCatalog(catalog.record.id.catalog); try await settle(reopened)
        precondition(reopened.catalogs.isEmpty && reopened.rows.isEmpty && index.count == 1,
                     "Removing an imported catalog must not mutate the native index")
        print("PASS: catalog scope, native identity isolation, uncapped exports, mapping persistence and independent removal")
    }
}

private extension Optional {
    func unwrap() throws -> Wrapped { guard let value = self else { throw CocoaError(.fileReadUnknown) }; return value }
}
