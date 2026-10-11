import Foundation

/// Sources: paths/metadata come from the existing reconcile listing and indexed
/// records; POSIX failure descriptions come from the failing filesystem call.
public struct ReconcileObservation: Sendable, Equatable {
    public enum Kind: Sendable { case added, removed, metadata, incomplete }
    public let kind: Kind
    public let path: String
    public let size: UInt64?
    public let modificationTime: Int64?
    public let priorSize: UInt64?
    public let priorModificationTime: Int64?
    public let failure: String?

    static func added(_ path: String) -> Self { Self(kind: .added, path: path) }
    static func removed(_ path: String) -> Self { Self(kind: .removed, path: path) }
    static func metadata(_ path: String, size: UInt64, mtime: Int64, priorSize: UInt64, priorMtime: Int64) -> Self {
        Self(kind: .metadata, path: path, size: size, modificationTime: mtime,
             priorSize: priorSize, priorModificationTime: priorMtime)
    }
    static func failed(_ path: String, error: Int32) -> Self {
        Self(kind: .incomplete, path: path,
             failure: NSError(domain: NSPOSIXErrorDomain, code: Int(error)).localizedDescription)
    }
    static func invalidSize(_ path: String) -> Self {
        // Source: this label describes the negative st_size returned by fstatat.
        Self(kind: .incomplete, path: path, failure: "Filesystem reported a negative size.")
    }

    private init(kind: Kind, path: String, size: UInt64? = nil, modificationTime: Int64? = nil,
                 priorSize: UInt64? = nil, priorModificationTime: Int64? = nil, failure: String? = nil) {
        self.kind = kind; self.path = path; self.size = size; self.modificationTime = modificationTime
        self.priorSize = priorSize; self.priorModificationTime = priorModificationTime; self.failure = failure
    }
}
