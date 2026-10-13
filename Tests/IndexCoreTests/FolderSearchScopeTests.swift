import Foundation
import Testing
@testable import IndexCore

@Suite struct FolderSearchScopeTests {
    private func fixture() -> FileStore {
        var store = FileStore()
        let root = store.append(name: "/", parent: FileStore.noParent, size: 0, mtime: 0, isDir: true, volID: 1)
        let users = store.append(name: "Users", parent: root, size: 0, mtime: 0, isDir: true, volID: 1)
        let nested = store.append(name: "Nested", parent: users, size: 0, mtime: 0, isDir: true, volID: 1)
        let apps = store.append(name: "Applications", parent: root, size: 0, mtime: 0, isDir: true, volID: 1)
        let volumes = store.append(name: "Volumes", parent: root, size: 0, mtime: 0, isDir: true, volID: 1)
        let lookalike = store.append(name: "Volumes-other", parent: root, size: 0, mtime: 0, isDir: true, volID: 1)
        store.append(name: "report-home.txt", parent: users, size: 1, mtime: 1, isDir: false, volID: 1)
        store.append(name: "report-nested.txt", parent: nested, size: 2, mtime: 2, isDir: false, volID: 1)
        store.append(name: "report-app.txt", parent: apps, size: 3, mtime: 3, isDir: false, volID: 1)
        store.append(name: "report-drive.txt", parent: volumes, size: 4, mtime: 4, isDir: false, volID: 2)
        store.append(name: "report-lookalike.txt", parent: lookalike, size: 5, mtime: 5, isDir: false, volID: 1)
        let dead = store.append(name: "deleted.txt", parent: users, size: 6, mtime: 6, isDir: false, volID: 1)
        store.markDeleted(dead)
        let share = store.append(name: "/Network/Share", parent: FileStore.noParent, size: 0, mtime: 0, isDir: true, volID: 3)
        store.append(name: "report-share.txt", parent: share, size: 7, mtime: 7, isDir: false, volID: 3)
        return store
    }

    @Test func unionDeduplicatesOverlappingBranchesAndKeepsAllResultRows() async throws {
        let store = fixture(), index = SearchIndex(); index.publish(store)
        let selection = FolderSearchScope(included: [
            FolderScope(path: "/Users"), FolderScope(path: "/Users/Nested"),
            FolderScope(path: "/Applications"), FolderScope(path: "/Users")
        ])
        #expect(selection.included.count == 3)
        let first = await index.searchReport(Query(text: "report"), sort: .size, ascending: false,
            limit: 1, folderSelection: selection, includeAllResults: true)
        #expect(first.totalMatches == 3 && first.records.map(\.name) == ["report-app.txt"])
        let list = try #require(first.resultList)
        #expect(list.count == 3)
        #expect(await list.prepare())
        #expect((0..<list.count).compactMap { list.record(at: $0)?.name } ==
            ["report-app.txt", "report-nested.txt", "report-home.txt"])
        let changed = await index.searchReport(Query(text: "report"), folderSelection:
            FolderSearchScope(included: [FolderScope(path: "/Volumes")]))
        #expect(changed.records.map(\.name) == ["report-drive.txt"])
        #expect(changed.snapshotID == first.snapshotID && changed.revision == first.revision)
        let fuzzy = await index.searchReport(Query(text: "rprt", fuzzy: true), folderSelection: selection)
        #expect(fuzzy.totalMatches == 3)
        let narrowed = await index.searchReport(Query(text: "report-app"), folderSelection: selection)
        #expect(narrowed.records.map(\.name) == ["report-app.txt"])
    }

    @Test func exclusionsRemoveTheBranchItselfAndDescendantsWithoutPrefixMatching() async throws {
        let store = fixture(), index = SearchIndex(); index.publish(store)
        let everythingExceptVolumes = FolderSearchScope(excluded: [FolderScope(path: "/Volumes")])
        let all = await index.searchReport(Query(text: ""), limit: 100, folderSelection: everythingExceptVolumes)
        #expect(!all.records.contains { $0.path == "/Volumes" || $0.name == "report-drive.txt" })
        #expect(all.records.contains { $0.path == "/Volumes-other" })
        #expect(all.records.contains { $0.path == "/Network/Share/report-share.txt" })
        let nested = await index.searchReport(Query(text: ""), folderSelection: FolderSearchScope(
            included: [FolderScope(path: "/Users"), FolderScope(path: "/Users/Nested")],
            excluded: [FolderScope(path: "/Users/Nested")]))
        #expect(nested.records.map(\.name) == ["report-home.txt"])
        let excludesAncestor = await index.searchReport(Query(text: ""), folderSelection: FolderSearchScope(
            included: [FolderScope(path: "/Users/Nested")], excluded: [FolderScope(path: "/Users")]))
        #expect(excludesAncestor.totalMatches == 0)
        let onlyIndependent = await index.searchReport(Query(text: "ext:txt"), folderSelection:
            FolderSearchScope(excluded: [FolderScope(path: "/")]))
        #expect(onlyIndependent.records.map(\.name) == ["report-share.txt"])
    }

    @Test func explicitSelectionOverridesLegacyFallbackAndMissingIncludesNeverBroaden() async throws {
        let store = fixture(), index = SearchIndex(); index.publish(store)
        let legacy = FolderScope(path: "/Volumes")
        let all = await index.searchReport(Query(text: "report"), scope: legacy, folderSelection: FolderSearchScope())
        #expect(all.totalMatches == 6)
        let chosen = FolderSearchScope(included: [FolderScope(id: 4, path: "/Missing"), FolderScope(path: "/Users")])
        let result = await index.searchReport(Query(text: "report"), scope: legacy, folderSelection: chosen)
        #expect(Set(result.records.map(\.name)) == Set(["report-home.txt", "report-nested.txt"]))
        let missing = FolderSearchScope(included: [FolderScope(id: 4, path: "/Missing")])
        #expect(await index.searchReport(Query(text: "report"), folderSelection: missing).totalMatches == 0)
        #expect(try CatalogSearch.nativeIDs(store: store, query: Query(text: "report"),
            folderPath: "/Volumes", folderSelection: missing).isEmpty)
        #expect(try CatalogSearch.nativeIDs(store: store, query: Query(text: "report"),
            folderPath: "/Missing", folderSelection: FolderSearchScope()).count == 6)
        #expect(throws: CatalogError.self) {
            try CatalogSearch.nativeIDs(store: store, query: Query(text: "report"), folderPath: "/Missing")
        }
    }

    @Test func unicodePathsAndRebuiltHintIDsStayByteExactAcrossPublishedSnapshots() async throws {
        var store = FileStore()
        let root = store.append(name: "/", parent: FileStore.noParent, size: 0, mtime: 0, isDir: true, volID: 1)
        let composed = store.append(name: "Café", parent: root, size: 0, mtime: 0, isDir: true, volID: 1)
        let decomposed = store.append(name: "Cafe\u{301}", parent: root, size: 0, mtime: 0, isDir: true, volID: 1)
        store.append(name: "one.txt", parent: composed, size: 1, mtime: 0, isDir: false, volID: 1)
        store.append(name: "two.txt", parent: decomposed, size: 1, mtime: 0, isDir: false, volID: 1)
        let selection = FolderSearchScope(included: [FolderScope(id: decomposed, path: "/Café")],
                                          excluded: [FolderScope(id: composed, path: "/Cafe\u{301}")])
        let unique = FolderSearchScope(included: [FolderScope(path: "/Café"), FolderScope(path: "/Cafe\u{301}"), FolderScope(path: "/Café")])
        #expect(unique.included.count == 2)
        #expect(selection != FolderSearchScope(included: [FolderScope(id: decomposed, path: "/Cafe\u{301}")],
                                               excluded: selection.excluded))
        let index = SearchIndex(); index.publish(store)
        let first = await index.searchReport(Query(text: ""), folderSelection: selection, includeAllResults: true)
        #expect(first.records.map(\.name) == ["one.txt"])
        var rebuilt = FileStore()
        let newRoot = rebuilt.append(name: "/", parent: FileStore.noParent, size: 0, mtime: 0, isDir: true, volID: 1)
        let wrong = rebuilt.append(name: "Other", parent: newRoot, size: 0, mtime: 0, isDir: true, volID: 1)
        rebuilt.append(name: "Unrelated", parent: newRoot, size: 0, mtime: 0, isDir: true, volID: 1)
        let newComposed = rebuilt.append(name: "Café", parent: newRoot, size: 0, mtime: 0, isDir: true, volID: 1)
        let wrongNested = rebuilt.append(name: "Café", parent: wrong, size: 0, mtime: 0, isDir: true, volID: 1)
        rebuilt.append(name: "wrong.txt", parent: wrongNested, size: 1, mtime: 0, isDir: false, volID: 1)
        rebuilt.append(name: "new.txt", parent: newComposed, size: 1, mtime: 0, isDir: false, volID: 1)
        index.publish(rebuilt)
        let next = await index.searchReport(Query(text: ""), folderSelection: selection)
        #expect(next.records.map(\.name) == ["new.txt"])
        #expect(next.snapshotID != first.snapshotID)
        #expect(first.resultList?.record(at: 0)?.path == "/Café/one.txt")
        rebuilt.markDeleted(newComposed)
        index.publish(rebuilt)
        #expect(await index.searchReport(Query(text: ""), folderSelection: selection).totalMatches == 0)
    }

    @Test func exportContentAndDuplicatesUseExactlyTheSameUnionAndExclusions() async throws {
        let directory = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("folder-scopes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let relativePaths = ["chosen/one.txt", "chosen/nested/two.txt", "second/three.txt", "chosen-other/four.txt"]
        for relative in relativePaths {
            let file = directory.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("needle".utf8).write(to: file)
        }
        var store = FileStore()
        try Scanner(rules: ExcludeRules(names: [], pathPrefixes: [], excludeHidden: false))
            .scan(rootPath: directory.path, into: &store, volID: 1)
        let index = SearchIndex(); index.publish(store)
        let scope = FolderSearchScope(included: [FolderScope(path: directory.path + "/chosen"),
            FolderScope(path: directory.path + "/second"), FolderScope(path: directory.path + "/absent")],
            excluded: [FolderScope(path: directory.path + "/chosen/nested")])
        let expected = Set([directory.path + "/chosen/one.txt", directory.path + "/second/three.txt"])
        let query = Query(text: "ext:txt")
        let report = await index.searchReport(query, folderSelection: scope)
        #expect(Set(report.records.map(\.path)) == expected)
        let ids = try CatalogSearch.nativeIDs(store: store, query: query, folderPath: "/invalid-legacy-fallback",
                                              folderSelection: scope)
        #expect(Set(ids.map { store.path(of: $0) }) == expected)
        let output = directory.appendingPathComponent("export.json")
        #expect(try CatalogIO.exportNative(store: store, query: query, folderSelection: scope,
                                          to: output, format: .json) == 2)
        let rows = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: output)) as? [[String: Any]])
        #expect(Set(rows.compactMap { $0["path"] as? String }) == expected)
        var content = ContentSearchProgress()
        for await progress in ContentSearchService.events(index: index, request: ContentSearchRequest(
            literal: "needle", filenameQuery: query, restrictToFilenameQuery: true,
            folderPath: "/invalid-legacy-fallback", folderSelection: scope)) { content = progress }
        #expect(content.failure == nil && content.candidates == 2 && content.searched == 2)
        #expect(Set(content.results.map(\.path)) == expected)
        var picked = ContentSearchProgress()
        for await progress in ContentSearchService.events(index: index, request: ContentSearchRequest(
            literal: "needle", pickedFolderPath: directory.path + "/chosen", folderSelection: scope)) { picked = progress }
        #expect(picked.results.map(\.path) == [directory.path + "/chosen/one.txt"])
        let duplicates = await DuplicateFinder().find(in: .scopedQuery(snapshot: store, query: query, folderSelection: scope))
        #expect(duplicates.inspectedFiles == 2 && duplicates.groups.count == 1)
        #expect(Set(duplicates.groups[0].files.map(\.path)) == expected)
        #expect(duplicates.skipped.contains { $0.path == directory.path + "/absent" && $0.reason == .unavailable })
        let missing = FolderSearchScope(included: [FolderScope(path: directory.path + "/absent")])
        var unavailable = ContentSearchProgress()
        for await progress in ContentSearchService.events(index: index, request:
            ContentSearchRequest(literal: "needle", folderSelection: missing)) { unavailable = progress }
        #expect(unavailable.candidates == 0 && unavailable.bytesRead == 0 && unavailable.results.isEmpty)
    }

    @Test func cancellationAndMissingRootResolutionAreBoundedIndependentlyOfRootCount() throws {
        var store = FileStore()
        let root = store.append(name: "/", parent: FileStore.noParent, size: 0, mtime: 0, isDir: true, volID: 1)
        for number in 0..<50_000 {
            store.append(name: "folder-\(number)", parent: root, size: 0, mtime: 0, isDir: true, volID: 1)
        }
        let selection = FolderSearchScope(included: (0..<256).map { FolderScope(path: "/missing-\($0)") })
        let probe = FolderScopeCancellationProbe()
        let resolved = try ResolvedFolderSearchScope(selection, in: store, isCancelled: { probe.check() })
        #expect(resolved.missingIncludedPaths.count == 256)
        // Cancellation checkpoints scale with one index pass plus selected roots,
        // rather than 256 complete traversals of this same 50,001-record store.
        #expect(probe.calls < 1_000)
        #expect(try resolved.candidates(in: store, isCancelled: { false }) == [])
        let midResolution = FolderScopeCancellationProbe(cancelAt: 270)
        #expect(throws: CancellationError.self) {
            try ResolvedFolderSearchScope(selection, in: store, isCancelled: { midResolution.check() })
        }
        let scoped = try ResolvedFolderSearchScope(FolderSearchScope(excluded: [FolderScope(id: 1, path: "/folder-0")]),
                                                  in: store, isCancelled: { false })
        let midFiltering = FolderScopeCancellationProbe(cancelAt: 10)
        #expect(throws: CancellationError.self) {
            try scoped.candidates(in: store, isCancelled: { midFiltering.check() })
        }
        #expect(throws: CancellationError.self) {
            try CatalogSearch.nativeIDs(store: store, query: Query(text: ""), folderSelection: selection, isCancelled: { true })
        }
    }

    @Test func deepAncestryCancellationAndMalformedParentsDoNotHangResolution() throws {
        var store = FileStore()
        var parent = store.append(name: "/", parent: FileStore.noParent, size: 0, mtime: 0, isDir: true, volID: 1)
        for _ in 0..<3_000 { parent = store.append(name: "d", parent: parent, size: 0, mtime: 0, isDir: true, volID: 1) }
        let selection = FolderSearchScope(included: [FolderScope(id: parent, path: String(repeating: "/d", count: 3_000))])
        let probe = FolderScopeCancellationProbe(cancelAt: 5)
        #expect(throws: CancellationError.self) {
            try ResolvedFolderSearchScope(selection, in: store, isCancelled: { probe.check() })
        }
        var malformed = FileStore()
        malformed.append(name: "a", parent: 1, size: 0, mtime: 0, isDir: true, volID: 1)
        malformed.append(name: "b", parent: 0, size: 0, mtime: 0, isDir: true, volID: 1)
        let invalid = try ResolvedFolderSearchScope(FolderSearchScope(included: [FolderScope(id: 0, path: "/a")]),
                                                  in: malformed, isCancelled: { false })
        #expect(try invalid.candidates(in: malformed, isCancelled: { false }) == [])
    }
}

private final class FolderScopeCancellationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    private let cancelAt: Int?
    init(cancelAt: Int? = nil) { self.cancelAt = cancelAt }
    var calls: Int { lock.withLock { value } }
    func check() -> Bool { lock.withLock { value += 1; return cancelAt.map { value >= $0 } ?? false } }
}
