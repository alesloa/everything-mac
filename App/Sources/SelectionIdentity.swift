import IndexCore

struct SelectionIdentity: Sendable, Hashable {
    let id: UInt32
    let path: [UInt8]
    init(_ record: FileRecord) {
        id = record.id
        path = Array(record.path.utf8)
    }
}
