import Foundation

enum ResultColumnKey: String, Codable, CaseIterable {
    case name, path, size, kind, mtime, fileCount, indexedSize

    // Existing labels come from ResultsTable.swift; Files and Indexed Size label the owner's requested indexed descendant totals.
    var title: String {
        switch self {
        case .name: "Name"
        case .path: "Path"
        case .size: "Size"
        case .kind: "Kind"
        case .mtime: "Date Modified"
        case .fileCount: "Files"
        case .indexedSize: "Indexed Size"
        }
    }
    var defaultWidth: Double {
        switch self {
        case .name: 260
        case .path: 380
        case .size: 90
        case .kind: 130
        case .mtime: 160
        case .fileCount: 80
        case .indexedSize: 110
        }
    }
}

struct ResultsColumnLayout: Codable, Equatable {
    struct Column: Codable, Equatable {
        var key: ResultColumnKey
        var width: Double
        var hidden: Bool
    }
    var columns: [Column]
    static let defaultsKey = "resultsColumnLayout.v1"
    static var standard: Self {
        Self(columns: ResultColumnKey.allCases.map {
            Column(key: $0, width: $0.defaultWidth, hidden: $0 == .fileCount || $0 == .indexedSize)
        })
    }

    static func load(from defaults: UserDefaults = .standard) -> Self {
        // Width, order, and visibility come from the actual table layout saved in UserDefaults.
        guard let data = defaults.data(forKey: defaultsKey),
              let value = try? JSONDecoder().decode(Self.self, from: data) else { return .standard }
        return value.sanitized()
    }

    func save(to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(sanitized()) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    func sanitized() -> Self {
        var seen: Set<ResultColumnKey> = []
        var result = columns.filter { seen.insert($0.key).inserted }.map { column in
            var column = column
            column.width = column.width.isFinite ? min(2000, max(40, column.width)) : column.key.defaultWidth
            return column
        }
        for key in ResultColumnKey.allCases where !seen.contains(key) {
            result.append(Column(key: key, width: key.defaultWidth, hidden: key == .fileCount || key == .indexedSize))
        }
        if result.allSatisfy(\.hidden), let index = result.firstIndex(where: { $0.key == .name }) {
            result[index].hidden = false
        }
        return Self(columns: result)
    }
}
