import Foundation

public struct RecordHighlights: Sendable, Equatable {
    public var name: [NSRange] = []
    public var path: [NSRange] = []
    public init() {}
}

// Highlight ranges come from the parsed current query and the indexed row text.
// This helper is intended for a cancellable background presentation worker.
public struct QueryHighlighter: Sendable {
    private let query: Query
    private let regexes: [String: NSRegularExpression]

    public init(query: Query) {
        self.query = query.refreshingRelativeDates()
        var compiled: [String: NSRegularExpression] = [:]
        func visit(_ expression: QueryExpression) {
            switch expression {
            case .predicate(.regex(let pattern)):
                compiled[pattern] = try? NSRegularExpression(pattern: pattern,
                    options: query.caseInsensitive ? [.caseInsensitive] : [])
            case .and(let children), .or(let children): children.forEach(visit)
            case .not(let child): visit(child)
            default: break
            }
        }
        visit(self.query.plan.expression)
        regexes = compiled
    }

    public func highlights(for record: FileRecord,
                           isCancelled: @Sendable () -> Bool = { false }) -> RecordHighlights {
        guard query.validationError == nil, !isCancelled() else { return RecordHighlights() }
        let result = evaluate(query.plan.expression, record: record, isCancelled: isCancelled)
        guard result.matches, !isCancelled() else { return RecordHighlights() }
        return result.ranges
    }

    private struct Evaluation {
        var matches: Bool
        var ranges = RecordHighlights()
        mutating func append(_ other: Evaluation) {
            ranges.name += other.ranges.name
            ranges.path += other.ranges.path
        }
    }

    private func evaluate(_ expression: QueryExpression, record: FileRecord,
                          isCancelled: @Sendable () -> Bool) -> Evaluation {
        guard !isCancelled() else { return Evaluation(matches: false) }
        switch expression {
        case .and(let children):
            var result = Evaluation(matches: true)
            for child in children {
                let match = evaluate(child, record: record, isCancelled: isCancelled)
                guard match.matches else { return Evaluation(matches: false) }
                result.append(match)
            }
            return result
        case .or(let children):
            var result = Evaluation(matches: false)
            for child in children {
                let match = evaluate(child, record: record, isCancelled: isCancelled)
                if match.matches { result.matches = true; result.append(match) }
            }
            return result
        case .not(let child):
            return Evaluation(matches: !evaluate(child, record: record, isCancelled: isCancelled).matches)
        case .predicate(let predicate):
            switch predicate {
            case .directory(let expected): return Evaluation(matches: record.isDir == expected)
            case .size(let condition): return Evaluation(matches: !record.isDir && condition.matches(record.size))
            case .date(let condition): return Evaluation(matches: condition.matches(record.mtime))
            case .typedText(let directory, let term):
                guard record.isDir == directory else { return Evaluation(matches: false) }
                return text(term, scope: .automatic, record: record)
            case .text(let term, let scope): return text(term, scope: scope, record: record)
            case .extensionList(let values):
                guard !record.isDir, let dot = record.name.lastIndex(of: "."), dot != record.name.startIndex,
                      values.contains(where: { query.fold($0).utf8.elementsEqual(query.fold(String(record.name[record.name.index(after: dot)...])).utf8) }) else {
                    return Evaluation(matches: false)
                }
                var result = Evaluation(matches: true)
                let suffix = record.name[record.name.index(after: dot)...]
                let length = suffix.utf16.count
                result.ranges.name = [NSRange(location: record.name.utf16.count - length, length: length)]
                result.ranges.path = [NSRange(location: record.path.utf16.count - length, length: length)]
                return result
            case .regex(let pattern):
                guard let regex = regexes[pattern] else { return Evaluation(matches: false) }
                let value = query.matchPath ? record.path : record.name
                var ranges: [NSRange] = []
                regex.enumerateMatches(in: value, options: [.reportProgress], range: NSRange(location: 0, length: value.utf16.count)) { match, _, stop in
                    if isCancelled() { stop.pointee = true }
                    if let match { ranges.append(match.range) }
                }
                var result = Evaluation(matches: !ranges.isEmpty && !isCancelled())
                if query.matchPath { result.ranges.path = ranges } else { result.ranges.name = ranges }
                return result
            }
        }
    }

    private func text(_ token: Query.Token, scope: QueryTextScope, record: FileRecord) -> Evaluation {
        if scope == .parent && record.parent == FileStore.noParent { return Evaluation(matches: false) }
        let path = scope == .path || scope == .parent || scope == .automatic && query.matchPath
        let value = scope == .parent ? (record.path as NSString).deletingLastPathComponent : path ? record.path : record.name
        let parentExact = scope == .parent && !token.text.contains("*") && !token.text.contains("?")
        let match: (Bool, [NSRange])
        if parentExact {
            match = (query.fold(value).utf8.elementsEqual(query.fold(token.text, preservingWildcards: true).utf8),
                     [NSRange(location: 0, length: value.utf16.count)])
        } else { match = textRanges(token, value: value) }
        var result = Evaluation(matches: match.0)
        if match.0 {
            if path { result.ranges.path = match.1 } else { result.ranges.name = match.1 }
        }
        return result
    }

    private func textRanges(_ token: Query.Token, value: String) -> (Bool, [NSRange]) {
        let pattern = query.fold(token.text, preservingWildcards: true)
        let needle = Array(pattern.unicodeScalars)
        if needle.isEmpty { return (true, []) }
        let normalized = NormalizedText(value, query: query)
        let scalars = normalized.scalars
        if token.text.contains("*") || token.text.contains("?") {
            let matched = Glob.matches(pattern: pattern, in: query.fold(value), caseInsensitive: false)
            return (matched, matched ? [NSRange(location: 0, length: value.utf16.count)] : [])
        }
        if query.fuzzy && !query.wholeWord && !query.matchPrefix && !query.matchSuffix && !token.isLiteral {
            var indexes: [Int] = [], next = 0
            for index in scalars.indices where next < needle.count {
                if scalars[index] == needle[next] { indexes.append(index); next += 1 }
            }
            guard next == needle.count else { return (false, []) }
            return (true, indexes.map { normalized.original[$0] })
        }
        guard needle.count <= scalars.count else { return (false, []) }
        let words = CharacterSet.alphanumerics
        func valid(_ offset: Int) -> Bool {
            for index in needle.indices where needle[index] != scalars[offset + index] { return false }
            if query.wholeWord {
                if offset > 0 && words.contains(scalars[offset - 1]) { return false }
                if offset + needle.count < scalars.count && words.contains(scalars[offset + needle.count]) { return false }
            }
            return true
        }
        if query.matchPrefix && !valid(0) { return (false, []) }
        if query.matchSuffix && !valid(scalars.count - needle.count) { return (false, []) }
        var ranges: [NSRange] = []
        for offset in 0...(scalars.count - needle.count) {
            if query.matchPrefix || query.matchSuffix {
                guard query.matchPrefix && offset == 0 || query.matchSuffix && offset == scalars.count - needle.count else { continue }
            }
            if valid(offset) {
                let first = normalized.original[offset], last = normalized.original[offset + needle.count - 1]
                ranges.append(NSRange(location: first.location, length: NSMaxRange(last) - first.location))
            }
        }
        return (!ranges.isEmpty, ranges)
    }

    private struct NormalizedText {
        var scalars: [Unicode.Scalar] = []
        var original: [NSRange] = []
        init(_ input: String, query: Query) {
            var offset = 0
            for character in input {
                let value = String(character), length = value.utf16.count
                for scalar in query.fold(value).unicodeScalars {
                    scalars.append(scalar)
                    original.append(NSRange(location: offset, length: length))
                }
                offset += length
            }
        }
    }
}
