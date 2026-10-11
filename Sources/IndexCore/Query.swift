import Foundation

public struct Query: Sendable, Equatable {
    public var text: String { didSet { rebuildPlan() } }
    public var matchPath: Bool
    public var caseInsensitive: Bool
    public var wholeWord: Bool
    public var fuzzy: Bool
    public var regex: Bool { didSet { rebuildPlan() } }
    public var diacriticInsensitive: Bool
    public var matchPrefix: Bool
    public var matchSuffix: Bool
    public var ignorePunctuation: Bool
    public var ignoreWhitespace: Bool
    private let referenceDate: Date?
    var plan: ParsedQuery

    public init(text: String, matchPath: Bool = false, caseInsensitive: Bool = true,
                wholeWord: Bool = false, fuzzy: Bool = false, regex: Bool = false,
                diacriticInsensitive: Bool = false, matchPrefix: Bool = false,
                matchSuffix: Bool = false, ignorePunctuation: Bool = false,
                ignoreWhitespace: Bool = false, referenceDate: Date? = nil) {
        self.text = text; self.matchPath = matchPath; self.caseInsensitive = caseInsensitive
        self.wholeWord = wholeWord; self.fuzzy = fuzzy; self.regex = regex
        self.diacriticInsensitive = diacriticInsensitive; self.matchPrefix = matchPrefix
        self.matchSuffix = matchSuffix; self.ignorePunctuation = ignorePunctuation
        self.ignoreWhitespace = ignoreWhitespace; self.referenceDate = referenceDate
        plan = QuerySyntax.parse(text, regex: regex, referenceDate: referenceDate ?? Date())
    }

    private mutating func rebuildPlan() {
        plan = QuerySyntax.parse(text, regex: regex, referenceDate: referenceDate ?? Date())
    }

    // The error text comes from this parser's validation, including Foundation's
    // actual regular-expression compile error when a regex cannot be compiled.
    public var validationError: QueryValidationError? { plan.error }
    public var terms: [String] { tokens.map(\.text) }
    struct Token: Sendable {
        let text: String
        let quoted: Bool
        var isLiteral: Bool { quoted || text.contains("*") || text.contains("?") }
    }
    var tokens: [Token] { plan.tokens }
    var usesAdvancedEngine: Bool {
        plan.advanced || regex || diacriticInsensitive || matchPrefix || matchSuffix
            || ignorePunctuation || ignoreWhitespace || validationError != nil
    }
    var hasFuzzyTerms: Bool {
        fuzzy && !wholeWord && !regex && !matchPrefix && !matchSuffix && plan.hasPlainTerms
    }

    func refreshingRelativeDates() -> Query {
        guard referenceDate == nil, plan.relativeDates,
              plan.dayAnchor != Calendar.current.startOfDay(for: Date()).timeIntervalSince1970 else { return self }
        var updated = self
        updated.rebuildPlan()
        return updated
    }

    public static func == (lhs: Query, rhs: Query) -> Bool {
        // Preserve scalar spellings used by literal matching, and expire relative
        // date queries when their calendar-day anchor changes.
        lhs.text.utf8.elementsEqual(rhs.text.utf8)
            && lhs.matchPath == rhs.matchPath && lhs.caseInsensitive == rhs.caseInsensitive
            && lhs.wholeWord == rhs.wholeWord && lhs.fuzzy == rhs.fuzzy && lhs.regex == rhs.regex
            && lhs.diacriticInsensitive == rhs.diacriticInsensitive
            && lhs.matchPrefix == rhs.matchPrefix && lhs.matchSuffix == rhs.matchSuffix
            && lhs.ignorePunctuation == rhs.ignorePunctuation && lhs.ignoreWhitespace == rhs.ignoreWhitespace
            && (!lhs.plan.relativeDates && !rhs.plan.relativeDates || lhs.plan.dayAnchor == rhs.plan.dayAnchor)
    }
}
