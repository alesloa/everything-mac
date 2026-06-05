// Everything semantics: a term with no `*`/`?` is a substring match; a term that
// contains a wildcard is anchored full-string glob matching.
public enum Glob {
    public static func matches(pattern: String, in text: String, caseInsensitive: Bool) -> Bool {
        let p = caseInsensitive ? pattern.lowercased() : pattern
        let t = caseInsensitive ? text.lowercased() : text
        let pa = Array(p.unicodeScalars)
        let ta = Array(t.unicodeScalars)
        if !pa.contains("*") && !pa.contains("?") {
            return contains(haystack: ta, needle: pa)
        }
        return globMatch(pattern: pa, text: ta)
    }

    private static func contains(haystack: [Unicode.Scalar], needle: [Unicode.Scalar]) -> Bool {
        if needle.isEmpty { return true }
        if needle.count > haystack.count { return false }
        let last = haystack.count - needle.count
        var i = 0
        while i <= last {
            var k = 0
            while k < needle.count && haystack[i + k] == needle[k] { k += 1 }
            if k == needle.count { return true }
            i += 1
        }
        return false
    }

    // Iterative glob with backtracking. `*` = zero+ scalars, `?` = exactly one.
    private static func globMatch(pattern: [Unicode.Scalar], text: [Unicode.Scalar]) -> Bool {
        var p = 0, t = 0
        var star = -1, mark = 0
        while t < text.count {
            if p < pattern.count && (pattern[p] == "?" || pattern[p] == text[t]) {
                p += 1; t += 1
            } else if p < pattern.count && pattern[p] == "*" {
                star = p; mark = t; p += 1
            } else if star != -1 {
                p = star + 1; mark += 1; t = mark
            } else {
                return false
            }
        }
        while p < pattern.count && pattern[p] == "*" { p += 1 }
        return p == pattern.count
    }
}

// MARK: - ASCII byte fast path

public extension Glob {
    /// Returns nil if `s` contains any non-ASCII scalar; otherwise returns the
    /// lowercased ASCII bytes of `s`.
    static func asciiLowerBytes(_ s: String) -> [UInt8]? {
        var out: [UInt8] = []
        out.reserveCapacity(s.utf8.count)
        for byte in s.utf8 {
            guard byte < 0x80 else { return nil }
            out.append(byte >= 0x41 && byte <= 0x5A ? byte &+ 0x20 : byte)
        }
        return out
    }

    /// Match `pattern` (already-lowercased ASCII bytes) against `hay` (raw UTF-8 bytes).
    /// Haystack bytes are ASCII-case-folded on the fly; non-ASCII haystack bytes are
    /// compared as-is (an ASCII pattern never matches them, which is correct).
    /// Substring match when pattern has no `*` (0x2A) / `?` (0x3F); else anchored glob.
    static func matchesASCII(patternLowerBytes pattern: [UInt8], in hay: ArraySlice<UInt8>) -> Bool {
        let hasWildcard = pattern.contains(0x2A) || pattern.contains(0x3F)
        if hasWildcard {
            return bytesGlobMatch(pattern: pattern, hay: hay)
        } else {
            return bytesContains(hay: hay, needle: pattern)
        }
    }

    // Fold a single haystack byte: A-Z → a-z, rest as-is.
    @inline(__always)
    private static func fold(_ b: UInt8) -> UInt8 {
        b >= 0x41 && b <= 0x5A ? b &+ 0x20 : b
    }

    private static func bytesContains(hay: ArraySlice<UInt8>, needle: [UInt8]) -> Bool {
        if needle.isEmpty { return true }
        let hc = hay.count
        let nc = needle.count
        if nc > hc { return false }
        let hayBase = hay.startIndex
        let last = hc - nc
        var i = 0
        while i <= last {
            var k = 0
            while k < nc && fold(hay[hayBase + i + k]) == needle[k] { k += 1 }
            if k == nc { return true }
            i += 1
        }
        return false
    }

    private static func bytesGlobMatch(pattern: [UInt8], hay: ArraySlice<UInt8>) -> Bool {
        let pc = pattern.count
        let hc = hay.count
        let hayBase = hay.startIndex
        var p = 0, t = 0
        var star = -1, mark = 0
        while t < hc {
            let hb = fold(hay[hayBase + t])
            if p < pc && (pattern[p] == 0x3F || pattern[p] == hb) {
                p += 1; t += 1
            } else if p < pc && pattern[p] == 0x2A {
                star = p; mark = t; p += 1
            } else if star != -1 {
                p = star + 1; mark += 1; t = mark
            } else {
                return false
            }
        }
        while p < pc && pattern[p] == 0x2A { p += 1 }
        return p == pc
    }
}
