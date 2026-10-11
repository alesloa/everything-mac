import Foundation

enum QueryTextScope: Sendable { case automatic, name, path, parent }

enum QueryPredicate: Sendable {
    case text(Query.Token, QueryTextScope)
    case extensionList([String])
    case directory(Bool)
    case typedText(Bool, Query.Token)
    case size(SizeConstraint)
    case date(DateConstraint)
    case regex(String)

    static func parse(_ raw: String, quoted: Bool, date: Date,
                      forcedLiteral: Bool = false) throws -> (predicate: QueryPredicate, structured: Bool, relative: Bool) {
        let plain = (QueryPredicate.text(Query.Token(text: raw, quoted: quoted), .automatic), false, false)
        guard !forcedLiteral, let colon = raw.firstIndex(of: ":") else { return plain }
        let key = raw[..<colon].lowercased()
        let value = String(raw[raw.index(after: colon)...])
        // A colon in a filename or URL stays literal unless it names a supported
        // search function. Quoting the whole term always requests a literal.
        let known = ["ext", "size", "dm", "date-modified", "file", "folder", "path", "parent", "name", "regex"]
        guard known.contains(key) else { return plain }
        if key == "file" || key == "folder" {
            if value.isEmpty { return (.directory(key == "folder"), true, false) }
            return (.typedText(key == "folder", Query.Token(text: value, quoted: quoted)), true, false)
        }
        guard !value.isEmpty else { throw QueryValidationError("The \(key): search function requires a value.") }
        switch key {
        case "ext":
            let values = value.split(separator: ";", omittingEmptySubsequences: false).map { part in
                part.hasPrefix(".") ? String(part.dropFirst()) : String(part)
            }
            guard values.allSatisfy({ !$0.isEmpty && !$0.contains("/") && !$0.contains("*") && !$0.contains("?") }) else {
                throw QueryValidationError("The ext: search function requires extensions separated by semicolons.")
            }
            return (.extensionList(values), true, false)
        case "size": return (.size(try SizeConstraint.parse(value)), true, false)
        case "dm", "date-modified":
            let constraint = try DateConstraint.parse(value, referenceDate: date)
            return (.date(constraint.0), true, constraint.1)
        case "regex":
            try QuerySyntax.validateRegex(value)
            return (.regex(value), true, false)
        default:
            let scope: QueryTextScope = key == "path" ? .path : key == "parent" ? .parent : .name
            return (.text(Query.Token(text: value, quoted: quoted), scope), true, false)
        }
    }
}

enum QueryComparison: String, Sendable {
    case equal = "=", unequal = "!=", less = "<", lessEqual = "<=", greater = ">", greaterEqual = ">="
    static func separate(_ text: String) -> (QueryComparison, String) {
        for op in ["!=", "<=", ">=", "=", "<", ">"] {
            if text.hasPrefix(op) { return (QueryComparison(rawValue: op)!, String(text.dropFirst(op.count))) }
        }
        return (.equal, text)
    }
    func matches<T: Comparable>(_ value: T, _ bound: T) -> Bool {
        switch self {
        case .equal: value == bound
        case .unequal: value != bound
        case .less: value < bound
        case .lessEqual: value <= bound
        case .greater: value > bound
        case .greaterEqual: value >= bound
        }
    }
}

enum SizeConstraint: Sendable {
    case comparison(QueryComparison, UInt64)
    case range(UInt64, UInt64)
    func matches(_ bytes: UInt64) -> Bool {
        switch self {
        case .comparison(let op, let value): op.matches(bytes, value)
        case .range(let lower, let upper): bytes >= lower && bytes <= upper
        }
    }
    static func parse(_ text: String) throws -> SizeConstraint {
        if text.contains("..") {
            let pieces = text.components(separatedBy: "..")
            guard pieces.count == 2 else { throw QueryValidationError("The size: range requires two sizes separated by ..") }
            let lower = try bytes(pieces[0]), upper = try bytes(pieces[1])
            guard lower <= upper else { throw QueryValidationError("The size: range ends before it begins.") }
            return .range(lower, upper)
        }
        let (op, value) = QueryComparison.separate(text)
        return .comparison(op, try bytes(value))
    }
    static func bytes(_ text: String) throws -> UInt64 {
        let number = text.prefix { $0.isASCII && ($0.isNumber || $0 == ".") }
        let unit = text.dropFirst(number.count).lowercased()
        let factors: [String: UInt64] = ["": 1, "b": 1, "k": 1000, "kb": 1000, "m": 1_000_000,
            "mb": 1_000_000, "g": 1_000_000_000, "gb": 1_000_000_000, "t": 1_000_000_000_000,
            "tb": 1_000_000_000_000, "kib": 1024, "mib": 1_048_576, "gib": 1_073_741_824, "tib": 1_099_511_627_776]
        guard !number.isEmpty, number.filter({ $0 == "." }).count <= 1,
              let factor = factors[unit], let decimal = Decimal(string: String(number), locale: Locale(identifier: "en_US_POSIX")) else {
            throw QueryValidationError("The size: value must be a nonnegative number with B, KB, MB, GB, TB, KiB, MiB, GiB, or TiB.")
        }
        let value = decimal * Decimal(factor)
        let maximum = Decimal(string: String(UInt64.max))!
        guard value >= 0, value <= maximum else { throw QueryValidationError("The size: value is outside the supported byte range.") }
        let ns = NSDecimalNumber(decimal: value)
        let integer = ns.uint64Value
        guard Decimal(integer) == value else { throw QueryValidationError("The size: value does not resolve to a whole number of bytes.") }
        return integer
    }
}

enum DateConstraint: Sendable {
    case interval(Int64, Int64, excluding: Bool)
    case comparison(QueryComparison, Int64)
    func matches(_ timestamp: Int64) -> Bool {
        switch self {
        case .interval(let lower, let upper, let excluding):
            return (timestamp >= lower && timestamp < upper) != excluding
        case .comparison(let op, let value): return op.matches(timestamp, value)
        }
    }
    static func parse(_ text: String, referenceDate: Date) throws -> (DateConstraint, Bool) {
        if text.contains("..") {
            let pieces = text.components(separatedBy: "..")
            guard pieces.count == 2 else { throw QueryValidationError("The dm: range requires two dates separated by ..") }
            let start = try day(pieces[0], referenceDate: referenceDate)
            let end = try day(pieces[1], referenceDate: referenceDate)
            guard start.lower <= end.lower else { throw QueryValidationError("The dm: range ends before it begins.") }
            return (.interval(start.lower, end.upper, excluding: false), start.relative || end.relative)
        }
        let (op, value) = QueryComparison.separate(text)
        let date = try day(value, referenceDate: referenceDate)
        switch op {
        case .equal: return (.interval(date.lower, date.upper, excluding: false), date.relative)
        case .unequal: return (.interval(date.lower, date.upper, excluding: true), date.relative)
        case .greater: return (.comparison(.greaterEqual, date.upper), date.relative)
        case .greaterEqual: return (.comparison(.greaterEqual, date.lower), date.relative)
        case .less: return (.comparison(.less, date.lower), date.relative)
        case .lessEqual: return (.comparison(.less, date.upper), date.relative)
        }
    }
    private static func day(_ text: String, referenceDate: Date) throws -> (lower: Int64, upper: Int64, relative: Bool) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let value: Date
        let relative: Bool
        switch text.lowercased() {
        case "today": value = referenceDate; relative = true
        case "yesterday":
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: referenceDate) else {
                throw QueryValidationError("The dm: relative date could not be calculated.")
            }
            value = yesterday; relative = true
        default:
            let pieces = text.split(separator: "-", omittingEmptySubsequences: false)
            guard pieces.count == 3, pieces[0].count == 4, pieces[1].count == 2, pieces[2].count == 2,
                  let year = Int(pieces[0]), let month = Int(pieces[1]), let day = Int(pieces[2]),
                  year >= 1, year <= 9999, month >= 1, month <= 12, day >= 1, day <= 31,
                  let candidate = calendar.date(from: DateComponents(year: year, month: month, day: day)) else {
                throw QueryValidationError("The dm: value must be YYYY-MM-DD, today, or yesterday.")
            }
            let components = calendar.dateComponents([.year, .month, .day], from: candidate)
            guard components.year == year, components.month == month, components.day == day else {
                throw QueryValidationError("The dm: value is not a valid calendar date.")
            }
            value = candidate; relative = false
        }
        let start = calendar.startOfDay(for: value)
        guard let next = calendar.date(byAdding: .day, value: 1, to: start) else {
            throw QueryValidationError("The dm: date boundary could not be calculated.")
        }
        return (Int64(start.timeIntervalSince1970), Int64(next.timeIntervalSince1970), relative)
    }
}
