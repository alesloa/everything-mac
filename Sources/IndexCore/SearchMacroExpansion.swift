import Foundation

public enum SearchMacroError: Error, LocalizedError, Equatable, Sendable {
    case unknown(String), duplicate(String), recursive(String), invalidName(String), expansionLimit, missingFilter

    // Source: these messages describe this application's macro validation rules and owner-entered names.
    public var errorDescription: String? {
        switch self {
        case .unknown(let name): "No saved search has the macro name \"\(name)\"."
        case .duplicate(let name): "More than one saved search uses the macro name \"\(name)\"."
        case .recursive(let name): "The saved macro \"\(name)\" refers to itself."
        case .invalidName(let name): "The macro name \"\(name)\" must start with a letter and contain only letters, numbers, underscores, or hyphens."
        case .expansionLimit: "The saved macro expansion exceeds the application's size or nesting limit."
        case .missingFilter: "The selected saved filter is no longer available."
        }
    }
}

public struct SearchMacroExpansion: Sendable {
    public let savedSearches: [SavedSearch]
    // Source: these explicit application limits bound recursive user-saved query expansion.
    public static let maximumDepth = 16
    public static let maximumBytes = 65_536
    public static let maximumReferences = 256

    public init(savedSearches: [SavedSearch]) { self.savedSearches = savedSearches }

    public static func validName(_ name: String) -> Bool {
        let bytes = Array(name.utf8)
        func letter(_ b: UInt8) -> Bool { (65...90).contains(b) || (97...122).contains(b) }
        guard let first = bytes.first, letter(first), bytes.count <= 64 else { return false }
        return bytes.allSatisfy { letter($0) || (48...57).contains($0) || $0 == 95 || $0 == 45 }
    }

    public func expand(_ text: String) throws -> String {
        var budget = Self.maximumReferences
        return try expand(text, stack: [], budget: &budget)
    }

    public func resolve(_ state: SearchWorkspaceState) throws -> Query {
        var state = state
        if let error = state.effectiveFilters.validationError { throw error }
        var budget = Self.maximumReferences
        if !state.regex { state.query = try expand(state.query, stack: [], budget: &budget) }
        var query = state.searchQuery
        if let id = state.customFilterID {
            guard let saved = savedSearches.first(where: { $0.id == id && $0.isCustomFilter }) else { throw SearchMacroError.missingFilter }
            let fragment = try fragment(saved, stack: [], budget: &budget)
            if query.regex { query.text = "regex:\(Query.quotedLiteral(query.text))"; query.regex = false }
            query.text = query.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? fragment : "(\(query.text)) (\(fragment))"
        }
        guard query.text.utf8.count <= Self.maximumBytes else { throw SearchMacroError.expansionLimit }
        return query
    }

    private func fragment(_ saved: SavedSearch, stack: [UUID], budget: inout Int) throws -> String {
        if let error = saved.state.effectiveFilters.validationError { throw error }
        guard stack.count < Self.maximumDepth, budget > 0 else { throw SearchMacroError.expansionLimit }
        guard !stack.contains(saved.id) else { throw SearchMacroError.recursive(saved.macroName.isEmpty ? saved.name : saved.macroName) }
        budget -= 1
        let next = stack + [saved.id]
        var text = saved.state.regex ? "regex:\(Query.quotedLiteral(saved.state.query))"
            : try expand(saved.state.query, stack: next, budget: &budget)
        text = saved.state.effectiveFilters.applying(to: text)
        if let id = saved.state.customFilterID {
            guard let filter = savedSearches.first(where: { $0.id == id && $0.isCustomFilter }) else { throw SearchMacroError.missingFilter }
            let addition = try fragment(filter, stack: next, budget: &budget)
            text = text.isEmpty ? addition : "(\(text)) (\(addition))"
        }
        guard text.utf8.count <= Self.maximumBytes else { throw SearchMacroError.expansionLimit }
        return text
    }

    private func expand(_ text: String, stack: [UUID], budget: inout Int) throws -> String {
        guard text.utf8.count <= Self.maximumBytes, stack.count <= Self.maximumDepth else { throw SearchMacroError.expansionLimit }
        var output = "", i = text.startIndex, quoted = false, escaped = false
        var atBoundary = true
        while i < text.endIndex {
            let char = text[i]
            if escaped { output.append(char); escaped = false; atBoundary = false; i = text.index(after: i); continue }
            if char == "\\" { output.append(char); escaped = true; atBoundary = false; i = text.index(after: i); continue }
            if char == "\"" { quoted.toggle(); output.append(char); atBoundary = false; i = text.index(after: i); continue }
            if !quoted, atBoundary, text[i...].hasPrefix("macro:") {
                let start = text.index(i, offsetBy: 6)
                var end = start
                while end < text.endIndex, !text[end].isWhitespace, !"()<>|".contains(text[end]) { end = text.index(after: end) }
                let name = String(text[start..<end])
                guard Self.validName(name) else { throw SearchMacroError.invalidName(name) }
                let matches = savedSearches.filter { $0.macroName.lowercased() == name.lowercased() }
                guard let saved = matches.first else { throw SearchMacroError.unknown(name) }
                guard matches.count == 1 else { throw SearchMacroError.duplicate(name) }
                output += "(\(try fragment(saved, stack: stack, budget: &budget)))"
                i = end; atBoundary = false
            } else {
                output.append(char); i = text.index(after: i)
                atBoundary = !quoted && (char.isWhitespace || "(<|!".contains(char))
            }
            guard output.utf8.count <= Self.maximumBytes else { throw SearchMacroError.expansionLimit }
        }
        return output
    }
}
