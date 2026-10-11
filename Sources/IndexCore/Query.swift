public struct Query: Sendable, Equatable {
    public var text: String
    public var matchPath: Bool
    public var caseInsensitive: Bool
    // When true, each plain (non-wildcard) term must match as a whole word — bounded by
    // a non-alphanumeric character or a string edge — rather than as a loose substring.
    public var wholeWord: Bool
    public var fuzzy: Bool

    public init(text: String, matchPath: Bool = false, caseInsensitive: Bool = true,
                wholeWord: Bool = false, fuzzy: Bool = false) {
        self.text = text
        self.matchPath = matchPath
        self.caseInsensitive = caseInsensitive
        self.wholeWord = wholeWord
        self.fuzzy = fuzzy
    }

    public static func == (lhs: Query, rhs: Query) -> Bool {
        // Literal/glob matching compares Unicode scalars. Swift String equality
        // normalizes equivalent spellings, which would reuse the wrong matches.
        lhs.text.utf8.elementsEqual(rhs.text.utf8)
            && lhs.matchPath == rhs.matchPath && lhs.caseInsensitive == rhs.caseInsensitive
            && lhs.wholeWord == rhs.wholeWord && lhs.fuzzy == rhs.fuzzy
    }

    // Whitespace-separated terms; quoted phrases kept intact.
    public var terms: [String] { tokens.map(\.text) }

    struct Token: Sendable {
        let text: String
        let quoted: Bool
        var isLiteral: Bool { quoted || text.contains("*") || text.contains("?") }
    }

    var hasFuzzyTerms: Bool { fuzzy && !wholeWord && tokens.contains { !$0.isLiteral } }

    var tokens: [Token] {
        var out: [Token] = []
        var cur = ""
        var inQuote = false
        var quoted = false
        for ch in text {
            if ch == "\"" { inQuote.toggle(); quoted = true; continue }
            if ch == " " && !inQuote {
                if !cur.isEmpty { out.append(Token(text: cur, quoted: quoted)); cur = "" }
                quoted = false
            } else {
                cur.append(ch)
            }
        }
        if !cur.isEmpty { out.append(Token(text: cur, quoted: quoted)) }
        return out
    }
}
