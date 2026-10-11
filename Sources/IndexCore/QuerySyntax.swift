import Foundation

public struct QueryValidationError: Error, LocalizedError, Sendable, Equatable {
    public let message: String
    public var errorDescription: String? { message }
    // Each message is a parser diagnostic for the submitted query, not a support code.
    init(_ message: String) { self.message = message }
}

indirect enum QueryExpression: Sendable {
    case predicate(QueryPredicate)
    case and([QueryExpression])
    case or([QueryExpression])
    case not(QueryExpression)
}

struct ParsedQuery: Sendable {
    var tokens: [Query.Token] = []
    var expression: QueryExpression = .and([])
    var advanced = false
    var hasPlainTerms = false
    var relativeDates = false
    var dayAnchor: TimeInterval = 0
    var error: QueryValidationError?
}

enum QuerySyntax {
    private enum Lexeme: Sendable {
        case term(String, Bool, Bool), and, or, not, open(Character), close(Character)
    }

    static func parse(_ text: String, regex: Bool, referenceDate: Date) -> ParsedQuery {
        var result = ParsedQuery()
        do {
            guard text.utf8.count <= 32_768 else { throw QueryValidationError("The search query exceeds 32,768 bytes.") }
            if regex {
                try validateRegex(text)
                result.expression = .predicate(.regex(text))
                result.advanced = true
                return result
            }
            let lexemes = try lex(text)
            guard lexemes.count <= 512 else { throw QueryValidationError("The search query exceeds 512 terms and operators.") }
            var parser = Parser(lexemes: lexemes, date: referenceDate)
            result.expression = try parser.parse()
            result.advanced = parser.advanced
            result.tokens = parser.tokens
            result.hasPlainTerms = parser.tokens.contains { !$0.isLiteral }
            result.relativeDates = parser.relativeDates
            result.dayAnchor = Calendar.current.startOfDay(for: referenceDate).timeIntervalSince1970
        } catch let error as QueryValidationError {
            result.error = error
        } catch {
            result.error = QueryValidationError(error.localizedDescription)
        }
        return result
    }

    static func validateRegex(_ pattern: String) throws {
        guard pattern.utf8.count <= 4096 else { throw QueryValidationError("The regular expression exceeds 4,096 bytes.") }
        do { _ = try NSRegularExpression(pattern: pattern) }
        catch { throw QueryValidationError(error.localizedDescription) }
    }

    private static func lex(_ text: String) throws -> [Lexeme] {
        let chars = Array(text)
        var out: [Lexeme] = [], index = 0
        while index < chars.count {
            let ch = chars[index]
            if ch.isWhitespace { index += 1; continue }
            if ch == "(" || ch == "<" { out.append(.open(ch)); index += 1; continue }
            if ch == ")" || ch == ">" { out.append(.close(ch)); index += 1; continue }
            if ch == "|" { out.append(.or); index += 1; continue }
            if ch == "!" { out.append(.not); index += 1; continue }
            let forcedLiteral = ch == "\""
            var value = "", quoted = false, inQuote = false
            while index < chars.count {
                let next = chars[index]
                if next == "\"" { quoted = true; inQuote.toggle(); index += 1; continue }
                // Only quote/backslash escapes are decoded inside quoted values;
                // regex escapes such as \d and literal backslashes remain intact.
                if inQuote && next == "\\" && index + 1 < chars.count,
                   chars[index + 1] == "\"" || chars[index + 1] == "\\" {
                    value.append(chars[index + 1]); index += 2; continue
                }
                if !inQuote {
                    if next.isWhitespace || next == "(" || next == ")" || next == "|" { break }
                    // Comparisons belong to size/date values; standalone angle
                    // brackets form groups, including <ext:pdf|ext:txt>.
                    let comparison = value.hasSuffix(":") && ["size:", "dm:", "date-modified:"].contains(value.lowercased())
                    if next == "<" && !comparison { break }
                    if next == ">" && !comparison { break }
                }
                value.append(next); index += 1
            }
            guard !inQuote else { throw QueryValidationError("The search query contains an unclosed quote.") }
            guard !value.isEmpty else { throw QueryValidationError("A search term or quoted value is empty.") }
            switch value {
            case "AND" where !quoted: out.append(.and)
            case "OR" where !quoted: out.append(.or)
            case "NOT" where !quoted: out.append(.not)
            default: out.append(.term(value, quoted, forcedLiteral))
            }
        }
        return out
    }

    private struct Parser {
        let lexemes: [Lexeme]
        let date: Date
        var index = 0
        var depth = 0
        var advanced = false
        var tokens: [Query.Token] = []
        var relativeDates = false

        mutating func parse() throws -> QueryExpression {
            guard !lexemes.isEmpty else { return .and([]) }
            let result = try conjunction()
            guard index == lexemes.count else { throw QueryValidationError("The search query has an unexpected closing group.") }
            return result
        }
        mutating func disjunction() throws -> QueryExpression {
            var expressions = [try unary()]
            while index < lexemes.count, case .or = lexemes[index] {
                advanced = true; index += 1
                expressions.append(try unary())
            }
            return expressions.count == 1 ? expressions[0] : .or(expressions)
        }
        mutating func conjunction() throws -> QueryExpression {
            // OR binds more tightly than AND: apple banana|orange searches for
            // apple AND (banana OR orange), matching the documented query syntax.
            var expressions = [try disjunction()]
            while index < lexemes.count {
                switch lexemes[index] {
                case .close: return expressions.count == 1 ? expressions[0] : .and(expressions)
                case .and: advanced = true; index += 1
                default: break
                }
                expressions.append(try disjunction())
            }
            return expressions.count == 1 ? expressions[0] : .and(expressions)
        }
        mutating func unary() throws -> QueryExpression {
            guard index < lexemes.count else { throw QueryValidationError("A search operator is missing its following term.") }
            guard depth < 64 else { throw QueryValidationError("The search query exceeds 64 nested operators or groups.") }
            depth += 1
            defer { depth -= 1 }
            switch lexemes[index] {
            case .not:
                advanced = true; index += 1
                return .not(try unary())
            case .open(let opening):
                advanced = true; index += 1
                let result = try conjunction()
                guard index < lexemes.count, case .close(let closing) = lexemes[index],
                      opening == "(" && closing == ")" || opening == "<" && closing == ">" else {
                    throw QueryValidationError("The search query contains an unclosed or mismatched group.")
                }
                index += 1
                return result
            case .term(let value, let quoted, let forcedLiteral):
                index += 1
                let parsed = try QueryPredicate.parse(value, quoted: quoted, date: date, forcedLiteral: forcedLiteral)
                if parsed.structured { advanced = true }
                if parsed.relative { relativeDates = true }
                if case .text(let token, _) = parsed.predicate { tokens.append(token) }
                if case .typedText(_, let token) = parsed.predicate { tokens.append(token) }
                return .predicate(parsed.predicate)
            case .and, .or, .close:
                throw QueryValidationError("A search operator or closing group appears where a term is required.")
            }
        }
    }
}
