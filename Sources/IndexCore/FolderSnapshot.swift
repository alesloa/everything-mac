import Foundation

// Totals add indexed descendant file sizes; directory metadata sizes are excluded.
public struct FolderTotals: Sendable, Equatable {
    public let bytes: UInt64?
    public let fileCount: Int
}

public struct FolderSnapshot: Sendable {
    public let snapshotID: UUID
    public let revision: UInt64
    public let roots: [UInt32]
    private let store: FileStore
    private let bytes: [UInt64]
    private let files: [UInt32]
    private let overflow: Set<UInt32>
    private let descendants: [UInt32: [UInt32]]

    public func children(of id: UInt32) -> [UInt32] { descendants[id] ?? [] }

    public func record(for id: UInt32) -> FileRecord? {
        guard Int(id) < store.count, store.isLive(id), store.isDir(of: id) else { return nil }
        return FileRecord(id: id, name: store.name(of: id), path: store.path(of: id),
                          parent: store.parent(of: id), size: store.size(of: id),
                          mtime: store.mtime(of: id), isDir: true, volID: store.volID(of: id))
    }

    public func totals(for record: FileRecord) -> FolderTotals? {
        let id = record.id
        guard record.isDir, Int(id) < store.count, store.isLive(id), store.isDir(of: id),
              store.path(of: id).utf8.elementsEqual(record.path.utf8) else { return nil }
        return FolderTotals(bytes: overflow.contains(id) ? nil : bytes[Int(id)],
                            fileCount: Int(files[Int(id)]))
    }

    static func build(store: FileStore, snapshotID: UUID,
                      isCancelled: @Sendable () -> Bool) -> FolderSnapshot? {
        guard !isCancelled() else { return nil }
        var bytes = [UInt64](repeating: 0, count: store.count)
        var files = [UInt32](repeating: 0, count: store.count)
        var remaining = [UInt32](repeating: 0, count: store.count)
        var overflow: Set<UInt32> = []
        var children: [UInt32: [UInt32]] = [:]
        var roots: [UInt32] = [], directories: [UInt32] = []

        func parentDirectory(_ id: UInt32) -> UInt32? {
            let parent = store.parent(of: id)
            guard parent != FileStore.noParent, Int(parent) < store.count,
                  store.isLive(parent), store.isDir(of: parent) else { return nil }
            return parent
        }
        for offset in 0..<store.count {
            if offset & 1023 == 0 && isCancelled() { return nil }
            let id = UInt32(offset)
            guard store.isLive(id) else { continue }
            let parent = parentDirectory(id)
            if store.isDir(of: id) {
                directories.append(id)
                if let parent {
                    remaining[Int(parent)] += 1
                    children[parent, default: []].append(id)
                } else { roots.append(id) }
            } else if let parent {
                let (sum, didOverflow) = bytes[Int(parent)].addingReportingOverflow(store.size(of: id))
                bytes[Int(parent)] = sum
                if didOverflow { overflow.insert(parent) }
                files[Int(parent)] += 1
            }
        }
        // A leaf-first pass does not assume parent slots precede children. Each
        // directory is visited once, regardless of tree depth or append order.
        var queue = directories.filter { remaining[Int($0)] == 0 }, cursor = 0
        while cursor < queue.count {
            if cursor & 1023 == 0 && isCancelled() { return nil }
            let id = queue[cursor]; cursor += 1
            guard let parent = parentDirectory(id) else { continue }
            let (sum, didOverflow) = bytes[Int(parent)].addingReportingOverflow(bytes[Int(id)])
            bytes[Int(parent)] = sum
            if didOverflow || overflow.contains(id) { overflow.insert(parent) }
            files[Int(parent)] += files[Int(id)]
            remaining[Int(parent)] -= 1
            if remaining[Int(parent)] == 0 { queue.append(parent) }
        }
        guard cursor == directories.count, !isCancelled() else { return nil }
        for id in children.keys {
            if isCancelled() { return nil }
            children[id]?.sort { store.nameSortsBefore($0, $1) }
        }
        roots.sort { store.nameSortsBefore($0, $1) }
        guard !isCancelled() else { return nil }
        return FolderSnapshot(snapshotID: snapshotID, revision: store.revision, roots: roots,
                              store: store, bytes: bytes, files: files,
                              overflow: overflow, descendants: children)
    }
}
