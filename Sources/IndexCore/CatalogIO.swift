import Foundation
import Darwin

public enum CatalogIO {
    private struct Header: Codable { let id: UUID; let sourceName: String }
    private static let magic = Data("EFC01".utf8)

    /// Imports into our immutable portable file without materializing every path.
    /// File list formats and metadata semantics follow public voidtools EFU docs.
    @discardableResult
    public static func importFile(from source: URL, to destination: URL,
                                  format: CatalogFormat? = nil, id: UUID = UUID(),
                                  isCancelled: @escaping @Sendable () -> Bool = { false }) throws -> FileCatalogSnapshot {
        let selected = try format ?? inferredFormat(source)
        guard selected != .json else { throw CatalogError.unsupportedFormat(selected.rawValue) }
        try atomicWrite(to: destination, isCancelled: isCancelled) { handle in
            let header = try JSONEncoder().encode(Header(id: id, sourceName: source.lastPathComponent))
            var bytes = magic; bytes.appendInteger(UInt32(header.count)); bytes.append(header)
            try handle.write(contentsOf: bytes)
            let delimiter: UInt8 = selected == .tsv ? 9 : selected == .txt ? 0 : 44
            let reader = try CatalogCSVReader(url: source, delimiter: delimiter, cancelled: isCancelled)
            var columns: [String: Int] = [:]
            if selected != .txt {
                guard let row = try reader.row() else { throw CatalogError.invalidDocument("The header is missing.") }
                for (index, name) in row.enumerated() { columns[name.trimmingCharacters(in: .whitespaces).lowercased()] = index }
                guard columns["filename"] != nil || columns["path"] != nil else {
                    throw CatalogError.invalidDocument("The header requires Filename or Path.")
                }
            }
            var rowNumber = 0
            while let row = try reader.row() {
                if isCancelled() { throw CancellationError() }
                if row.allSatisfy({ $0.isEmpty }) { continue }
                func field(_ keys: [String]) -> String? {
                    for key in keys {
                        if let index = columns[key], index < row.count, !row[index].isEmpty { return row[index] }
                    }
                    return nil
                }
                let path = selected == .txt ? row[0] : field(["filename", "path"]) ?? ""
                guard !path.isEmpty, !path.contains("\0") else { throw CatalogError.invalidDocument("A row has an empty path or a NUL byte.") }
                func unsigned<T: FixedWidthInteger & UnsignedInteger>(_ value: String?, as: T.Type) throws -> T? {
                    guard let value else { return nil }
                    let number = value.hasPrefix("0x") ? T(value.dropFirst(2), radix: 16) : T(value)
                    guard let number else { throw CatalogError.invalidDocument("Invalid numeric metadata: \(value)") }
                    return number
                }
                let size: UInt64? = try unsigned(field(["size", "size (bytes)"]), as: UInt64.self)
                let attributes: UInt32? = try unsigned(field(["attributes"]), as: UInt32.self)
                let modified = try timestamp(field(["date modified", "modified", "mtime"]))
                let created = try timestamp(field(["date created", "created"]))
                let directory: Bool?
                if let explicit = field(["directory", "isdir", "is directory"]) {
                    switch explicit.lowercased() {
                    case "true", "1": directory = true
                    case "false", "0": directory = false
                    default: throw CatalogError.invalidDocument("Invalid directory metadata: \(explicit)")
                    }
                } else if let attributes { directory = attributes & 16 != 0 }
                else if path.hasSuffix("\\") || path.hasSuffix("/") { directory = true }
                else { directory = nil }
                let record = CatalogRecord(id: CatalogRecordID(catalog: id, row: rowNumber), path: path,
                    size: size, modified: modified, created: created, attributes: attributes, isDirectory: directory)
                try handle.write(contentsOf: encoded(record))
                rowNumber += 1
            }
        }
        return try load(from: destination, isCancelled: isCancelled)
    }

    public static func load(from url: URL,
                            isCancelled: @escaping @Sendable () -> Bool = { false }) throws -> FileCatalogSnapshot {
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        guard data.count >= 9, data.starts(with: magic) else { throw CatalogError.invalidDocument("The saved catalog header is invalid.") }
        let length = data.withUnsafeBytes { Int(UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 5, as: UInt32.self))) }
        guard length <= 1_048_576, length <= data.count - 9 else { throw CatalogError.invalidDocument("The saved catalog header is truncated or exceeds the supported byte length.") }
        let header = try JSONDecoder().decode(Header.self, from: data.subdata(in: 9..<(9 + length)))
        var offsets: [Int] = [], cursor = 9 + length
        try data.withUnsafeBytes { bytes in
            while cursor < data.count {
                if offsets.count & 255 == 0 && isCancelled() { throw CancellationError() }
                guard data.count - cursor >= 46 else { throw CatalogError.invalidDocument("A saved catalog row is truncated.") }
                let size = Int(UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: cursor + 1, as: UInt32.self)))
                guard size <= 16 * 1024 * 1024, size <= data.count - cursor - 46, bytes[cursor] & 192 == 0,
                      UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: cursor + 21, as: UInt32.self)) < 1_000_000_000,
                      UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: cursor + 33, as: UInt32.self)) < 1_000_000_000,
                      let path = String(bytes: bytes[(cursor + 46)..<(cursor + 46 + size)], encoding: .utf8),
                      !path.isEmpty, !path.contains("\0") else { throw CatalogError.invalidDocument("A saved catalog row is invalid.") }
                offsets.append(cursor); cursor += 46 + size
            }
        }
        return FileCatalogSnapshot(id: header.id, sourceName: header.sourceName, url: url, data: data, offsets: offsets)
    }

    public static func inferredFormat(_ url: URL) throws -> CatalogFormat {
        guard let format = CatalogFormat(rawValue: url.pathExtension.lowercased()) else {
            throw CatalogError.unsupportedFormat(url.pathExtension)
        }
        return format
    }

    static func timestamp(_ value: String?) throws -> CatalogTimestamp? {
        guard let value else { return nil }
        if let ticks = UInt64(value) { return CatalogTimestamp(filetime: ticks) }
        var wholeDate = value, nanos: UInt32 = 0
        if let dot = value.firstIndex(of: ".") {
            let tail = value[value.index(after: dot)...]
            let digits = tail.prefix(while: { $0.isNumber && $0.isASCII })
            guard !digits.isEmpty, digits.count <= 9 else {
                throw CatalogError.invalidDocument("Date precision exceeds nanoseconds: \(value)")
            }
            nanos = UInt32(String(digits) + String(repeating: "0", count: 9 - digits.count))!
            wholeDate = String(value[..<dot]) + String(tail.dropFirst(digits.count))
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let local = DateFormatter(); local.locale = Locale(identifier: "en_US_POSIX")
        local.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"; local.isLenient = false
        let localDate = wholeDate.count == 19 ? local.date(from: wholeDate) : nil
        guard let date = formatter.date(from: wholeDate) ?? localDate else {
            throw CatalogError.invalidDocument("Invalid date metadata: \(value)")
        }
        let seconds = floor(date.timeIntervalSince1970)
        guard seconds >= Double(Int64.min), seconds < Double(Int64.max) else {
            throw CatalogError.invalidDocument("Date metadata is outside the supported range: \(value)")
        }
        // Parse textual fractional digits separately to avoid FILETIME precision
        // loss through Double. ISO timezone/local dates come from the document.
        return CatalogTimestamp(seconds: Int64(seconds), nanoseconds: nanos)
    }

    private static func encoded(_ record: CatalogRecord) throws -> Data {
        let path = Data(record.path.utf8)
        guard path.count <= Int(UInt32.max) else { throw CatalogError.invalidDocument("A path exceeds the supported byte length.") }
        var flags: UInt8 = 0
        if record.size != nil { flags |= 1 }; if record.modified != nil { flags |= 2 }
        if record.created != nil { flags |= 4 }; if record.attributes != nil { flags |= 8 }
        if let directory = record.isDirectory { flags |= 16; if directory { flags |= 32 } }
        var bytes = Data([flags]); bytes.appendInteger(UInt32(path.count)); bytes.appendInteger(record.size ?? 0)
        for date in [record.modified, record.created] {
            bytes.appendInteger(date?.seconds ?? 0); bytes.appendInteger(date?.nanoseconds ?? 0)
        }
        bytes.appendInteger(record.attributes ?? 0); bytes.append(Data(repeating: 0, count: 5)); bytes.append(path)
        return bytes
    }

    /// The old destination survives cancellation or any write failure.
    static func atomicWrite(to destination: URL, isCancelled: @Sendable () -> Bool,
                            body: (FileHandle) throws -> Void) throws {
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".catalog-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: temporary.path])
        }
        defer { try? FileManager.default.removeItem(at: temporary) }
        let handle = try FileHandle(forWritingTo: temporary)
        do {
            try body(handle)
            if isCancelled() { throw CancellationError() }
            try handle.synchronize(); try handle.close()
            if isCancelled() { throw CancellationError() }
            if Darwin.rename(temporary.path, destination.path) != 0 {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: destination.path])
            }
        } catch { try? handle.close(); throw error }
    }
}

private extension Data {
    mutating func appendInteger<T: FixedWidthInteger>(_ value: T) {
        var encoded = value.littleEndian
        Swift.withUnsafeBytes(of: &encoded) { append(contentsOf: $0) }
    }
}
