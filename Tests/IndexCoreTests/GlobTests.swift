import Testing
@testable import IndexCore

@Test func globMatchesWildcards() {
    #expect(Glob.matches(pattern: "*.pdf", in: "report.pdf", caseInsensitive: true))
    #expect(Glob.matches(pattern: "re?ort", in: "report", caseInsensitive: true))
    #expect(Glob.matches(pattern: "REPORT", in: "report", caseInsensitive: true))
    #expect(!Glob.matches(pattern: "*.pdf", in: "report.txt", caseInsensitive: true))
    #expect(Glob.matches(pattern: "rep", in: "myreport.pdf", caseInsensitive: true))
    #expect(!Glob.matches(pattern: "zzz", in: "report", caseInsensitive: true))
}
