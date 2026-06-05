import Foundation

public enum IndexCache {
    struct CacheError: Error {}

    // File layout: ["EMC1" magic][UInt64 lastEventID][FileStore binary blob].
    // Binary, not JSON: a whole-disk index is millions of records, and JSON
    // encode/decode of that takes tens of seconds and stalls every launch. The
    // binary form saves in ~1s and restores via memcpy.
    private static let magic = Array("EMC1".utf8)

    public static func save(_ store: FileStore, to url: URL, lastEventID: UInt64) throws {
        var data = Data()
        data.append(contentsOf: magic)
        var evid = lastEventID
        withUnsafeBytes(of: &evid) { data.append(contentsOf: $0) }
        data.append(store.serializedBinary())
        try data.write(to: url, options: .atomic)
    }

    public static func load(from url: URL) throws -> (FileStore, UInt64) {
        let data = try Data(contentsOf: url, options: .mappedIfSafe) // memory-mapped
        let header = magic.count + 8
        guard data.count >= header, Array(data[0..<magic.count]) == magic else { throw CacheError() }
        let evid = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: magic.count, as: UInt64.self) }
        guard let store = FileStore(binary: data.subdata(in: header..<data.count)) else { throw CacheError() }
        return (store, evid)
    }
}
