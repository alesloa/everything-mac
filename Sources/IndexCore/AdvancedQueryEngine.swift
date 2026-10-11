import Foundation

extension QueryEngine {
    func advancedMatches(_ input: Query, in store: FileStore, candidates: [UInt32]?,
                         isCancelled: @escaping @Sendable () -> Bool) -> [SearchMatch] {
        let query = input.refreshingRelativeDates()
        guard query.validationError == nil, !isCancelled() else { return [] }
        guard let expression = try? PreparedExpression(query.plan.expression, query: query) else { return [] }
        let n = candidates?.count ?? store.count
        return searchParts(count: n, parallelThreshold: 100_000, isCancelled: isCancelled) { lo, hi in
            var matches: [SearchMatch] = []
            for offset in lo..<hi {
                if offset & 127 == 0 && isCancelled() { return [] }
                let id = candidates?[offset] ?? UInt32(offset)
                guard Int(id) < store.count, store.isLive(id) else { continue }
                if let score = expression.score(id, in: store, query: query, isCancelled: isCancelled) {
                    matches.append(SearchMatch(id: id, score: score))
                }
            }
            return isCancelled() ? [] : matches
        }
    }
}

private indirect enum PreparedExpression: Sendable {
    case predicate(PreparedPredicate)
    case and([PreparedExpression]), or([PreparedExpression]), not(PreparedExpression)

    init(_ expression: QueryExpression, query: Query) throws {
        switch expression {
        case .predicate(let predicate): self = .predicate(try PreparedPredicate(predicate, query: query))
        case .and(let expressions):
            // Cheap type/size/date checks reject candidates before allocating a
            // filename/path. Preserve the order within equal-cost predicates.
            let sorted = expressions.enumerated().sorted {
                let a = Self.cost($0.element), b = Self.cost($1.element)
                return a == b ? $0.offset < $1.offset : a < b
            }
            self = .and(try sorted.map { try PreparedExpression($0.element, query: query) })
        case .or(let expressions): self = .or(try expressions.map { try PreparedExpression($0, query: query) })
        case .not(let expression): self = .not(try PreparedExpression(expression, query: query))
        }
    }
    private static func cost(_ expression: QueryExpression) -> Int {
        if case .predicate(let predicate) = expression {
            switch predicate {
            case .directory, .size, .date: return 0
            case .extensionList, .typedText: return 1
            case .text(_, .automatic), .text(_, .name): return 2
            case .text: return 3
            case .regex: return 4
            }
        }
        return 5
    }
    func score(_ id: UInt32, in store: FileStore, query: Query,
               isCancelled: @Sendable () -> Bool) -> Int? {
        switch self {
        case .predicate(let predicate): return predicate.score(id, in: store, query: query, isCancelled: isCancelled)
        case .and(let expressions):
            var total = 0
            for expression in expressions {
                guard let score = expression.score(id, in: store, query: query, isCancelled: isCancelled) else { return nil }
                total += score
            }
            return total
        case .or(let expressions):
            var best: Int?
            for expression in expressions {
                if let score = expression.score(id, in: store, query: query, isCancelled: isCancelled) {
                    best = max(best ?? score, score)
                }
            }
            return best
        case .not(let expression): return expression.score(id, in: store, query: query, isCancelled: isCancelled) == nil ? 0 : nil
        }
    }
}

private enum PreparedPredicate: Sendable {
    case text(PreparedText, QueryTextScope), typedText(Bool, PreparedText)
    case extensionList([String], [[UInt8]]?), directory(Bool), size(SizeConstraint), date(DateConstraint)
    case regex(NSRegularExpression)

    init(_ predicate: QueryPredicate, query: Query) throws {
        switch predicate {
        case .text(let term, let scope): self = .text(PreparedText(term, query: query), scope)
        case .typedText(let directory, let term): self = .typedText(directory, PreparedText(term, query: query))
        case .extensionList(let values):
            let folded = values.map { query.fold($0) }
            let byteSafe = !query.diacriticInsensitive && !query.ignorePunctuation && !query.ignoreWhitespace
                && folded.allSatisfy { $0.utf8.allSatisfy { $0 < 128 } }
            self = .extensionList(folded, byteSafe ? folded.map { Array($0.utf8) } : nil)
        case .directory(let value): self = .directory(value)
        case .size(let value): self = .size(value)
        case .date(let value): self = .date(value)
        case .regex(let pattern):
            // Regex syntax is preserved. Normalization options apply to ordinary
            // text terms; regex gets its explicit case-insensitive flag only.
            self = .regex(try NSRegularExpression(pattern: pattern, options: query.caseInsensitive ? [.caseInsensitive] : []))
        }
    }
    func score(_ id: UInt32, in store: FileStore, query: Query,
               isCancelled: @Sendable () -> Bool) -> Int? {
        switch self {
        case .directory(let expected): return store.isDir(of: id) == expected ? 0 : nil
        case .size(let condition): return !store.isDir(of: id) && condition.matches(store.size(of: id)) ? 0 : nil
        case .date(let condition): return condition.matches(store.mtime(of: id)) ? 0 : nil
        case .extensionList(let extensions, let ascii):
            guard !store.isDir(of: id) else { return nil }
            if let ascii {
                // Built-in filters use ASCII extensions. Compare the arena bytes
                // directly instead of allocating one String per indexed record.
                let matches = store.withNameArena { arena in
                    let name = arena.bytes(in: store.nameRange(of: id))
                    var dot = name.count - 1
                    while dot > 0 && name[dot] != 46 { dot -= 1 }
                    guard dot > 0 else { return false }
                    for extensionBytes in ascii where extensionBytes.count == name.count - dot - 1 {
                        var equal = true
                        for index in extensionBytes.indices {
                            let byte = name[dot + index + 1]
                            let folded = query.caseInsensitive && byte >= 65 && byte <= 90 ? byte &+ 32 : byte
                            if folded != extensionBytes[index] { equal = false; break }
                        }
                        if equal { return true }
                    }
                    return false
                }
                return matches ? 0 : nil
            }
            let name = store.name(of: id)
            guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return nil }
            return extensions.contains(query.fold(String(name[name.index(after: dot)...]))) ? 0 : nil
        case .typedText(let directory, let term):
            guard store.isDir(of: id) == directory else { return nil }
            return term.score(query.matchPath ? store.path(of: id) : store.name(of: id), query: query)
        case .text(let term, let scope):
            let text: String
            switch scope {
            case .automatic: text = query.matchPath ? store.path(of: id) : store.name(of: id)
            case .name: text = store.name(of: id)
            case .path: text = store.path(of: id)
            case .parent:
                let parent = store.parent(of: id)
                guard parent != FileStore.noParent else { return nil }
                text = store.path(of: parent)
                // parent: chooses a direct containing directory, rather than all
                // descendants of a directory with a matching path substring.
                if !term.wildcard {
                    return query.fold(text).utf8.elementsEqual(term.pattern.utf8) ? 0 : nil
                }
            }
            return term.score(text, query: query)
        case .regex(let regex):
            guard !isCancelled() else { return nil }
            let text = query.matchPath ? store.path(of: id) : store.name(of: id)
            var matched = false
            regex.enumerateMatches(in: text, options: [.reportProgress], range: NSRange(text.startIndex..., in: text)) { result, _, stop in
                if isCancelled() { stop.pointee = true }
                if result != nil { matched = true; stop.pointee = true }
            }
            return matched && !isCancelled() ? 0 : nil
        }
    }
}

private struct PreparedText: Sendable {
    let pattern: String
    let wildcard: Bool
    let fuzzy: Bool
    let asciiFuzzy: FuzzyMatcher.Pattern?
    init(_ token: Query.Token, query: Query) {
        pattern = query.fold(token.text, preservingWildcards: true)
        wildcard = token.text.contains("*") || token.text.contains("?")
        fuzzy = query.fuzzy && !query.wholeWord && !query.matchPrefix && !query.matchSuffix && !token.isLiteral
        asciiFuzzy = fuzzy && pattern.utf8.allSatisfy({ $0 < 128 }) ? FuzzyMatcher.Pattern(pattern, caseInsensitive: false) : nil
    }
    func score(_ input: String, query: Query) -> Int? {
        let text = query.fold(input)
        if wildcard { return Glob.matches(pattern: pattern, in: text, caseInsensitive: false) ? 0 : nil }
        if query.matchPrefix || query.matchSuffix {
            let scalars = Array(text.unicodeScalars), needle = Array(pattern.unicodeScalars)
            if query.matchPrefix && !scalars.starts(with: needle) { return nil }
            if query.matchSuffix && !scalars.reversed().starts(with: needle.reversed()) { return nil }
            if query.wholeWord {
                let words = CharacterSet.alphanumerics
                if query.matchPrefix && scalars.count > needle.count && words.contains(scalars[needle.count]) { return nil }
                if query.matchSuffix && scalars.count > needle.count && words.contains(scalars[scalars.count - needle.count - 1]) { return nil }
            }
            return 0
        }
        if query.wholeWord { return Glob.containsWholeWord(pattern, in: text, caseInsensitive: false) ? 0 : nil }
        if fuzzy {
            if let asciiFuzzy {
                return Array(text.utf8).withUnsafeBufferPointer {
                    asciiFuzzy.score($0, nameMask: FuzzyMatcher.mask($0), matchPath: query.matchPath)
                }
            }
            return FuzzyMatcher.unicodeScore(text, pattern, ci: false)
        }
        return Glob.matches(pattern: pattern, in: text, caseInsensitive: false) ? 0 : nil
    }
}

private extension Query {
    func fold(_ input: String, preservingWildcards: Bool = false) -> String {
        var result = diacriticInsensitive ? input.folding(options: [.diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX")) : input
        if caseInsensitive { result = result.lowercased() }
        if ignorePunctuation || ignoreWhitespace {
            result = String(String.UnicodeScalarView(result.unicodeScalars.filter {
                !(ignorePunctuation && CharacterSet.punctuationCharacters.contains($0)
                    && !(preservingWildcards && ($0 == "*" || $0 == "?")))
                    && !(ignoreWhitespace && CharacterSet.whitespacesAndNewlines.contains($0))
            }))
        }
        return result
    }
}
