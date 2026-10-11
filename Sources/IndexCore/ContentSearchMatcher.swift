import Foundation

/// KMP over canonically normalized/folded scalars handles matches spanning read
/// chunks. A final grapheme is held until the next chunk so decomposed accents
/// and multiscalar emoji are never split before folding. Oversize graphemes fail
/// closed; all carry, excerpts and needle storage have explicit bounds.
struct ContentSearchMatcher {
    private let needle: [Unicode.Scalar]
    private let prefix: [Int]
    private let folding: String.CompareOptions
    private var matched = 0
    private var carry = ""
    private var tail = [String](repeating: "", count: 160)
    private var tailPosition = 0
    private var tailCount = 0
    private var tailBytes = 0
    private var excerptFollowing = 0
    private var hasExcerpt = false
    private(set) var occurrenceCount = 0
    private(set) var excerpt = ""
    private(set) var valid = true
    private static let locale = Locale(identifier: "en_US_POSIX")

    init(literal: String, options: ContentSearchOptions) {
        var fold: String.CompareOptions = []
        if options.caseInsensitive { fold.insert(.caseInsensitive) }
        if options.diacriticInsensitive { fold.insert(.diacriticInsensitive) }
        folding = fold
        needle = Array(literal.folding(options: fold, locale: Self.locale)
            .precomposedStringWithCanonicalMapping.unicodeScalars)
        var table = [Int](repeating: 0, count: needle.count)
        if needle.count > 1 {
            var length = 0
            for position in 1..<needle.count {
                while length > 0 && needle[position] != needle[length] { length = table[length - 1] }
                if needle[position] == needle[length] { length += 1 }
                table[position] = length
            }
        }
        prefix = table
        valid = !needle.isEmpty && needle.count <= 8_192
    }

    mutating func append(_ text: String, final: Bool = false, isCancelled: () -> Bool) {
        guard valid, !isCancelled() else { return }
        carry += text
        let end = final || carry.isEmpty ? carry.endIndex : carry.index(before: carry.endIndex)
        var index = carry.startIndex, iterations = 0
        while index < end {
            if iterations & 511 == 0 && isCancelled() { return }
            iterations += 1
            let next = carry.index(after: index)
            let character = String(carry[index..<next])
            // Prevent a malicious unbroken combining sequence from defeating
            // the chunk/overlap bound. It is skipped, never a partial text hit.
            guard character.utf8.count <= 8_192 else { valid = false; return }
            consume(character)
            index = next
        }
        carry = String(carry[index...])
        if carry.utf8.count > 8_192 { valid = false }
    }

    mutating func finishSegment(isCancelled: () -> Bool) {
        append("", final: true, isCancelled: isCancelled)
        matched = 0; excerptFollowing = 0
        tailCount = 0; tailBytes = 0
    }

    private mutating func consume(_ character: String) {
        if tailCount == tail.count { tailBytes -= tail[tailPosition].utf8.count }
        tail[tailPosition] = character
        tailBytes += character.utf8.count
        tailPosition = (tailPosition + 1) % tail.count
        tailCount = min(tail.count, tailCount + 1)
        while tailBytes > 512 && tailCount > 0 {
            let oldest = (tailPosition - tailCount + tail.count) % tail.count
            tailBytes -= tail[oldest].utf8.count; tailCount -= 1
            tail[oldest] = ""
        }
        if excerptFollowing > 0 {
            if excerpt.utf8.count + character.utf8.count <= 1_024 {
                excerpt += character; excerptFollowing -= 1
            } else { excerptFollowing = 0 }
        }
        let folded = character.folding(options: folding, locale: Self.locale)
            .precomposedStringWithCanonicalMapping
        for scalar in folded.unicodeScalars {
            while matched > 0 && scalar != needle[matched] { matched = prefix[matched - 1] }
            if scalar == needle[matched] { matched += 1 }
            if matched == needle.count {
                occurrenceCount += 1
                if !hasExcerpt {
                    hasExcerpt = true
                    let start = (tailPosition - tailCount + tail.count) % tail.count
                    excerpt = (0..<tailCount).map { tail[(start + $0) % tail.count] }.joined()
                    excerptFollowing = 160
                }
                // Count nonoverlapping normalized literal occurrences.
                matched = 0
            }
        }
    }
}

/// Strict decoding rejects binary/malformed data rather than manufacturing
/// replacement characters. UTF-16 is supported with a byte-order mark;
/// unmarked text is UTF-8. Byte carry is at most 3 bytes plus a UTF-16 surrogate.
struct ContentSearchDecoder {
    private enum Encoding { case utf8, utf16LE, utf16BE }
    private var encoding: Encoding?
    private var pending: [UInt8] = []

    mutating func decode(_ data: [UInt8], final: Bool = false) -> String? {
        pending += data
        if encoding == nil {
            if pending.count < 3 && !final { return "" }
            if pending.starts(with: [0xff, 0xfe]) { encoding = .utf16LE; pending.removeFirst(2) }
            else if pending.starts(with: [0xfe, 0xff]) { encoding = .utf16BE; pending.removeFirst(2) }
            else {
                encoding = .utf8
                if pending.starts(with: [0xef, 0xbb, 0xbf]) { pending.removeFirst(3) }
            }
        }
        guard let encoding else { return nil }
        var output = String.UnicodeScalarView(), position = 0
        decodeLoop: while position < pending.count {
            let value: UInt32
            let length: Int
            switch encoding {
            case .utf8:
                let first = pending[position]
                if first < 0x80 { value = UInt32(first); length = 1 }
                else {
                    let count = first >= 0xc2 && first <= 0xdf ? 2 : first >= 0xe0 && first <= 0xef ? 3
                        : first >= 0xf0 && first <= 0xf4 ? 4 : 0
                    guard count > 0 else { return nil }
                    if position + count > pending.count { break decodeLoop }
                    var scalar = UInt32(first & (0x7f >> count))
                    for offset in 1..<count {
                        let byte = pending[position + offset]
                        guard byte & 0xc0 == 0x80 else { return nil }
                        scalar = scalar << 6 | UInt32(byte & 0x3f)
                    }
                    guard scalar >= (count == 2 ? 0x80 : count == 3 ? 0x800 : 0x10000),
                          scalar <= 0x10ffff, !(0xd800...0xdfff).contains(scalar) else { return nil }
                    value = scalar; length = count
                }
            case .utf16LE, .utf16BE:
                if position + 2 > pending.count { break decodeLoop }
                func unit(_ offset: Int) -> UInt32 {
                    let a = UInt32(pending[offset]), b = UInt32(pending[offset + 1])
                    return encoding == .utf16LE ? a | b << 8 : a << 8 | b
                }
                let first = unit(position)
                if (0xd800...0xdbff).contains(first) {
                    if position + 4 > pending.count { break decodeLoop }
                    let second = unit(position + 2)
                    guard (0xdc00...0xdfff).contains(second) else { return nil }
                    value = 0x10000 + ((first - 0xd800) << 10) + second - 0xdc00; length = 4
                } else {
                    guard !(0xdc00...0xdfff).contains(first) else { return nil }
                    value = first; length = 2
                }
            }
            // Reject NUL and binary controls; preserve actual tab/newline text.
            guard value != 0, value >= 32 || value == 9 || value == 10 || value == 13,
                  let scalar = Unicode.Scalar(value) else { return nil }
            output.append(scalar); position += length
        }
        pending.removeFirst(position)
        guard !final || pending.isEmpty else { return nil }
        return String(output)
    }
}
