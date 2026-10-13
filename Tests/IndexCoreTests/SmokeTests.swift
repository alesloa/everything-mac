import Testing
@testable import IndexCore

@Test func versionIsSet() {
    // Source: the application version in App/project.yml.
    #expect(IndexCore.version == "0.6.1")
}
