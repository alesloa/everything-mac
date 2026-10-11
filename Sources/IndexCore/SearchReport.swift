import Foundation

// Every displayed row/count is decoded from the same accepted index publication.
public struct SearchReport: Sendable {
    public let records: [FileRecord]
    public let totalMatches: Int
    public let snapshotID: UUID
    public let revision: UInt64
}

public struct FolderScope: Sendable, Equatable {
    public let id: UInt32?
    public let path: String

    public init(id: UInt32? = nil, path: String) { self.id = id; self.path = path }
    public init(record: FileRecord) { id = record.id; path = record.path }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.path.utf8.elementsEqual(rhs.path.utf8)
    }

    public func resolve(in store: FileStore, isCancelled: @Sendable () -> Bool = { false }) -> UInt32? {
        if let id, Int(id) < store.count, store.isLive(id), store.isDir(of: id),
           store.path(of: id).utf8.elementsEqual(path.utf8) { return id }
        // Saved workspace paths survive rebuilt slot IDs, but never change their
        // Unicode spelling or fall back to an unrelated directory with that ID.
        for offset in 0..<store.count {
            if offset & 1023 == 0 && isCancelled() { return nil }
            let candidate = UInt32(offset)
            if store.isLive(candidate), store.isDir(of: candidate),
               store.path(of: candidate).utf8.elementsEqual(path.utf8) { return candidate }
        }
        return nil
    }

    public static func contains(_ id: UInt32, below directory: UInt32, in store: FileStore) -> Bool {
        guard Int(id) < store.count, store.isLive(id) else { return false }
        var next = store.parent(of: id), steps = 0
        while next != FileStore.noParent && Int(next) < store.count && steps < store.count {
            guard store.isLive(next) else { return false }
            if next == directory { return true }
            next = store.parent(of: next); steps += 1
        }
        return false
    }
}
