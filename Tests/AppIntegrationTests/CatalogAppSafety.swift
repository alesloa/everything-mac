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

        let isolatedDirectory = directory.appendingPathComponent("isolated-restore")
        try FileManager.default.createDirectory(at: isolatedDirectory, withIntermediateDirectories: false)
        let validURL = isolatedDirectory.appendingPathComponent("valid.efcatalog")
        let validSnapshot = try CatalogIO.importFile(from: source, to: validURL)
        let corruptURL = isolatedDirectory.appendingPathComponent("corrupt.efcatalog")
        let corruptBytes = Data("broken catalog".utf8)
        try corruptBytes.write(to: corruptURL, options: .withoutOverwriting)
        let mappingURL = isolatedDirectory.appendingPathComponent("mappings.json")
        let mappingBytes = Data("{broken mappings".utf8)
        try mappingBytes.write(to: mappingURL, options: .withoutOverwriting)
        let isolated = CatalogStore(directory: isolatedDirectory)
        try await settle(isolated)
        precondition(isolated.catalogs.count == 1 && isolated.catalogs[0].id == validSnapshot.id)
        precondition(isolated.rows.count == 1 && isolated.rows[0].record.path == "C:\\Archive\\catalog-file.txt",
                     "Valid catalogs must remain searchable when another catalog or mappings file is corrupt")
        precondition(isolated.mappings.isEmpty, "Failed mapping settings must not invent a mapping")
        let restoreError = try isolated.errorMessage.unwrap()
        precondition(restoreError.contains(corruptURL.path) && restoreError.contains(mappingURL.path),
                     "Restore errors must identify every offending saved file")
        do { _ = try CatalogIO.load(from: corruptURL); preconditionFailure("Corrupt catalog unexpectedly loaded") }
        catch { precondition(restoreError.contains(error.localizedDescription)) }
        do {
            _ = try JSONDecoder().decode([UUID: CatalogPathMapping].self, from: mappingBytes)
            preconditionFailure("Corrupt mappings unexpectedly decoded")
        } catch { precondition(restoreError.contains(error.localizedDescription)) }
        let savedCorruptBytes = try Data(contentsOf: corruptURL), savedMappingBytes = try Data(contentsOf: mappingURL)
        let retainedValid = try CatalogIO.load(from: validURL)
        precondition(savedCorruptBytes == corruptBytes && savedMappingBytes == mappingBytes,
                     "Restore must preserve corrupt owner files for recovery")
        precondition(retainedValid.count == 1)
        let cancelledRestore = CatalogStore(directory: isolatedDirectory)
        cancelledRestore.cancelWork()
        try await settle(cancelledRestore)
        precondition(cancelledRestore.catalogs.isEmpty && cancelledRestore.rows.isEmpty && cancelledRestore.mappings.isEmpty,
                     "Cancelled restore must not publish a partially loaded catalog collection")
        precondition(cancelledRestore.errorMessage == nil, "Cancellation must remain cancellation")
        print("PASS: catalog scope, native identity isolation, uncapped exports, mapping persistence, independent removal and corrupt restore isolation")
    }
}

private extension Optional {
    func unwrap() throws -> Wrapped { guard let value = self else { throw CocoaError(.fileReadUnknown) }; return value }
}
