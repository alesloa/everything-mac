import Foundation

// Swift adaptation of fsearch's fzf-style subsequence ranking and one-edit
// prefix matching. Copyright (c) 2026 Noah Dunnagan, MIT; see
// App/Resources/fsearch-LICENSE.txt and THIRD_PARTY_NOTICES.md.
enum FuzzyMatcher {
    @inline(__always) static func fold(_ b: UInt8) -> UInt8 {
        b >= 65 && b <= 90 ? b + 32 : b
    }

    // Hash collisions only admit extra candidates; they never reject a match.
    @inline(__always) static func bit(_ b: UInt8) -> UInt64 { 1 << (fold(b) & 63) }
    static func mask<C: Collection>(_ bytes: C) -> UInt64 where C.Element == UInt8 {
        bytes.reduce(0) { $0 | bit($1) }
    }

    struct Pattern: Sendable {
        let bytes: [UInt8]
        let mask: UInt64
        let caseInsensitive: Bool
        let takesTypos: Bool

        init(_ text: String, caseInsensitive: Bool) {
            let raw = Array(text.utf8)
            self.caseInsensitive = caseInsensitive
            bytes = caseInsensitive ? raw.map(FuzzyMatcher.fold) : raw
            mask = FuzzyMatcher.mask(raw)
            takesTypos = caseInsensitive && raw.count >= 5 && raw.count <= 128
                && raw.contains { (65...90).contains($0) || (97...122).contains($0) }
        }

        @inline(__always) func fits(_ nameMask: UInt64) -> Bool {
            let missing = mask & ~nameMask
            return missing == 0 || (takesTypos && missing.nonzeroBitCount <= 1
                && nameMask & FuzzyMatcher.bit(bytes[0]) != 0)
        }

        func score<Bytes: RandomAccessCollection>(_ name: Bytes, nameMask: UInt64,
                                                 matchPath: Bool = false) -> Int?
            where Bytes.Element == UInt8, Bytes.Index == Int {
            let missing = mask & ~nameMask
            let clean = missing == 0 ? FuzzyMatcher.score(name, bytes, ci: caseInsensitive) : nil
            guard takesTypos, missing.nonzeroBitCount <= 1,
                  nameMask & FuzzyMatcher.bit(bytes[0]) != 0 else { return clean }
            // A typo must retain the first letter and occur at a word's prefix.
            // Digits are never edited: distinct numbered files stay distinct.
            var best = clean
            var start = name.startIndex
            if name.count > 1 && name[start] == 46 && bytes[0] != 46 { start += 1 }
            while start < name.endIndex {
                if FuzzyMatcher.fold(name[start]) == bytes[0],
                   let length = FuzzyMatcher.oneEditPrefix(name[start...], bytes) {
                    let fixed = name[start..<(start + length)].map(FuzzyMatcher.fold)
                    if let s = FuzzyMatcher.score(name, fixed, ci: true, cap: 30) {
                        best = max(best ?? Int.min, s - 40)
                    }
                }
                if matchPath {
                    // Full-path matching includes filename and directory prefixes.
                    // Adding the parent path must not remove filename typo hits.
                    guard let separator = name[start...].firstIndex(where: { $0 == 32 || $0 == 47 }) else { break }
                    start = separator + 1
                    if start + 1 < name.endIndex && name[start] == 46 && bytes[0] != 46 { start += 1 }
                } else {
                    if nameMask & FuzzyMatcher.bit(32) == 0 { break }
                    guard let space = name[start...].firstIndex(of: 32) else { break }
                    start = space + 1
                }
            }
            return best
        }
    }

    private enum Class { case lower, upper, digit, delimiter, other }
    @inline(__always) private static func classify(_ b: UInt8) -> Class {
        switch b {
        case 97...122: return .lower
        case 65...90: return .upper
        case 48...57: return .digit
        case 32, 95, 45, 46, 47, 40, 41, 91, 93, 44, 43, 64: return .delimiter
        default: return .other
        }
    }
    @inline(__always) private static func bonus(_ prev: Class, _ cur: Class) -> Int {
        if prev == .delimiter && cur != .delimiter { return 8 }
        if prev == .lower && cur == .upper { return 7 }
        if (prev == .lower || prev == .upper) && cur == .digit { return 7 }
        return 0
    }

    // Leftmost-ending subsequence, shrunk from the right, with word-boundary,
    // camel-case and consecutive-letter bonuses. No allocation per candidate.
    private static func score<Bytes: RandomAccessCollection>(_ name: Bytes, _ q: [UInt8], ci: Bool, cap: Int = 100) -> Int?
        where Bytes.Element == UInt8, Bytes.Index == Int {
        guard !q.isEmpty, q.count <= name.count else { return nil }
        func equal(_ b: UInt8, _ c: UInt8) -> Bool { (ci ? fold(b) : b) == c }
        var cursor = name.startIndex
        for c in q {
            while cursor < name.endIndex && !equal(name[cursor], c) { cursor += 1 }
            guard cursor < name.endIndex else { return nil }
            cursor += 1
        }
        let end = cursor - 1
        var start = cursor
        for c in q.reversed() {
            repeat { start -= 1 } while !equal(name[start], c)
        }
        var at = start
        var firstBonus = 0
        var result = 0
        for k in q.indices {
            var consecutive = false
            if k > 0 {
                let last = at
                at += 1
                while !equal(name[at], q[k]) { at += 1 }
                consecutive = at == last + 1
                if !consecutive { result -= 3 + at - last - 2 }
            }
            let previous: Class = at == name.startIndex ? .delimiter : classify(name[at - 1])
            var b = bonus(previous, classify(name[at]))
            if consecutive {
                if b >= 8 && b > firstBonus { firstBonus = b }
                b = max(b, firstBonus, 4)
            } else { firstBonus = b }
            result += 16 + (k == 0 ? b * 2 : b)
        }
        let offset = name.startIndex + (name.count > 1 && name.first == 46 ? 1 : 0)
        if start == offset && end + 1 - start == q.count {
            let stem = name.lastIndex(of: 46).flatMap { $0 > offset ? $0 : nil } ?? name.endIndex
            let placed = end + 1 == name.endIndex ? 100 : (end + 1 == stem ? 80 : 30)
            result += min(placed, cap)
        }
        return result - min(name.count, 80) / 3
    }

    // Exactly one substitution, insertion, deletion or adjacent transposition.
    private static func oneEditPrefix<Bytes: RandomAccessCollection>(_ word: Bytes, _ q: [UInt8]) -> Int?
        where Bytes.Element == UInt8, Bytes.Index == Int {
        let w = word.startIndex
        var i = 0
        while i < q.count && i < word.count && fold(word[w + i]) == q[i] { i += 1 }
        guard i < q.count else { return nil }
        func digit(_ b: UInt8) -> Bool { (48...57).contains(b) }
        guard !digit(q[i]), i >= word.count || !digit(word[w + i]) else { return nil }
        func starts(_ wi: Int, _ qi: Int) -> Bool {
            guard wi <= word.count, word.count - wi >= q.count - qi else { return false }
            for k in qi..<q.count where fold(word[w + wi + k - qi]) != q[k] { return false }
            return true
        }
        if i + 1 < q.count && i + 1 < word.count,
           !digit(q[i + 1]), !digit(word[w + i + 1]),
           fold(word[w + i]) == q[i + 1], fold(word[w + i + 1]) == q[i], starts(i + 2, i + 2) { return q.count }
        if i < word.count && starts(i + 1, i + 1) { return q.count }
        if starts(i, i + 1) { return q.count - 1 }
        if i < word.count && starts(i + 1, i) { return q.count + 1 }
        return nil
    }

    static func unicodeScore(_ name: String, _ term: String, ci: Bool) -> Int? {
        let candidate = ci ? name.lowercased() : name
        let pattern = ci ? term.lowercased() : term
        var remaining = pattern[...]
        var gaps = 0
        for ch in candidate {
            if ch == remaining.first {
                remaining.removeFirst()
                if remaining.isEmpty {
                    let placement = candidate == pattern ? 100 : (candidate.hasPrefix(pattern) ? 30 : 0)
                    return pattern.count * 16 + placement - gaps
                }
            } else { gaps += 1 }
        }
        return nil
    }
}
