import Foundation
import Testing
@testable import IndexCore

@Suite struct ResultDetailsTests {
    func fixture() -> (FileStore, UInt32, UInt32) {
        var store = FileStore()
        let root = store.append(name: "/", parent: FileStore.noParent, size: 999, mtime: 0, isDir: true, volID: 1)
        let folder = store.append(name: "Reports", parent: root, size: 999, mtime: 0, isDir: true, volID: 1)
        let nested = store.append(name: "Archive", parent: folder, size: 999, mtime: 0, isDir: true, volID: 1)
        _ = store.append(name: "résumé.pdf", parent: folder, size: 100, mtime: 100, isDir: false, volID: 1)
        _ = store.append(name: "report-final.pdf", parent: nested, size: 200, mtime: 200, isDir: false, volID: 1)
        let deleted = store.append(name: "deleted.pdf", parent: nested, size: 500, mtime: 0, isDir: false, volID: 1)
        store.markDeleted(deleted)
        _ = store.append(name: "report-outside.pdf", parent: root, size: 400, mtime: 300, isDir: false, volID: 1)
        return (store, folder, nested)
    }

    @Test func countsAreExactBeyondLimitAcrossCachedSortsAndNarrowing() async {
        var store = FileStore()
        let root = store.append(name: "/", parent: FileStore.noParent, size: 0, mtime: 0, isDir: true, volID: 1)
        for index in 0..<12_001 {
            _ = store.append(name: "report-\(index).pdf", parent: root, size: UInt64(index), mtime: Int64(index), isDir: false, volID: 1)
        }
        let index = SearchIndex(); index.publish(store)
        let first = await index.searchReport(Query(text: "report"), limit: 17)
        #expect(first.totalMatches == 12_001)
        #expect(first.records.count == 17)
        let sorted = await index.searchReport(Query(text: "report"), sort: .size, ascending: false, limit: 2)
        #expect(sorted.totalMatches == first.totalMatches)
        #expect(sorted.records.first?.size == 12_000)
        #expect(sorted.snapshotID == first.snapshotID)
        let narrow = await index.searchReport(Query(text: "report-12"), limit: 3)
        #expect(narrow.totalMatches == QueryEngine().search(Query(text: "report-12"), in: store).count)
        let countOnly = await index.searchReport(Query(text: "report"), limit: 0)
        #expect(countOnly.records.isEmpty && countOnly.totalMatches == 12_001)
    }

    @Test func scopedAdvancedAndFuzzyCountsUseIndexAncestry() async throws {
        let (store, folder, _) = fixture()
        let index = SearchIndex(); index.publish(store)
        let scope = FolderScope(id: folder, path: store.path(of: folder))
        let result = await index.searchReport(Query(text: "ext:pdf size:>=100"), limit: 1, scope: scope)
        #expect(result.totalMatches == 2 && result.records.count == 1)
        let fuzzy = await index.searchReport(Query(text: "rprt", fuzzy: true), limit: 1, scope: scope)
        #expect(fuzzy.totalMatches == 1)
        let all = await index.searchReport(Query(text: ""), limit: 10, scope: scope)
        #expect(all.totalMatches == 3)
        #expect(!all.records.contains { $0.id == folder })
        let missing = await index.searchReport(Query(text: "report"), scope: FolderScope(id: folder, path: "/Missing"))
        #expect(missing.totalMatches == 0 && missing.records.isEmpty)
    }

    @Test func recursiveTotalsExcludeDirectorySizesDeletedFilesAndOtherFolders() async throws {
        let (store, folder, nested) = fixture()
        let index = SearchIndex(); index.publish(store)
        let snapshot = try #require(await index.folderSnapshot())
        let folderRecord = try #require(snapshot.record(for: folder))
        let nestedRecord = try #require(snapshot.record(for: nested))
        let total = try #require(snapshot.totals(for: folderRecord))
        #expect(total.bytes == 300 && total.fileCount == 2)
        #expect(snapshot.totals(for: nestedRecord)?.bytes == 200)
        #expect(snapshot.children(of: folder) == [nested])
        #expect(snapshot.roots == [0])
        let repeated = try #require(await index.folderSnapshot())
        #expect(repeated.snapshotID == snapshot.snapshotID)
        let report = await index.searchReport(Query(text: ""), limit: 1)
        #expect(report.snapshotID == snapshot.snapshotID && report.revision == snapshot.revision)
    }

    @Test func aggregatesPreservePublishedSnapshotAcrossMutationsAndRebuiltIDs() async throws {
        var (store, folder, _) = fixture()
        let index = SearchIndex(); index.publish(store)
        let first = try #require(await index.folderSnapshot())
        let oldRecord = try #require(first.record(for: folder))
        _ = store.append(name: "new.pdf", parent: folder, size: 700, mtime: 0, isDir: false, volID: 1)
        index.publish(store)
        let second = try #require(await index.folderSnapshot())
        #expect(first.totals(for: oldRecord)?.bytes == 300)
        #expect(second.totals(for: oldRecord)?.bytes == 1000)
        #expect(first.snapshotID != second.snapshotID)
        var rebuilt = FileStore()
        let root = rebuilt.append(name: "/", parent: FileStore.noParent, size: 0, mtime: 0, isDir: true, volID: 1)
        _ = rebuilt.append(name: "Other", parent: root, size: 0, mtime: 0, isDir: true, volID: 1)
        index.publish(rebuilt)
        let third = try #require(await index.folderSnapshot())
        #expect(third.totals(for: oldRecord) == nil)
        let scoped = await index.searchReport(Query(text: ""), scope: FolderScope(record: oldRecord))
        #expect(scoped.totalMatches == 0)
    }

    @Test func unicodeFolderScopesKeepExactByteSpelling() async {
        var store = FileStore()
        let root = store.append(name: "/", parent: FileStore.noParent, size: 0, mtime: 0, isDir: true, volID: 1)
        let composed = store.append(name: "Café", parent: root, size: 0, mtime: 0, isDir: true, volID: 1)
        let decomposed = store.append(name: "Cafe\u{301}", parent: root, size: 0, mtime: 0, isDir: true, volID: 1)
        _ = store.append(name: "one.txt", parent: composed, size: 1, mtime: 0, isDir: false, volID: 1)
        _ = store.append(name: "two.txt", parent: decomposed, size: 2, mtime: 0, isDir: false, volID: 1)
        let index = SearchIndex(); index.publish(store)
        let scope = FolderScope(id: decomposed, path: "/Café")
        let result = await index.searchReport(Query(text: ""), scope: scope)
        #expect(result.records.map(\.name) == ["one.txt"])
        #expect(FolderScope(path: "/Café") != FolderScope(path: "/Cafe\u{301}"))
    }

    @Test func overflowIsAbsentAndDeepTotalsDoNotUseRecursion() throws {
        var store = FileStore()
        var parent = store.append(name: "/", parent: FileStore.noParent, size: 0, mtime: 0, isDir: true, volID: 1)
        for _ in 0..<2000 { parent = store.append(name: "d", parent: parent, size: 0, mtime: 0, isDir: true, volID: 1) }
        _ = store.append(name: "huge", parent: parent, size: UInt64.max, mtime: 0, isDir: false, volID: 1)
        _ = store.append(name: "one", parent: parent, size: 1, mtime: 0, isDir: false, volID: 1)
        let built = FolderSnapshot.build(store: store, snapshotID: UUID(), isCancelled: { false })
        let snapshot = try #require(built)
        let rootRecord = try #require(snapshot.record(for: 0))
        let total = try #require(snapshot.totals(for: rootRecord))
        #expect(total.bytes == nil && total.fileCount == 2)
        let cancelled = FolderSnapshot.build(store: store, snapshotID: UUID(), isCancelled: { true })
        #expect(cancelled == nil)
    }

    @Test func forwardParentsAndMidBuildCancellationAreHandled() throws {
        var store = FileStore()
        let child = store.append(name: "Child", parent: 1, size: 1000, mtime: 0, isDir: true, volID: 1)
        let root = store.append(name: "/", parent: FileStore.noParent, size: 1000, mtime: 0, isDir: true, volID: 1)
        for index in 0..<20_000 {
            _ = store.append(name: "file-\(index)", parent: child, size: 1, mtime: 0, isDir: false, volID: 1)
        }
        let built = FolderSnapshot.build(store: store, snapshotID: UUID(), isCancelled: { false })
        let snapshot = try #require(built)
        let record = try #require(snapshot.record(for: root))
        #expect(snapshot.totals(for: record)?.bytes == 20_000)
        let counter = CancellationProbe()
        let cancelled = FolderSnapshot.build(store: store, snapshotID: UUID(), isCancelled: { counter.check() })
        #expect(cancelled == nil)
        #expect(counter.calls == 5)
    }

    @Test func currentQueryHighlightsRespectUnicodeBooleanAndMetadataBranches() {
        let record = FileRecord(id: 1, name: "Résumé-final.pdf", path: "/Docs/Résumé-final.pdf", parent: 0,
                                size: 100, mtime: 0, isDir: false, volID: 1)
        let unicode = QueryHighlighter(query: Query(text: "resume", diacriticInsensitive: true)).highlights(for: record)
        #expect(unicode.name == [NSRange(location: 0, length: 6)])
        let decomposed = FileRecord(id: 3, name: "Cafe\u{301}-😀.txt", path: "/Docs/Cafe\u{301}-😀.txt", parent: 0,
                                    size: 100, mtime: 0, isDir: false, volID: 1)
        let accents = QueryHighlighter(query: Query(text: "cafe", diacriticInsensitive: true)).highlights(for: decomposed)
        #expect(accents.name == [NSRange(location: 0, length: 5)])
        let emoji = QueryHighlighter(query: Query(text: "😀")).highlights(for: decomposed)
        #expect(emoji.name == [NSRange(location: 6, length: 2)])
        let branch = QueryHighlighter(query: Query(text: "(name:final size:>1000)|ext:pdf")).highlights(for: record)
        #expect(branch.name == [NSRange(location: 13, length: 3)])
        let negative = QueryHighlighter(query: Query(text: "name:final NOT name:draft")).highlights(for: record)
        #expect(negative.name == [NSRange(location: 7, length: 5)])
        let path = QueryHighlighter(query: Query(text: "path:Docs")).highlights(for: record)
        #expect(path.name.isEmpty && path.path == [NSRange(location: 1, length: 4)])
        let regex = QueryHighlighter(query: Query(text: "Résumé.*pdf", regex: true)).highlights(for: record)
        #expect(regex.name == [NSRange(location: 0, length: 16)])
        let fuzzy = QueryHighlighter(query: Query(text: "fnl", fuzzy: true)).highlights(for: record)
        #expect(fuzzy.name == [NSRange(location: 7, length: 1), NSRange(location: 9, length: 1), NSRange(location: 11, length: 1)])
        #expect(QueryHighlighter(query: Query(text: "final")).highlights(for: record, isCancelled: { true }).name.isEmpty)
    }
}

private final class CancellationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var calls: Int { lock.withLock { value } }
    func check() -> Bool { lock.withLock { value += 1; return value >= 5 } }
}
