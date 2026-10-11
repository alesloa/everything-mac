import Foundation
import Darwin
import PDFKit

struct ContentSearchFileResult: Sendable {
    var hit: ContentSearchHit?
    var error: ContentSearchFileError?
    var searched = false
    var bytesRead: Int64 = 0
}

enum ContentSearchReader {
    static func search(path: String, literal: String, options: ContentSearchOptions,
                       isCancelled: () -> Bool) -> ContentSearchFileResult {
        var result = ContentSearchFileResult()
        do {
            guard let file = try ContentSearchFileAccess.openFile(path: path, options: options,
                                                                 isCancelled: isCancelled) else { return result }
            var matcher = ContentSearchMatcher(literal: literal, options: options)
            guard matcher.valid else { return result }
            let isPDF = (path as NSString).pathExtension.lowercased() == "pdf"
            var decoder = ContentSearchDecoder(), pdfData = Data()
            var buffer = [UInt8](repeating: 0, count: options.chunkBytes)
            while !isCancelled() {
                let length = read(file.descriptor, &buffer, buffer.count)
                if length < 0 {
                    if errno == EINTR { continue }
                    throw ContentSearchFileAccess.posixError()
                }
                if length == 0 { break }
                result.bytesRead += Int64(length)
                guard result.bytesRead <= options.maxFileBytes, result.bytesRead <= file.stamp.size else { return result }
                if isPDF { pdfData.append(contentsOf: buffer.prefix(length)) }
                else {
                    guard let text = decoder.decode(Array(buffer.prefix(length))) else { return result }
                    matcher.append(text, isCancelled: isCancelled)
                    guard matcher.valid else { return result }
                }
            }
            guard !isCancelled(), result.bytesRead == file.stamp.size else { return result }
            if isPDF {
                guard extractPDF(pdfData, matcher: &matcher, options: options, isCancelled: isCancelled) else { return result }
            } else {
                guard let text = decoder.decode([], final: true) else { return result }
                matcher.append(text, final: true, isCancelled: isCancelled)
            }
            guard matcher.valid, !isCancelled(), try file.remainsUnchanged(isCancelled: isCancelled) else { return result }
            result.searched = true
            if matcher.occurrenceCount > 0 {
                result.hit = ContentSearchHit(path: path, occurrenceCount: matcher.occurrenceCount,
                    excerpt: matcher.excerpt, fileBytes: file.stamp.size,
                    modifiedSeconds: file.stamp.modifiedSeconds, modifiedNanoseconds: file.stamp.modifiedNanoseconds)
            }
        } catch {
            if !isCancelled() { result.error = .init(path: path, message: error.localizedDescription) }
        }
        return result
    }

    private static func extractPDF(_ data: Data, matcher: inout ContentSearchMatcher,
                                   options: ContentSearchOptions, isCancelled: () -> Bool) -> Bool {
        // Native text extraction only: no view, URL navigation, HTML importer,
        // attachment loading or external actions are invoked.
        guard !isCancelled(), let document = PDFDocument(data: data), !document.isLocked,
              document.pageCount <= options.maxPDFPages else { return false }
        var extractedBytes = 0
        let maximum = min(options.maxFileBytes * 8, 64 * 1_024 * 1_024)
        for page in 0..<document.pageCount {
            guard !isCancelled(), let actualPage = document.page(at: page) else { return false }
            if let text = actualPage.string {
                extractedBytes += text.utf8.count
                guard extractedBytes <= maximum else { return false }
                // Finish each page independently: no invented page separator and
                // no occurrence assembled from two unrelated page boundaries.
                matcher.append(text, final: true, isCancelled: isCancelled)
                guard matcher.valid else { return false }
            }
            matcher.finishSegment(isCancelled: isCancelled)
        }
        return !isCancelled()
    }
}
