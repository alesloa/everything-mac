import Foundation

/// Exact FILETIME conversion follows voidtools' public EFU documentation:
/// https://www.voidtools.com/en-uk/support/everything/file_lists/#efu-file-format
public struct CatalogTimestamp: Sendable, Equatable, Comparable, Codable {
    public let seconds: Int64
    public let nanoseconds: UInt32
    private static let epoch: Int64 = 11_644_473_600
    public init(seconds: Int64, nanoseconds: UInt32 = 0) {
        precondition(nanoseconds < 1_000_000_000)
        self.seconds = seconds; self.nanoseconds = nanoseconds
    }
    public init(filetime: UInt64) {
        seconds = Int64(filetime / 10_000_000) - Self.epoch
        nanoseconds = UInt32(filetime % 10_000_000) * 100
    }
    public var filetime: UInt64? {
        let (shifted, overflow) = seconds.addingReportingOverflow(Self.epoch)
        guard !overflow, shifted >= 0, nanoseconds % 100 == 0 else { return nil }
        let (ticks, multiplied) = UInt64(shifted).multipliedReportingOverflow(by: 10_000_000)
        let (result, added) = ticks.addingReportingOverflow(UInt64(nanoseconds / 100))
        return multiplied || added ? nil : result
    }
    public var date: Date { Date(timeIntervalSince1970: Double(seconds) + Double(nanoseconds) / 1_000_000_000) }
    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.seconds == rhs.seconds ? lhs.nanoseconds < rhs.nanoseconds : lhs.seconds < rhs.seconds
    }
}

/// All optional metadata comes from the imported document, or the native FileRecord.
/// A row number identifies an imported row, never a native index slot or support code.
public struct CatalogRecordID: Sendable, Hashable, Codable {
    public let catalog: UUID
    public let row: Int
    public init(catalog: UUID, row: Int) { self.catalog = catalog; self.row = row }
}

public struct CatalogRecord: Sendable, Equatable, Codable, Identifiable {
    public let id: CatalogRecordID
    public let path: String
    public let size: UInt64?
    public let modified: CatalogTimestamp?
    public let created: CatalogTimestamp?
    public let attributes: UInt32?
    public let isDirectory: Bool?
    public var name: String { String(path.trimmingCharacters(in: CharacterSet(charactersIn: "/\\")).split(whereSeparator: { $0 == "/" || $0 == "\\" }).last ?? "") }
    public var parentPath: String {
        var trimmed = path
        while trimmed.hasSuffix("/") || trimmed.hasSuffix("\\") { trimmed.removeLast() }
        guard let split = trimmed.lastIndex(where: { $0 == "/" || $0 == "\\" }) else { return "" }
        return String(trimmed[..<split])
    }
    public init(id: CatalogRecordID, path: String, size: UInt64? = nil,
                modified: CatalogTimestamp? = nil, created: CatalogTimestamp? = nil,
                attributes: UInt32? = nil, isDirectory: Bool? = nil) {
        self.id = id; self.path = path; self.size = size; self.modified = modified
        self.created = created; self.attributes = attributes; self.isDirectory = isDirectory
    }
    public init(native record: FileRecord, catalogID: UUID) {
        self.init(id: CatalogRecordID(catalog: catalogID, row: Int(record.id)), path: record.path,
                  size: record.size, modified: CatalogTimestamp(seconds: record.mtime),
                  isDirectory: record.isDir)
    }
}

// Format labels are the owner's requested export formats, not imported metadata.
public enum CatalogFormat: String, Sendable, CaseIterable, Identifiable {
    case efu, csv, txt, tsv, json
    public var id: String { rawValue }
    public var label: String { rawValue.uppercased() }
}

/// Error text below reports parser validation of the actual document or path mapping.
public enum CatalogError: Error, LocalizedError, Sendable {
    case invalidDocument(String), unsafeMapping(String), unsupportedFormat(String), invalidScope(String)
    public var errorDescription: String? {
        switch self {
        case .invalidDocument(let detail): "Invalid file catalog: \(detail)"
        case .unsafeMapping(let detail): "Catalog path mapping: \(detail)"
        case .unsupportedFormat(let format): "Unsupported catalog format: \(format)"
        case .invalidScope(let detail): "Folder scope: \(detail)"
        }
    }
}

/// Immutable binary file; only offsets are resident, paths are decoded on demand.
/// The mapped file remains alive when a catalog is replaced or removed from disk.
public final class FileCatalogSnapshot: @unchecked Sendable {
    public let id: UUID
    public let sourceName: String
    public let url: URL
    public var count: Int { offsets.count }
    private let data: Data
    private let offsets: [Int]
    init(id: UUID, sourceName: String, url: URL, data: Data, offsets: [Int]) {
        self.id = id; self.sourceName = sourceName; self.url = url
        self.data = data; self.offsets = offsets
    }
    public func record(at row: Int) -> CatalogRecord? {
        guard offsets.indices.contains(row) else { return nil }
        let offset = offsets[row]
        return data.withUnsafeBytes { bytes in
            let flags = bytes[offset]
            let length = Int(bytes.loadUnaligned(fromByteOffset: offset + 1, as: UInt32.self).littleEndian)
            let path = String(decoding: bytes[(offset + 46)..<(offset + 46 + length)], as: UTF8.self)
            func timestamp(_ position: Int) -> CatalogTimestamp {
                CatalogTimestamp(seconds: Int64(littleEndian: bytes.loadUnaligned(fromByteOffset: position, as: Int64.self)),
                                 nanoseconds: UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: position + 8, as: UInt32.self)))
            }
            return CatalogRecord(id: CatalogRecordID(catalog: id, row: row), path: path,
                size: flags & 1 == 0 ? nil : UInt64(littleEndian: bytes.loadUnaligned(fromByteOffset: offset + 5, as: UInt64.self)),
                modified: flags & 2 == 0 ? nil : timestamp(offset + 13),
                created: flags & 4 == 0 ? nil : timestamp(offset + 25),
                attributes: flags & 8 == 0 ? nil : UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: offset + 37, as: UInt32.self)),
                isDirectory: flags & 16 == 0 ? nil : flags & 32 != 0)
        }
    }
}
