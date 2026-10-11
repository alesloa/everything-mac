import Foundation
import IndexCore

// Share scans are replacement snapshots, so a partial or failed scan cannot
// safely tell us which previously known files were actually removed.
enum ShareIndexMutation {
    // Called when the share's rules are unchanged, including local-root toggles.
    // Copy last-known share records without consulting an offline
    // server. A local tree now occupying the old path wins over stale metadata.
    static func retainKnownShares(_ shares: [NetworkShare], from previous: FileStore,
                                  in replacement: inout FileStore,
                                  isCancelled: @Sendable () -> Bool) {
        guard !shares.isEmpty else { return }
        let volumes = Set(shares.map(\.volID))
        var parents: [UInt32: UInt32] = [:]
        for offset in 0..<previous.count {
            if offset & 1023 == 0 && isCancelled() { return }
            let id = UInt32(offset), volume = previous.volID(of: id)
            guard previous.isLive(id), volumes.contains(volume) else { continue }
            let oldParent = previous.parent(of: id)
            let newParent: UInt32
            var name = previous.name(of: id)
            if oldParent != FileStore.noParent, previous.volID(of: oldParent) == volume {
                guard let mapped = parents[oldParent] else { continue }
                newParent = mapped
            } else {
                let oldPath = previous.path(of: id)
                let parentPath = (oldPath as NSString).deletingLastPathComponent
                if let parent = replacement.idForDirPath(parentPath) {
                    name = (oldPath as NSString).lastPathComponent
                    guard !replacement.childIDs(of: parent).contains(where: {
                        replacement.name(of: $0).utf8.elementsEqual(name.utf8)
                    }) else { continue }
                    newParent = parent
                } else {
                    guard replacement.idForDirPath(oldPath) == nil else { continue }
                    newParent = FileStore.noParent
                    name = oldPath
                }
            }
            parents[id] = replacement.append(name: name, parent: newParent,
                                              size: previous.size(of: id), mtime: previous.mtime(of: id),
                                              isDir: previous.isDir(of: id), volID: volume)
        }
    }

    static func replace(_ share: NetworkShare, at mountPath: String, with sub: FileStore,
                        in store: inout FileStore) -> Bool {
        guard sub.count > 0, sub.scanCompleted,
              sub.rootID != FileStore.noParent, sub.isLive(sub.rootID), sub.isDir(of: sub.rootID),
              sub.path(of: sub.rootID).utf8.elementsEqual(mountPath.utf8) else { return false }
        let parentPath = (mountPath as NSString).deletingLastPathComponent
        let parent = store.idForDirPath(parentPath) ?? FileStore.noParent
        // The caller verified this source is mounted here. Its complete snapshot
        // replaces any cached subtree at that path, including an old local node.
        let rootName = (mountPath as NSString).lastPathComponent
        if parent == FileStore.noParent {
            if let id = store.idForDirPath(mountPath) { store.markSubtreeDeleted(id) }
        } else {
            for id in store.childIDs(of: parent) where store.name(of: id).utf8.elementsEqual(rootName.utf8) {
                store.markSubtreeDeleted(id)
            }
        }
        store.markDeleted(volID: share.volID)
        store.merge(sub, asChildOf: parent, volID: share.volID)
        return true
    }
}
