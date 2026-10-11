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
    // Missing in older archives, where an empty type set meant Everything.
    public var typeSelectionIsExplicit: Bool?
    public var over: SearchSizeLimit?
    public var under: SearchSizeLimit?

    public init(types: Set<SearchFilter> = [], over: SearchSizeLimit? = nil, under: SearchSizeLimit? = nil) {
        self.types = types.subtracting([.all]); self.over = over; self.under = under
    }
    public static var allTypes: Set<SearchFilter> { Set(SearchFilter.allCases.filter { $0 != .all }) }
    public var selectedTypes: Set<SearchFilter> {
        types.isEmpty && typeSelectionIsExplicit != true ? Self.allTypes : types.subtracting([.all])
    }
    public var everythingSelected: Bool { selectedTypes == Self.allTypes }
    public var isEmpty: Bool { everythingSelected && over == nil && under == nil }
    public var activeCount: Int {
        (everythingSelected ? 0 : max(1, selectedTypes.count)) + (over == nil ? 0 : 1) + (under == nil ? 0 : 1)
    }

    /// All choices remain independent; Files includes every file category.
    public mutating func selectType(_ filter: SearchFilter, selected: Bool) {
        if filter == .all { selectAllTypes(selected); return }
        types = selectedTypes; typeSelectionIsExplicit = true
        if selected { types.insert(filter) } else { types.remove(filter) }
    }

    public mutating func selectAllTypes(_ selected: Bool) {
        types = selected ? Self.allTypes : []
        typeSelectionIsExplicit = true
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
        var pieces = everythingSelected ? [] : SearchFilter.allCases.filter { $0 != .all && selectedTypes.contains($0) }.map(\.title)
        if selectedTypes.isEmpty { pieces.append("No file types") }
        if let over { pieces.append("Over \(over.amount) \(over.unit.rawValue)") }
        if let under { pieces.append("Under \(under.amount) \(under.unit.rawValue)") }
        return pieces.isEmpty ? SearchFilter.all.title : pieces.joined(separator: ", ")
    }

    public func applying(to text: String) -> String {
        var parts: [String] = []
        let fragments = SearchFilter.allCases.filter { $0 != .all && selectedTypes.contains($0) }.map { filter in
            filter == .files || filter == .folders ? filter.queryFragment : "file: \(filter.queryFragment)"
        }
        if selectedTypes.isEmpty { parts.append("file: folder:") }
        else if !everythingSelected { parts.append("(" + fragments.map { "(\($0))" }.joined(separator: " | ") + ")") }
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
