import Foundation

/// Uses the same parsed public Query, predicates, glob and fuzzy matcher as the
/// native index. Unknown metadata has three-valued boolean behavior: even NOT
/// cannot turn an absent size/date/type into fabricated metadata.
struct CatalogQueryMatcher: Sendable {
    let query: Query
    let expression: Expression
    init(_ input: Query) throws {
        query = input.refreshingRelativeDates()
        if let error = query.validationError { throw error }
        expression = try Expression(query.plan.expression, query: query)
    }
    func score(_ record: CatalogRecord, isCancelled: @Sendable () -> Bool) -> Int? {
        if case .yes(let score) = expression.evaluate(record, query: query, cancelled: isCancelled) { return score }
        return nil
    }
    enum Evaluation { case yes(Int), no, unknown }
    indirect enum Expression: Sendable {
        case text(Text, QueryTextScope), typed(Bool, Text), extensions([String]), directory(Bool)
        case size(SizeConstraint), date(DateConstraint), regex(NSRegularExpression)
        case and([Expression]), or([Expression]), not(Expression)
        init(_ value: QueryExpression, query: Query) throws {
            switch value {
            case .and(let children): self = .and(try children.map { try Expression($0, query: query) })
            case .or(let children): self = .or(try children.map { try Expression($0, query: query) })
            case .not(let child): self = .not(try Expression(child, query: query))
            case .predicate(let predicate):
                switch predicate {
                case .text(let token, let scope): self = .text(Text(token, query: query), scope)
                case .typedText(let directory, let token): self = .typed(directory, Text(token, query: query))
                case .extensionList(let values): self = .extensions(values.map { query.catalogFold($0) })
                case .directory(let value): self = .directory(value)
                case .size(let value): self = .size(value)
                case .date(let value): self = .date(value)
                case .regex(let value): self = .regex(try NSRegularExpression(pattern: value, options: query.caseInsensitive ? [.caseInsensitive] : []))
                }
            }
        }
        func evaluate(_ record: CatalogRecord, query: Query, cancelled: @Sendable () -> Bool) -> Evaluation {
            if cancelled() { return .no }
            func scored(_ value: Int?) -> Evaluation { value.map(Evaluation.yes) ?? .no }
            switch self {
            case .and(let children):
                var score = 0, unknown = false
                for child in children {
                    switch child.evaluate(record, query: query, cancelled: cancelled) {
                    case .no: return .no
                    case .unknown: unknown = true
                    case .yes(let points): score += points
                    }
                }
                return unknown ? .unknown : .yes(score)
            case .or(let children):
                var best: Int?, unknown = false
                for child in children {
                    switch child.evaluate(record, query: query, cancelled: cancelled) {
                    case .no: break
                    case .unknown: unknown = true
                    case .yes(let score): best = max(best ?? score, score)
                    }
                }
                return best.map(Evaluation.yes) ?? (unknown ? .unknown : .no)
            case .not(let child):
                switch child.evaluate(record, query: query, cancelled: cancelled) {
                case .yes: return .no
                case .no: return .yes(0)
                case .unknown: return .unknown
                }
            case .directory(let value):
                guard let directory = record.isDirectory else { return .unknown }
                return value == directory ? .yes(0) : .no
            case .typed(let value, let term):
                guard let directory = record.isDirectory else { return .unknown }
                guard value == directory else { return .no }
                return scored(term.score(query.matchPath ? record.path : record.name, query: query))
            case .size(let condition):
                if record.isDirectory == true { return .no }
                guard let size = record.size else { return .unknown }
                return condition.matches(size) ? .yes(0) : .no
            case .date(let condition):
                guard let date = record.modified else { return .unknown }
                return condition.matches(date.seconds) ? .yes(0) : .no
            case .extensions(let values):
                guard record.isDirectory != true, let dot = record.name.lastIndex(of: "."), dot != record.name.startIndex else { return .no }
                return values.contains(query.catalogFold(String(record.name[record.name.index(after: dot)...]))) ? .yes(0) : .no
            case .text(let term, let scope):
                switch scope {
                case .automatic: return scored(term.score(query.matchPath ? record.path : record.name, query: query))
                case .name: return scored(term.score(record.name, query: query))
                case .path: return scored(term.score(record.path, query: query))
                case .parent:
                    if !term.wildcard { return query.catalogFold(record.parentPath).utf8.elementsEqual(term.pattern.utf8) ? .yes(0) : .no }
                    return scored(term.score(record.parentPath, query: query))
                }
            case .regex(let regex):
                let text = query.matchPath ? record.path : record.name
                var found = false
                regex.enumerateMatches(in: text, options: [.reportProgress], range: NSRange(text.startIndex..., in: text)) { result, _, stop in
                    if cancelled() { stop.pointee = true }
                    if result != nil { found = true; stop.pointee = true }
                }
                return found && !cancelled() ? .yes(0) : .no
            }
        }
    }
    struct Text: Sendable {
        let pattern: String
        let wildcard: Bool
        let fuzzy: Bool
        init(_ token: Query.Token, query: Query) {
            pattern = query.catalogFold(token.text, preservingWildcards: true)
            wildcard = token.text.contains("*") || token.text.contains("?")
            fuzzy = query.fuzzy && !query.wholeWord && !query.matchPrefix && !query.matchSuffix && !token.isLiteral
        }
        func score(_ input: String, query: Query) -> Int? {
            let text = query.catalogFold(input)
            if wildcard { return Glob.matches(pattern: pattern, in: text, caseInsensitive: false) ? 0 : nil }
            if query.matchPrefix || query.matchSuffix {
                let scalars = Array(text.unicodeScalars), needle = Array(pattern.unicodeScalars)
                if query.matchPrefix && !scalars.starts(with: needle) { return nil }
                if query.matchSuffix && !scalars.reversed().starts(with: needle.reversed()) { return nil }
                if query.wholeWord {
                    if query.matchPrefix && scalars.count > needle.count && CharacterSet.alphanumerics.contains(scalars[needle.count]) { return nil }
                    if query.matchSuffix && scalars.count > needle.count && CharacterSet.alphanumerics.contains(scalars[scalars.count - needle.count - 1]) { return nil }
                }
                return 0
            }
            if query.wholeWord { return Glob.containsWholeWord(pattern, in: text, caseInsensitive: false) ? 0 : nil }
            if fuzzy { return FuzzyMatcher.unicodeScore(text, pattern, ci: false) }
            return Glob.matches(pattern: pattern, in: text, caseInsensitive: false) ? 0 : nil
        }
    }
}

private extension Query {
    func catalogFold(_ input: String, preservingWildcards: Bool = false) -> String {
        var text = diacriticInsensitive ? input.folding(options: [.diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX")) : input
        if caseInsensitive { text = text.lowercased() }
        if ignorePunctuation || ignoreWhitespace {
            text = String(String.UnicodeScalarView(text.unicodeScalars.filter {
                !(ignorePunctuation && CharacterSet.punctuationCharacters.contains($0)
                    && !(preservingWildcards && ($0 == "*" || $0 == "?")))
                    && !(ignoreWhitespace && CharacterSet.whitespacesAndNewlines.contains($0))
            }))
        }
        return text
    }
}
