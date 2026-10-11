import Foundation

/// Streaming UTF-8 CSV reader; quoted delimiters, CRLF, BOM and embedded newlines
/// are part of document data. Invalid encoding and malformed rows fail visibly.
final class CatalogCSVReader {
    private let handle: FileHandle
    private var buffer = Data()
    private var position = 0
    private var eof = false
    private var first = true
    private let delimiter: UInt8
    private let cancelled: @Sendable () -> Bool
    // Bound a malicious single field while allowing long portable paths.
    private let maximumFieldBytes = 16 * 1024 * 1024
    init(url: URL, delimiter: UInt8 = 44, cancelled: @escaping @Sendable () -> Bool) throws {
        handle = try FileHandle(forReadingFrom: url); self.delimiter = delimiter; self.cancelled = cancelled
    }
    deinit { try? handle.close() }
    private func byte() throws -> UInt8? {
        if position >= buffer.count {
            if cancelled() { throw CancellationError() }
            guard !eof else { return nil }
            buffer = try handle.read(upToCount: 64 * 1024) ?? Data(); position = 0
            if buffer.isEmpty { eof = true; return nil }
            if first {
                first = false
                if buffer.starts(with: [0xEF, 0xBB, 0xBF]) { position = 3 }
            }
        }
        let value = buffer[position]; position += 1; return value
    }
    private var pending: UInt8?
    private func next() throws -> UInt8? {
        if let pending { self.pending = nil; return pending }
        return try byte()
    }
    func row() throws -> [String]? {
        var fields: [String] = [], field: [UInt8] = []
        var quoted = false, closed = false, started = false, consumed = false
        func decoded() throws -> String {
            guard let value = String(bytes: field, encoding: .utf8) else {
                throw CatalogError.invalidDocument("A field is not valid UTF-8.")
            }
            return value
        }
        while let value = try next() {
            consumed = true
            if quoted {
                if value == 34 {
                    let following = try next()
                    if following == 34 { field.append(34) }
                    else { quoted = false; closed = true; pending = following }
                } else { field.append(value) }
            } else if value == delimiter {
                fields.append(try decoded()); field.removeAll(keepingCapacity: true)
                started = false; closed = false
            } else if value == 10 || value == 13 {
                if value == 13 { let following = try next(); if following != 10 { pending = following } }
                fields.append(try decoded()); return fields
            } else if value == 34 && !started && !closed {
                quoted = true; started = true
            } else {
                guard !closed && value != 34 else { throw CatalogError.invalidDocument("Unexpected text or quote after a CSV field.") }
                started = true; field.append(value)
            }
            guard field.count <= maximumFieldBytes else { throw CatalogError.invalidDocument("A field exceeds the supported byte length.") }
            if field.count & 4095 == 0 && cancelled() { throw CancellationError() }
        }
        if quoted { throw CatalogError.invalidDocument("A quoted CSV field is not closed.") }
        guard consumed else { return nil }
        fields.append(try decoded()); return fields
    }
}

/// TXT files are UTF-8 paths separated by physical lines; CSV quoting is also
/// accepted/emitted so paths containing line breaks or quotes can roundtrip.
func catalogQuoted(_ value: String, delimiter: Character = ",") -> String {
    if value.contains(delimiter) || value.contains("\"") || value.contains("\n") || value.contains("\r") {
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
    return value
}
