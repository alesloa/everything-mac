// Reusing candidates is valid only when every new match also matched the old
// query. Keep this separate from ranking: scores always change with the query.
extension Query {
    func narrows(_ previous: Query) -> Bool {
        guard matchPath == previous.matchPath,
              caseInsensitive == previous.caseInsensitive,
              wholeWord == previous.wholeWord, fuzzy == previous.fuzzy else { return false }
        let old = previous.tokens, new = tokens
        guard !old.isEmpty, old.count == new.count else { return false }
        return zip(new, old).allSatisfy { term, prior in
            guard term.quoted == prior.quoted else { return false }
            if term.text == prior.text { return true }
            // A longer whole word need not match its shorter predecessor.
            // Arbitrary glob edits can widen an anchored pattern as well.
            guard !wholeWord, !term.text.contains("*"), !term.text.contains("?"),
                  !prior.text.contains("*"), !prior.text.contains("?") else { return false }
            let oldASCII = prior.text.utf8.allSatisfy { $0 < 128 }
            let newASCII = term.text.utf8.allSatisfy { $0 < 128 }
            // Switching from byte matching to Unicode folding/grapheme matching
            // can admit names the byte matcher rejected (for example Kelvin sign).
            guard oldASCII == newASCII else { return false }
            if fuzzy && !term.isLiteral {
                if oldASCII {
                    let a = FuzzyMatcher.Pattern(term.text, caseInsensitive: caseInsensitive)
                    let b = FuzzyMatcher.Pattern(prior.text, caseInsensitive: caseInsensitive)
                    // At five bytes typo correction first admits new names. At
                    // 129 bytes it turns off. Reset at both eligibility changes.
                    guard a.takesTypos == b.takesTypos else { return false }
                    // A one-edit prefix of the longer token has a prefix within
                    // one edit of the shorter token. A transposition crossing the
                    // old end is a substitution at that end; unchanged first
                    // letters and digit restrictions therefore remain valid.
                    return a.bytes.starts(with: b.bytes)
                }
                let a = caseInsensitive ? term.text.lowercased() : term.text
                let b = caseInsensitive ? prior.text.lowercased() : prior.text
                return Array(a).starts(with: Array(b))
            }
            let a = caseInsensitive ? term.text.lowercased() : term.text
            let b = caseInsensitive ? prior.text.lowercased() : prior.text
            // Literal substring matching compares scalars, unlike the Unicode
            // fuzzy matcher, which compares extended grapheme clusters.
            return a.unicodeScalars.starts(with: b.unicodeScalars)
        }
    }
}
