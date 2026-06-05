// One entry. Stored struct-of-arrays inside FileStore; this struct is the
// decoded view returned to callers.
public struct FileRecord: Sendable, Equatable {
    public let id: UInt32
    public let name: String
    public let path: String
    public let parent: UInt32
    public let size: UInt64
    public let mtime: Int64
    public let isDir: Bool
    public let volID: UInt32

    public init(id: UInt32, name: String, path: String, parent: UInt32, size: UInt64, mtime: Int64, isDir: Bool, volID: UInt32) {
        self.id = id; self.name = name; self.path = path; self.parent = parent
        self.size = size; self.mtime = mtime; self.isDir = isDir; self.volID = volID
    }
}
