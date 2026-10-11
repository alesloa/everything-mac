import Foundation
import Darwin
import PDFKit
import CoreGraphics
import CoreText
import Testing
@testable import IndexCore

private final class ContentSearchFixture {
    let root: URL
    init() throws {
        // /private/tmp is an actual directory; /tmp and /var are macOS aliases
        // deliberately rejected by the production no-ancestor-link policy.
        root = URL(fileURLWithPath: "/private/tmp")
            .appendingPathComponent("content-search-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    }
    deinit { try? FileManager.default.removeItem(at: root) }
    @discardableResult func write(_ name: String, data: Data) throws -> URL {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .withoutOverwriting)
        return url
    }
    @discardableResult func text(_ name: String, _ text: String) throws -> URL {
        try write(name, data: Data(text.utf8))
    }
    func index() throws -> SearchIndex {
        var store = FileStore()
        try Scanner(rules: ExcludeRules(names: [], pathPrefixes: [], excludeHidden: false))
            .scan(rootPath: root.path, into: &store, volID: 1)
        let index = SearchIndex(); index.publish(store); return index
    }
}

private func contentSearch(_ index: SearchIndex, _ request: ContentSearchRequest) async -> ContentSearchProgress {
    var last = ContentSearchProgress()
    for await update in ContentSearchService.events(index: index, request: request) { last = update }
    return last
}

@Test func contentSearchFindsMultilingualUTF8AcrossEveryByteBoundary() async throws {
    let fixture = try ContentSearchFixture()
    let actual = "before Résumé / Re\u{301}sume\u{301} / 東京 🌍 / Straße after"
    try fixture.text("multilingual.txt", actual)
    let index = try fixture.index()
    for chunk in [1, 2, 3, 7, 64] {
        var options = ContentSearchOptions(); options.chunkBytes = chunk
        let accented = await contentSearch(index, .init(literal: "résumé", options: options))
        #expect(accented.results.first?.occurrenceCount == 2)
        #expect(accented.results.first?.excerpt == actual)
        let japanese = await contentSearch(index, .init(literal: "東京 🌍", options: options))
        #expect(japanese.results.first?.occurrenceCount == 1)
        let caseFold = await contentSearch(index, .init(literal: "STRASSE", options: options))
        #expect(caseFold.results.first?.occurrenceCount == 1)
        options.diacriticInsensitive = true
        let plain = await contentSearch(index, .init(literal: "resume", options: options))
        #expect(plain.results.first?.occurrenceCount == 2)
        options.caseInsensitive = false
        let sensitive = await contentSearch(index, .init(literal: "résumé", options: options))
        #expect(sensitive.results.isEmpty)
    }
}

@Test func contentSearchDecodesBothUTF16ByteOrdersAndSurrogates() async throws {
    let fixture = try ContentSearchFixture(), actual = "αβ 東京 🌍 café"
    for (name, littleEndian) in [("little.txt", true), ("big.txt", false)] {
        var bytes: [UInt8] = littleEndian ? [0xff, 0xfe] : [0xfe, 0xff]
        for unit in actual.utf16 {
            let a = UInt8(truncatingIfNeeded: unit), b = UInt8(truncatingIfNeeded: unit >> 8)
            bytes += littleEndian ? [a, b] : [b, a]
        }
        try fixture.write(name, data: Data(bytes))
    }
    var options = ContentSearchOptions(); options.chunkBytes = 1
    let result = await contentSearch(try fixture.index(), .init(literal: "東京 🌍 café", options: options))
    #expect(result.searched == 2)
    #expect(result.results.count == 2)
    #expect(result.results.allSatisfy { $0.excerpt == actual })
}

@Test func contentSearchCountsNonoverlappingLiteralsAndKeepsBoundedActualExcerpt() async throws {
    let fixture = try ContentSearchFixture()
    let actual = String(repeating: "x", count: 600) + "abababa" + String(repeating: "y", count: 700)
    try fixture.text("counts.md", actual)
    var options = ContentSearchOptions(); options.chunkBytes = 2
    let result = await contentSearch(try fixture.index(), .init(literal: "aba", options: options))
    let hit = try #require(result.results.first)
    #expect(hit.occurrenceCount == 2)
    #expect(hit.excerpt.utf8.count <= 1_024)
    #expect(actual.contains(hit.excerpt))
}

@Test func contentSearchSkipsBinaryMalformedOversizeUnsupportedAndHTMLIsText() async throws {
    let fixture = try ContentSearchFixture()
    try fixture.write("binary.txt", data: Data([110, 101, 101, 100, 108, 101, 0, 1]))
    try fixture.write("badutf8.txt", data: Data([0xc0, 0xaf]))
    try fixture.write("badutf16.txt", data: Data([0xff, 0xfe, 0, 0xd8]))
    try fixture.text("large.txt", String(repeating: "needle", count: 100))
    try fixture.text("unsupported.rtf", "needle")
    let html = "<html><img src='https://example.invalid/needle.png'>needle</html>"
    try fixture.text("raw.html", html)
    var options = ContentSearchOptions(); options.maxFileBytes = 100; options.chunkBytes = 1
    let result = await contentSearch(try fixture.index(), .init(literal: "needle", options: options))
    #expect(result.candidates == 5)
    #expect(result.searched == 1)
    #expect(result.skipped == 4)
    #expect(result.results.first?.excerpt == html)
    #expect(result.results.first?.occurrenceCount == 2)
}

@Test func contentSearchUsesValidatedFilenameQueryAndTwoActualFolderScopes() async throws {
    let fixture = try ContentSearchFixture()
    try fixture.text("docs/report.swift", "needle")
    try fixture.text("docs/notes.txt", "needle")
    try fixture.text("docs/nested/report.txt", "needle")
    try fixture.text("docs-other/report.swift", "needle")
    let index = try fixture.index(), docs = fixture.root.appendingPathComponent("docs").path
    let result = await contentSearch(index, .init(literal: "needle", filenameQuery: Query(text: "report"),
        restrictToFilenameQuery: true, folderPath: docs))
    #expect(result.results.count == 2)
    let narrower = await contentSearch(index, .init(literal: "needle", filenameQuery: Query(text: "report"),
        restrictToFilenameQuery: true, folderPath: docs, pickedFolderPath: docs + "/nested"))
    #expect(narrower.results.map(\.path) == [docs + "/nested/report.txt"])
    let disjoint = await contentSearch(index, .init(literal: "needle", folderPath: docs,
        pickedFolderPath: fixture.root.appendingPathComponent("docs-other").path))
    #expect(disjoint.candidates == 0)
    let invalid = await contentSearch(index, .init(literal: "needle", filenameQuery: Query(text: "ext:"),
        restrictToFilenameQuery: true))
    #expect(invalid.failure == Query(text: "ext:").validationError?.localizedDescription)
    #expect(invalid.bytesRead == 0)
    let missing = await contentSearch(index, .init(literal: "needle", restrictToFilenameQuery: true))
    #expect(missing.failure != nil)
    #expect(missing.candidates == 0)
}

@Test func contentSearchNeverUsesDisplayedResultCapOrStaleIndexedSize() async throws {
    let fixture = try ContentSearchFixture()
    var store = FileStore()
    let root = store.append(name: fixture.root.path, parent: FileStore.noParent, size: 0, mtime: 0, isDir: true, volID: 1)
    for number in 0..<5_002 {
        store.append(name: "report-\(number).txt", parent: root, size: .max, mtime: 0, isDir: false, volID: 1)
    }
    try fixture.text("report-5001.txt", "needle")
    let index = SearchIndex(); index.publish(store)
    #expect(await index.search(Query(text: "report"), limit: 1).count == 1)
    let result = await contentSearch(index, .init(literal: "needle", filenameQuery: Query(text: "report"),
                                                restrictToFilenameQuery: true))
    #expect(result.candidates == 5_002)
    #expect(result.results.map(\.path) == [fixture.root.appendingPathComponent("report-5001.txt").path])
    #expect(result.results.first?.fileBytes == 6)
    #expect(result.errors.count == 100)
}

@Test func contentSearchRefusesFileAndAncestorLinksAndSpecialFiles() throws {
    let fixture = try ContentSearchFixture()
    let actual = try fixture.text("real/actual.txt", "needle")
    let link = fixture.root.appendingPathComponent("alias.txt")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: actual)
    let ancestor = fixture.root.appendingPathComponent("linked-dir")
    try FileManager.default.createSymbolicLink(at: ancestor, withDestinationURL: actual.deletingLastPathComponent())
    let fifo = fixture.root.appendingPathComponent("fifo.txt")
    #expect(fifo.path.withCString { mkfifo($0, 0o600) } == 0)
    let options = ContentSearchOptions()
    for path in [link.path, ancestor.appendingPathComponent("actual.txt").path, fifo.path] {
        let result = ContentSearchReader.search(path: path, literal: "needle", options: options, isCancelled: { false })
        #expect(result.hit == nil)
        #expect(!result.searched)
        #expect(result.bytesRead == 0)
    }
}

@Test func contentSearchDescriptorRevalidationRejectsReplacedAndEditedFiles() throws {
    let fixture = try ContentSearchFixture(), url = try fixture.text("changing.txt", "needle")
    let options = ContentSearchOptions()
    let file = try #require(try ContentSearchFileAccess.openFile(path: url.path, options: options, isCancelled: { false }))
    try Data("edited".utf8).write(to: url)
    #expect(try !file.remainsUnchanged(isCancelled: { false }))
    let edited = try #require(try ContentSearchFileAccess.openFile(path: url.path, options: options, isCancelled: { false }))
    try Data("needle".utf8).write(to: url, options: .atomic)
    #expect(try !edited.remainsUnchanged(isCancelled: { false }))
}

@Test func contentSearchSkipsFileChangedDuringStreamingAndStopsOnCancellation() throws {
    let fixture = try ContentSearchFixture()
    let url = try fixture.text("streaming.txt", "needle " + String(repeating: "a", count: 20_000))
    var options = ContentSearchOptions(); options.chunkBytes = 256
    var calls = 0
    let changed = ContentSearchReader.search(path: url.path, literal: "needle", options: options) {
        calls += 1
        if calls == 40 { try? Data("changed".utf8).write(to: url, options: .atomic) }
        return false
    }
    #expect(changed.hit == nil)
    #expect(!changed.searched)
    let cancelled = ContentSearchReader.search(path: url.path, literal: "changed", options: options, isCancelled: { true })
    #expect(cancelled.bytesRead == 0)
    #expect(cancelled.hit == nil)
}

@Test func contentSearchQueuedJobsCancelAndActivePermitStaysOccupied() async throws {
    let gate = ContentSearchJobGate(), first = SearchCancellation()
    try await gate.acquire(UUID(), cancellation: first)
    let waiting = Task { try await gate.acquire(UUID(), cancellation: SearchCancellation()) }
    try await Task.sleep(for: .milliseconds(20))
    waiting.cancel()
    do { try await waiting.value; Issue.record("Cancelled queued job acquired a permit") }
    catch is CancellationError {} catch { Issue.record("Unexpected gate error: \(error)") }
    // Cancellation of active work does not call release or admit another job.
    first.cancel()
    let nextToken = SearchCancellation()
    let next = Task { try await gate.acquire(UUID(), cancellation: nextToken) }
    try await Task.sleep(for: .milliseconds(20))
    next.cancel()
    do { try await next.value; Issue.record("Active cancellation prematurely released the permit") }
    catch is CancellationError {} catch { Issue.record("Unexpected gate error: \(error)") }
    await gate.release()
    try await gate.acquire(UUID(), cancellation: SearchCancellation())
    await gate.release()
}

private func contentPDF(_ text: String, pages: Int) -> Data {
    contentPDF(Array(repeating: text, count: pages))
}

private func contentPDF(_ pages: [String]) -> Data {
    let data = NSMutableData(), consumer = CGDataConsumer(data: data as CFMutableData)!
    var bounds = CGRect(x: 0, y: 0, width: 300, height: 300)
    let context = CGContext(consumer: consumer, mediaBox: &bounds, nil)!
    for text in pages {
        context.beginPDFPage(nil)
        let font = CTFontCreateWithName("Helvetica" as CFString, 14, nil)
        let string = NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
        context.textPosition = CGPoint(x: 20, y: 200)
        CTLineDraw(CTLineCreateWithAttributedString(string), context)
        context.endPDFPage()
    }
    context.closePDF(); return data as Data
}

@Test func contentSearchExtractsPDFTextWithSizePageAndFormatBounds() async throws {
    let fixture = try ContentSearchFixture()
    try fixture.write("one.pdf", data: contentPDF("PDF needle", pages: 1))
    try fixture.write("two.pdf", data: contentPDF("PDF needle", pages: 2))
    try fixture.text("text.txt", "needle")
    var options = ContentSearchOptions(); options.fileKind = .pdf; options.maxPDFPages = 1
    let result = await contentSearch(try fixture.index(), .init(literal: "needle", options: options))
    #expect(result.candidates == 2)
    #expect(result.searched == 1)
    #expect(result.skipped == 1)
    #expect(result.results.first?.occurrenceCount == 1)
    #expect(result.results.first?.excerpt.contains("PDF needle") == true)
    try fixture.write("fragmented.pdf", data: contentPDF(["need", "le"]))
    options.maxPDFPages = 2
    let complete = await contentSearch(try fixture.index(), .init(literal: "needle", options: options))
    #expect(complete.results.count == 2)
    #expect(!complete.results.contains { $0.path.hasSuffix("fragmented.pdf") })
    #expect(complete.results.first { $0.path.hasSuffix("two.pdf") }?.occurrenceCount == 2)
}

@Test func contentSearchBoundsCombiningCarryAndRejectsInvalidConfiguration() async throws {
    let fixture = try ContentSearchFixture()
    try fixture.text("combining.txt", "needle " + "a" + String(repeating: "\u{301}", count: 5_000))
    var options = ContentSearchOptions(); options.chunkBytes = 7
    let result = await contentSearch(try fixture.index(), .init(literal: "needle", options: options))
    #expect(result.results.isEmpty)
    #expect(result.skipped == 1)
    options.concurrency = 9
    let invalid = await contentSearch(try fixture.index(), .init(literal: "needle", options: options))
    #expect(invalid.failure != nil)
    #expect(invalid.bytesRead == 0)
}
