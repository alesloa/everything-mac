import Foundation
import Darwin

struct FileTransfer: Sendable {
    let source: URL
    let destination: URL
}

enum FileOperation: Sendable {
    case copy([FileTransfer])
    case move([FileTransfer])
    case rename([FileTransfer])
    case trash([URL])
}

struct FileOperationOutcome: Sendable {
    var changed = 0
    var errors: [String] = []
    var canUndo = false
}

private enum FileOperationError: LocalizedError {
    case changed(URL)
    var errorDescription: String? {
        switch self {
        case .changed(let url):
            // Source: the destination's actual file name and the before/after filesystem snapshots.
            return "\(url.lastPathComponent) changed after this operation. Undo was stopped."
        }
    }
}

/// Serializes filesystem work away from the main actor; undo never overwrites a destination.
actor FileOperationEngine {
    typealias TrashHandler = @Sendable (URL) throws -> URL
    private struct UndoChange: Sendable {
        let original: URL
        let current: URL
        let snapshot: FileTreeSnapshot
    }
    private struct UndoBatch: Sendable {
        let copies: Bool
        var changes: [UndoChange]
    }
    private let trashHandler: TrashHandler
    private var history: [UndoBatch] = []
    private let fm = FileManager.default

    init(trashHandler: @escaping TrashHandler = { url in
        var trashed: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &trashed)
        guard let trashed else { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path]) }
        return trashed as URL
    }) { self.trashHandler = trashHandler }

    func perform(_ operation: FileOperation) -> FileOperationOutcome {
        var outcome = FileOperationOutcome()
        var changes: [UndoChange] = []
        var copies = false
        do {
            switch operation {
            case .copy(let transfers), .move(let transfers):
                copies = { if case .copy = operation { return true }; return false }()
                try validate(transfers, allowCycles: false)
                for item in transfers {
                    try Task.checkCancellation()
                    // Validate before changing the source, and capture the result for safe undo.
                    _ = try FileTreeSnapshot(at: item.source)
                    if copies { try fm.copyItem(at: item.source, to: item.destination) }
                    else { try fm.moveItem(at: item.source, to: item.destination) }
                    outcome.changed += 1
                    changes.append(UndoChange(original: item.source, current: item.destination,
                                              snapshot: try FileTreeSnapshot(at: item.destination)))
                }
            case .rename(let transfers):
                try validate(transfers, allowCycles: true)
                try rename(transfers)
                outcome.changed = transfers.count
                for item in transfers {
                    changes.append(UndoChange(original: item.source, current: item.destination,
                                              snapshot: try FileTreeSnapshot(at: item.destination)))
                }
            case .trash(let urls):
                try validateSources(urls)
                for url in urls {
                    try Task.checkCancellation()
                    _ = try FileTreeSnapshot(at: url)
                    let destination = try trashHandler(url)
                    outcome.changed += 1
                    changes.append(UndoChange(original: url, current: destination,
                                              snapshot: try FileTreeSnapshot(at: destination)))
                }
            }
        } catch { outcome.errors.append(Self.message(error)) }
        if !changes.isEmpty { history.append(UndoBatch(copies: copies, changes: changes)) }
        outcome.canUndo = !history.isEmpty
        return outcome
    }

    func undo() -> FileOperationOutcome {
        var outcome = FileOperationOutcome()
        guard var batch = history.popLast() else { return outcome }
        do {
            for change in batch.changes {
                guard try FileTreeSnapshot(at: change.current) == change.snapshot else {
                    throw FileOperationError.changed(change.current)
                }
            }
            if batch.copies {
                // Removing a copied item remains recoverable through the system Trash.
                var remaining = batch.changes
                for change in batch.changes.reversed() {
                    try Task.checkCancellation()
                    _ = try trashHandler(change.current)
                    outcome.changed += 1
                    remaining.removeLast()
                    batch.changes = remaining
                }
            } else {
                let inverse = batch.changes.map { FileTransfer(source: $0.current, destination: $0.original) }
                try validate(inverse, allowCycles: true)
                try rename(inverse)
                outcome.changed = inverse.count
                batch.changes.removeAll()
            }
        } catch { outcome.errors.append(Self.message(error)) }
        if !batch.changes.isEmpty { history.append(batch) }
        outcome.canUndo = !history.isEmpty
        return outcome
    }

    func validate(_ transfers: [FileTransfer], allowCycles: Bool) throws {
        let sources = transfers.map(\.source)
        try validateSources(sources)
        var destinations = Set<String>()
        for transfer in transfers {
            let destination = transfer.destination
            try Self.validateName(destination.lastPathComponent, path: destination.path)
            let parent = destination.deletingLastPathComponent()
            var directory: ObjCBool = false
            guard fm.fileExists(atPath: parent.path, isDirectory: &directory), directory.boolValue else {
                throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: parent.path])
            }
            let volume = try parent.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
            let name = destination.lastPathComponent.precomposedStringWithCanonicalMapping
            let key = parent.resolvingSymlinksInPath().path + "/" +
                (volume.volumeSupportsCaseSensitiveNames == true ? name : name.lowercased())
            guard destinations.insert(key).inserted else {
                throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: destination.path])
            }
            if Self.exists(destination) {
                let isSource = sources.contains { $0.path.utf8.elementsEqual(destination.path.utf8) }
                let isSameItem = try allowCycles && FileTreeSnapshot.identity(at: transfer.source) ==
                    FileTreeSnapshot.identity(at: destination)
                guard allowCycles && (isSource || isSameItem) else {
                    throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: destination.path])
                }
            }
            let physicalDestination = parent.resolvingSymlinksInPath().appendingPathComponent(destination.lastPathComponent)
            if try FileTreeSnapshot.isDirectory(at: transfer.source),
               Self.contains(transfer.source.resolvingSymlinksInPath(), physicalDestination) {
                throw CocoaError(.fileWriteInvalidFileName, userInfo: [NSFilePathErrorKey: destination.path])
            }
        }
    }

    private func validateSources(_ urls: [URL]) throws {
        let ordered = urls.map { (original: $0, physical: Self.physicalPath($0)) }
            .sorted { $0.physical.pathComponents.joined(separator: "\0").utf8
                .lexicographicallyPrecedes($1.physical.pathComponents.joined(separator: "\0").utf8) }
        for (index, item) in ordered.enumerated() {
            let url = item.original
            guard url.isFileURL, url.standardizedFileURL.path != "/" else {
                throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: url.path])
            }
            _ = try FileTreeSnapshot.identity(at: url)
            if index > 0 {
                let other = ordered[index - 1].physical
                if item.physical.path.utf8.elementsEqual(other.path.utf8) || Self.contains(item.physical, other) || Self.contains(other, item.physical) {
                    throw CocoaError(.fileWriteInvalidFileName, userInfo: [NSFilePathErrorKey: url.path])
                }
            }
        }
    }

    /// Stage each name first so swaps, case-only renames, and undo use the same path.
    private func rename(_ transfers: [FileTransfer]) throws {
        var staged: [(item: FileTransfer, temporary: URL, finished: Bool)] = []
        do {
            for item in transfers {
                try Task.checkCancellation()
                let temporary = item.source.deletingLastPathComponent()
                    .appendingPathComponent(".EverythingMac-" + UUID().uuidString)
                try fm.moveItem(at: item.source, to: temporary)
                staged.append((item, temporary, false))
            }
            for index in staged.indices {
                try Task.checkCancellation()
                try fm.moveItem(at: staged[index].temporary, to: staged[index].item.destination)
                staged[index].finished = true
            }
        } catch {
            var failures = [Self.message(error)]
            // Move completed destinations back to staging before restoring original names.
            for index in staged.indices where staged[index].finished {
                do {
                    try fm.moveItem(at: staged[index].item.destination, to: staged[index].temporary)
                    staged[index].finished = false
                } catch { failures.append(Self.message(error)) }
            }
            for item in staged where !item.finished {
                do { try fm.moveItem(at: item.temporary, to: item.item.source) }
                catch { failures.append(Self.message(error)) }
            }
            throw NSError(domain: NSCocoaErrorDomain, code: CocoaError.fileWriteUnknown.rawValue,
                          userInfo: [NSLocalizedDescriptionKey: failures.joined(separator: "\n")])
        }
    }

    static func validateName(_ name: String, path: String) throws {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else {
            throw CocoaError(.fileWriteInvalidFileName, userInfo: [NSFilePathErrorKey: path])
        }
    }

    static func exists(_ url: URL) -> Bool {
        var info = stat()
        return url.withUnsafeFileSystemRepresentation { path in path.map { lstat($0, &info) == 0 } ?? false }
    }

    private static func contains(_ parent: URL, _ child: URL) -> Bool {
        let prefix = parent.standardizedFileURL.pathComponents
        let parts = child.standardizedFileURL.pathComponents
        return parts.count > prefix.count && parts.prefix(prefix.count).elementsEqual(prefix)
    }

    private static func physicalPath(_ url: URL) -> URL {
        url.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(url.lastPathComponent)
    }

    private static func message(_ error: any Error) -> String {
        if error is CancellationError { return CocoaError(.userCancelled).localizedDescription }
        return (error as NSError).localizedDescription
    }
}

private struct FileTreeSnapshot: Sendable, Equatable {
    private struct Entry: Sendable, Equatable {
        let path: [UInt8]
        let device: Int32
        let inode: UInt64
        let mode: UInt16
        let size: Int64
        let modified: Int64
        let modifiedNanos: Int64
        let changed: Int64
        let changedNanos: Int64
    }
    private var entries: [Entry] = []

    init(at root: URL) throws { try append(root, relative: "") }

    static func identity(at url: URL) throws -> [UInt64] {
        let info = try metadata(url)
        return [UInt64(bitPattern: Int64(info.st_dev)), UInt64(info.st_ino)]
    }

    static func isDirectory(at url: URL) throws -> Bool {
        try metadata(url).st_mode & S_IFMT == S_IFDIR
    }

    private mutating func append(_ url: URL, relative: String) throws {
        try Task.checkCancellation()
        let info = try Self.metadata(url)
        entries.append(Entry(path: Array(relative.utf8), device: info.st_dev, inode: info.st_ino,
                             mode: info.st_mode, size: info.st_size,
                             modified: Int64(info.st_mtimespec.tv_sec), modifiedNanos: Int64(info.st_mtimespec.tv_nsec),
                             changed: Int64(info.st_ctimespec.tv_sec), changedNanos: Int64(info.st_ctimespec.tv_nsec)))
        guard info.st_mode & S_IFMT == S_IFDIR else { return }
        let children = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
            .sorted { $0.lastPathComponent.utf8.lexicographicallyPrecedes($1.lastPathComponent.utf8) }
        for child in children { try append(child, relative: relative + "/" + child.lastPathComponent) }
    }

    private static func metadata(_ url: URL) throws -> stat {
        var info = stat()
        let success = url.withUnsafeFileSystemRepresentation { path in path.map { lstat($0, &info) == 0 } ?? false }
        guard success else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: url.path])
        }
        return info
    }
}
