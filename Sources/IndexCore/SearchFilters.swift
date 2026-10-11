import Foundation

/// Source: units and byte conversions use this application's size: query parser.
public struct SearchSizeLimit: Codable, Equatable, Sendable {
    public enum Unit: String, CaseIterable, Codable, Sendable {
        case bytes = "B", kilobytes = "KB", megabytes = "MB", gigabytes = "GB", terabytes = "TB"
    }
    public var amount: String
    public var unit: Unit

    public init(amount: String = "", unit: Unit = .megabytes) {
        self.amount = amount; self.unit = unit
    }
    public var queryValue: String { amount.trimmingCharacters(in: .whitespacesAndNewlines) + unit.rawValue }

    public func byteCount() throws -> UInt64 {
        let number = amount.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !number.isEmpty, number.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }) else {
            throw QueryValidationError("Enter a nonnegative size using numbers and a decimal point.")
        }
        return try SizeConstraint.bytes(queryValue)
    }
}

/// Source: categories come from SearchFilter; size bounds are owner-entered values.
/// Types are combined with OR, then size bounds narrow that union with AND.
public struct SearchFilters: Codable, Equatable, Sendable {
    public var types: Set<SearchFilter>
    public var over: SearchSizeLimit?
    public var under: SearchSizeLimit?

    public init(types: Set<SearchFilter> = [], over: SearchSizeLimit? = nil, under: SearchSizeLimit? = nil) {
        self.types = types.subtracting([.all]); self.over = over; self.under = under
    }
    public var isEmpty: Bool { types.subtracting([.all]).isEmpty && over == nil && under == nil }
    public var activeCount: Int { types.subtracting([.all]).count + (over == nil ? 0 : 1) + (under == nil ? 0 : 1) }

    /// A broad Files choice and specific file categories replace each other;
    /// Folders can be combined with either. Remaining categories still form a union.
    public mutating func selectType(_ filter: SearchFilter, selected: Bool) {
        if !selected { types.remove(filter); return }
        if filter == .all { types = []; return }
        if filter == .files { types.formIntersection([.folders]) }
        else if filter != .folders { types.remove(.files) }
        types.insert(filter)
    }

    public var validationError: QueryValidationError? {
        do {
            let lower = try over?.byteCount(), upper = try under?.byteCount()
            if let lower, let upper, lower >= upper {
                throw QueryValidationError("The Over size must be smaller than the Under size.")
            }
            return nil
        } catch let error as QueryValidationError { return error }
        catch { return QueryValidationError(error.localizedDescription) }
    }

    // Source: summary labels describe the actual selected categories and bounds.
    public var summary: String {
        var pieces = SearchFilter.allCases.filter { $0 != .all && types.contains($0) }.map(\.title)
        if let over { pieces.append("Over \(over.amount) \(over.unit.rawValue)") }
        if let under { pieces.append("Under \(under.amount) \(under.unit.rawValue)") }
        return pieces.isEmpty ? SearchFilter.all.title : pieces.joined(separator: ", ")
    }

    public func applying(to text: String) -> String {
        var parts: [String] = []
        let fragments = SearchFilter.allCases.filter { $0 != .all && types.contains($0) }.map { filter in
            filter == .files || filter == .folders ? filter.queryFragment : "file: \(filter.queryFragment)"
        }
        if !fragments.isEmpty { parts.append("(" + fragments.map { "(\($0))" }.joined(separator: " | ") + ")") }
        if over != nil || under != nil { parts.append("file:") }
        if let over { parts.append("size:\(Query.quotedLiteral(">" + over.queryValue))") }
        if let under { parts.append("size:\(Query.quotedLiteral("<" + under.queryValue))") }
        guard !parts.isEmpty else { return text }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed.isEmpty ? [] : ["(\(text))"]).joined(separator: " ")
            + (trimmed.isEmpty ? "" : " ") + parts.joined(separator: " ")
    }

    public func applying(to query: Query) -> Query {
        guard !isEmpty else { return query }
        var query = query
        if query.regex { query.regex = false; query.text = "regex:\(Query.quotedLiteral(query.text))" }
        query.text = applying(to: query.text)
        return query
    }
}
