import Foundation
import Testing
@testable import IndexCore

@Suite struct SearchResultListTests {
    private func fixture() -> FileStore {
        var store = FileStore()
        let root = store.append(name: "/", parent: FileStore.noParent, size: 0, mtime: 0, isDir: true, volID: 1)
        for number in (0..<12_001).reversed() {
            store.append(name: "report-\(number % 6000).txt", parent: root, size: UInt64(number),
                         mtime: Int64(number), isDir: false, volID: 1)
        }
        return store
    }

    @Test func allRowsAreAccessibleWithOnlyASmallInitialPrefix() async throws {
        let store = fixture(), index = SearchIndex()
        index.publish(store)
        for (sort, ascending) in [(QueryEngine.SortKey.name, true), (.size, false), (.mtime, true)] {
            let report = await index.searchReport(Query(text: "report"), sort: sort,
                                                 ascending: ascending, limit: 16, includeAllResults: true)
            let list = try #require(report.resultList)
            #expect(report.records.count == 16 && list.count == 12_001)
            #expect(list.record(at: 12_000) == nil)
            #expect(await list.prepare())
            let matches = QueryEngine().search(Query(text: "report"), in: store)
            let expected = QueryEngine().sort(matches, by: sort, ascending: ascending, in: store)
            #expect(list.record(at: 0)?.id == expected[0])
            #expect(list.record(at: 5000)?.id == expected[5000])
            #expect(list.record(at: 12_000)?.id == expected[12_000])
            #expect(list.record(at: -1) == nil && list.record(at: list.count) == nil)
            let record = try #require(list.record(at: 11_999))
            #expect(await list.indexes(of: [record]) == [11_999])
            #expect(await list.retaining([record]) == [record])
        }
    }

    @Test func fuzzyOrderingAndScopesKeepEveryMatchInTheSameSnapshot() async throws {
        var store = fixture()
        let folder = store.append(name: "folder", parent: 0, size: 0, mtime: 0, isDir: true, volID: 1)
        store.append(name: "rapid-transport.txt", parent: folder, size: 1, mtime: 1, isDir: false, volID: 1)
        let index = SearchIndex(); index.publish(store)
        let query = Query(text: "rprt", fuzzy: true)
        let report = await index.searchReport(query, limit: 8, includeAllResults: true)
        let list = try #require(report.resultList)
        #expect(await list.prepare())
        let expected = QueryEngine().rankedPrefix(QueryEngine().matches(query, in: store), limit: Int.max, in: store)
        #expect(list.count == expected.count)
        #expect(list.record(at: list.count - 1)?.id == expected.last)
        var replacement = FileStore()
        replacement.append(name: "/Other", parent: FileStore.noParent, size: 0, mtime: 0, isDir: true, volID: 1)
        index.publish(replacement)
        #expect(list.record(at: list.count - 1)?.path.hasPrefix("/") == true)
        #expect(list.snapshotID == report.snapshotID)
        index.publish(store)
        let scoped = await index.searchReport(Query(text: ""), scope: FolderScope(record: FileRecord(
            id: folder, name: "folder", path: "/folder", parent: 0, size: 0, mtime: 0, isDir: true, volID: 1)),
            includeAllResults: true)
        #expect(scoped.totalMatches == 1 && scoped.resultList?.count == 1)
    }

    @Test func cancelledPreparationAndReusedSlotsDoNotPublishWrongFiles() async throws {
        let store = fixture(), index = SearchIndex()
        index.publish(store)
        let report = await index.searchReport(Query(text: "report"), limit: 1, includeAllResults: true)
        let list = try #require(report.resultList)
        list.cancel()
        #expect(!(await list.prepare()))
        let original = try #require(report.records.first)
        var wrong = original
        wrong = FileRecord(id: original.id, name: original.name, path: "/Other/" + original.name,
                           parent: original.parent, size: original.size, mtime: original.mtime,
                           isDir: original.isDir, volID: original.volID)
        #expect(await list.retaining([wrong]) == [])
        let query = await index.searchReport(Query(text: "report-5"), limit: 1, includeAllResults: true)
        #expect(await query.resultList?.retaining([original]) == [])
    }

    @Test func compactSelectAllRemapsWithoutChangingPathsOrDroppingRows() async throws {
        var store = fixture(); let index = SearchIndex(); index.publish(store)
        let first = await index.searchReport(Query(text: "report"), limit: 8, includeAllResults: true)
        let list = try #require(first.resultList)
        let all = SearchRowSelection(list: list, rows: IndexSet(integersIn: 0..<list.count))
        #expect(all.count == 12_001 && all.preview.count == 8)
        store.append(name: "report-new.txt", parent: 0, size: 1, mtime: 0, isDir: false, volID: 1)
        index.publish(store)
        let next = await index.searchReport(Query(text: "report"), limit: 8, includeAllResults: true)
        let nextList = try #require(next.resultList)
        let retained = try #require(await all.retaining(in: nextList))
        #expect(retained.count == 12_001)
        let records = await retained.records()
        #expect(records.count == 12_001 && !records.contains { $0.name == "report-new.txt" })
        var rebuilt = FileStore()
        rebuilt.append(name: "/Other", parent: FileStore.noParent, size: 0, mtime: 0, isDir: true, volID: 1)
        rebuilt.append(name: "report-wrong.txt", parent: 0, size: 0, mtime: 0, isDir: false, volID: 1)
        index.publish(rebuilt)
        let wrong = await index.searchReport(Query(text: "report"), includeAllResults: true)
        #expect(await all.retaining(in: try #require(wrong.resultList)) == nil)
    }

    @Test func capturedSelectionsSurviveCancelledDisplayOrdering() async throws {
        let index = SearchIndex(); index.publish(fixture())
        let report = await index.searchReport(Query(text: "report"), sort: .name, limit: 8, includeAllResults: true)
        let list = try #require(report.resultList)
        let selection = SearchRowSelection(list: list, rows: IndexSet(integersIn: 0..<list.count))
        let pinned = selection.pinned()
        list.cancel()
        #expect(!(await list.prepare()))
        let records = await selection.records()
        #expect(records.count == list.count)
        #expect(await pinned.list.prepare())
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(try CatalogIO.exportSelection(pinned, to: directory.appendingPathComponent("selected.txt"), format: .txt) == list.count)
    }

    @Test func tailPagesMatchCompleteOrderingIncludingDuplicateTies() async throws {
        let store = fixture(), index = SearchIndex(); index.publish(store)
        for sort in [QueryEngine.SortKey.name, .size, .mtime, .kind, .path] {
            for ascending in [true, false] {
                let report = await index.searchReport(Query(text: "report"), sort: sort, ascending: ascending,
                                                     limit: 8, includeAllResults: true)
                let list = try #require(report.resultList)
                #expect(await list.prepareTail())
                #expect(!list.isPrepared)
                let tail = (list.count - 512..<list.count).compactMap { list.record(at: $0)?.id }
                #expect(tail.count == 512)
                let record = try #require(list.record(at: list.count - 1))
                #expect(await list.indexes(of: [record]) == [list.count - 1])
                #expect(!list.isPrepared)
                #expect(await list.prepare())
                #expect(tail == (list.count - 512..<list.count).compactMap { list.record(at: $0)?.id })
            }
        }
        for bestFirst in [true, false] {
            let report = await index.searchReport(Query(text: "rprt", fuzzy: true), ascending: bestFirst,
                                                 limit: 8, includeAllResults: true)
            let list = try #require(report.resultList)
            #expect(await list.prepareTail())
            let tail = (list.count - 512..<list.count).compactMap { list.record(at: $0)?.id }
            #expect(await list.prepare())
            #expect(tail == (list.count - 512..<list.count).compactMap { list.record(at: $0)?.id })
        }
    }
}
