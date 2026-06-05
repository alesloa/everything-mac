public struct Query: Sendable {
    public var text: String
    public var matchPath: Bool
    public var caseInsensitive: Bool

    public init(text: String, matchPath: Bool = false, caseInsensitive: Bool = true) {
        self.text = text
        self.matchPath = matchPath
        self.caseInsensitive = caseInsensitive
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
