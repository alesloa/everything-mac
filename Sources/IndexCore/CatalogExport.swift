import Foundation

extension CatalogIO {
    @discardableResult
    public static func exportSelection(_ selection: SearchRowSelection, to url: URL, format: CatalogFormat,
                                       isCancelled: @escaping @Sendable () -> Bool = { false }) throws -> Int {
        let namespace = UUID()
        return try exportStream(to: url, format: format, isCancelled: isCancelled) { emit in
            for row in selection.rows {
                if isCancelled() { throw CancellationError() }
                guard let record = selection.list.record(at: row) else { throw CancellationError() }
                try emit(CatalogRecord(native: record, catalogID: namespace))
            }
        }
    }
    /// Exports exactly these visible/selected rows in their supplied order.
    @discardableResult
    public static func exportRows(_ rows: [CatalogRecord], to url: URL, format: CatalogFormat,
                                  isCancelled: @escaping @Sendable () -> Bool = { false }) throws -> Int {
        try exportStream(to: url, format: format, isCancelled: isCancelled) { emit in
            for row in rows { try emit(row) }
        }
    }

    /// Streams ALL matching rows from stable snapshots, independent of UI limits.
    /// Source order is intentional; global display sorting would require retaining
    /// every match. Selected/shown exports retain their current displayed order.
    @discardableResult
    public static func exportMatching(_ catalogs: [FileCatalogSnapshot], native: FileStore? = nil,
                                      query: Query, to url: URL, format: CatalogFormat,
                                      isCancelled: @escaping @Sendable () -> Bool = { false }) throws -> Int {
        let matcher = try CatalogQueryMatcher(query)
        return try exportStream(to: url, format: format, isCancelled: isCancelled) { emit in
            for catalog in catalogs {
                for row in 0..<catalog.count {
                    if isCancelled() { throw CancellationError() }
                    if let record = catalog.record(at: row), matcher.score(record, isCancelled: isCancelled) != nil { try emit(record) }
                }
            }
            if let native {
                let namespace = UUID()
                let ids = QueryEngine().search(query, in: native, isCancelled: isCancelled).sorted()
                for id in ids {
                    if isCancelled() { throw CancellationError() }
                    let file = FileRecord(id: id, name: native.name(of: id), path: native.path(of: id), parent: native.parent(of: id),
                                          size: native.size(of: id), mtime: native.mtime(of: id), isDir: native.isDir(of: id), volID: native.volID(of: id))
                    let record = CatalogRecord(native: file, catalogID: namespace)
                    try emit(record)
                }
            }
        }
    }

    @discardableResult
    public static func exportNative(store: FileStore, query: Query, sort: QueryEngine.SortKey = .relevance,
                                    ascending: Bool = true, folderPath: String? = nil, to url: URL, format: CatalogFormat,
                                    isCancelled: @escaping @Sendable () -> Bool = { false }) throws -> Int {
        let ids = try CatalogSearch.nativeIDs(store: store, query: query, sort: sort, ascending: ascending,
                                              folderPath: folderPath, isCancelled: isCancelled)
        let namespace = UUID()
        return try exportStream(to: url, format: format, isCancelled: isCancelled) { emit in
            // Sorting retains compact IDs only; full-path records are emitted
            // individually, with exactly the native query and sort semantics.
            for id in ids {
                if isCancelled() { throw CancellationError() }
                let file = FileRecord(id: id, name: store.name(of: id), path: store.path(of: id), parent: store.parent(of: id),
                                      size: store.size(of: id), mtime: store.mtime(of: id), isDir: store.isDir(of: id), volID: store.volID(of: id))
                try emit(CatalogRecord(native: file, catalogID: namespace))
            }
        }
    }

    private static func exportStream(to url: URL, format: CatalogFormat, isCancelled: @escaping @Sendable () -> Bool,
                                     producer: ((CatalogRecord) throws -> Void) throws -> Void) throws -> Int {
        var count = 0
        try atomicWrite(to: url, isCancelled: isCancelled) { handle in
            count = try writeStream(format: format, write: { try handle.write(contentsOf: $0) },
                                    isCancelled: isCancelled, producer: producer)
        }
        return count
    }

    /// Uses the same catalog serializer for files, stdout and other byte sinks.
    /// The caller owns the sink; this method neither opens nor replaces a file.
    @discardableResult
    public static func writeStream(format: CatalogFormat, write: @escaping (Data) throws -> Void,
                                   isCancelled: @escaping @Sendable () -> Bool = { false },
                                   producer: ((CatalogRecord) throws -> Void) throws -> Void) throws -> Int {
        var count = 0
        if isCancelled() { throw CancellationError() }
        let delimiter: Character = format == .tsv ? "\t" : ","
        if format == .efu || format == .csv || format == .tsv {
            // Column names and FILETIME representation come from the public
            // EFU specification; Directory preserves unknown optional type.
            let header = ["Filename", "Size", "Date Modified", "Date Created", "Attributes", "Directory"]
            try write(Data((header.joined(separator: String(delimiter)) + "\r\n").utf8))
        } else if format == .json { try write(Data("[\n".utf8)) }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try producer { record in
            if isCancelled() { throw CancellationError() }
            let data: Data
            if format == .json {
                // IDs are internal catalog row identities, not published
                // metadata. Export only actual source fields.
                struct JSONRow: Encodable {
                    let path: String; let size: UInt64?; let modified: CatalogTimestamp?
                    let created: CatalogTimestamp?; let attributes: UInt32?; let directory: Bool?
                }
                let row = JSONRow(path: record.path, size: record.size, modified: record.modified,
                                  created: record.created, attributes: record.attributes, directory: record.isDirectory)
                var bytes = Data((count == 0 ? "" : ",\n").utf8); bytes.append(try encoder.encode(row)); data = bytes
            } else if format == .txt {
                data = Data((catalogQuoted(record.path, delimiter: "\0") + "\r\n").utf8)
            } else {
                func ticks(_ date: CatalogTimestamp?) throws -> String {
                    guard let date else { return "" }
                    guard let ticks = date.filetime else {
                        throw CatalogError.invalidDocument("A date cannot be represented exactly as FILETIME: \(record.path)")
                    }
                    return String(ticks)
                }
                // The Windows directory bit is the documented representation
                // of a directory type actually read from the native stat.
                let attributes = record.attributes ?? (record.isDirectory == true ? 16 : nil)
                let fields = [record.path, record.size.map(String.init) ?? "", try ticks(record.modified),
                              try ticks(record.created), attributes.map(String.init) ?? "",
                              record.isDirectory.map { $0 ? "true" : "false" } ?? ""]
                data = Data((fields.map { catalogQuoted($0, delimiter: delimiter) }.joined(separator: String(delimiter)) + "\r\n").utf8)
            }
            try write(data); count += 1
        }
        if isCancelled() { throw CancellationError() }
        if format == .json { try write(Data("\n]\n".utf8)) }
        return count
    }
}
