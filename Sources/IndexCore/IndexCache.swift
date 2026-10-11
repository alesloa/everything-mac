import Foundation
import Darwin

public enum IndexCache {
    struct CacheError: Error {}
    // [EMC2][event checkpoint][rules fingerprint][EMS1/EMS2 column blob].
    // Cache replacement is atomic: readers retain their old mapping's inode.
    private static let magic = Array("EMC2".utf8)

    public static func save(_ store: FileStore, to url: URL, lastEventID: UInt64,
                            rulesFingerprint: UInt64) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".index-\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil) else { throw CacheError() }
        let handle = try FileHandle(forWritingTo: temporary)
        do {
            func write(_ bytes: UnsafeRawBufferPointer) throws {
                guard let address = bytes.baseAddress, bytes.count > 0 else { return }
                try handle.write(contentsOf: Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: address), count: bytes.count, deallocator: .none))
            }
            try magic.withUnsafeBytes(write)
            var event = lastEventID, fingerprint = rulesFingerprint
            try withUnsafeBytes(of: &event, write)
            try withUnsafeBytes(of: &fingerprint, write)
            try store.writeBinary(write)
            try handle.synchronize()
            try handle.close()
            guard rename(temporary.path, url.path) == 0 else { throw CacheError() }
        } catch {
            try? handle.close()
            throw error
        }
    }

    public static func load(from url: URL) throws -> (FileStore, UInt64, UInt64) {
        try load(from: url, buildWriterIndex: true)
    }
    static func load(from url: URL, buildWriterIndex: Bool) throws -> (FileStore, UInt64, UInt64) {
        let bytes = try StoreBytes(file: url)
        let header = magic.count + 16
        guard bytes.count >= header, Array(bytes.buffer(in: 0..<magic.count)) == magic else { throw CacheError() }
        let event = bytes.value(at: magic.count, as: UInt64.self)
        let fingerprint = bytes.value(at: magic.count + 8, as: UInt64.self)
        guard let store = FileStore(storage: bytes, offset: header, buildWriterIndex: buildWriterIndex) else { throw CacheError() }
        return (store, event, fingerprint)
    }
}
