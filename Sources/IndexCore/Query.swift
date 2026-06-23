public struct Query: Sendable {
    public var text: String
    public var matchPath: Bool
    public var caseInsensitive: Bool
    // When true, each plain (non-wildcard) term must match as a whole word — bounded by
    // a non-alphanumeric character or a string edge — rather than as a loose substring.
    public var wholeWord: Bool

    public init(text: String, matchPath: Bool = false, caseInsensitive: Bool = true,
                wholeWord: Bool = false) {
        self.text = text
        self.matchPath = matchPath
        self.caseInsensitive = caseInsensitive
        self.wholeWord = wholeWord
    }

    // Whitespace-separated terms; quoted phrases kept intact.
    public var terms: [String] {
        var out: [String] = []
        var cur = ""
        var inQuote = false
        for ch in text {
            if ch == "\"" { inQuote.toggle(); continue }
            if ch == " " && !inQuote {
                if !cur.isEmpty { out.append(cur); cur = "" }
            } else {
                cur.append(ch)
            }
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }
}
