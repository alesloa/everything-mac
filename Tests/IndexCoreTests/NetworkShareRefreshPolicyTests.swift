import Foundation
import Testing
@testable import IndexCore

struct NetworkShareRefreshPolicyTests {
    @Test func unsupportedIntervalsFallBackToTheApplicationDefault() {
        for interval in [0.0, -1, .infinity, .nan, 301] {
            #expect(NetworkShareRefreshPolicy(interval: interval).interval == 300)
        }
        #expect(NetworkShareRefreshPolicy().paused == false)
    }

    @Test func persistedPolicyKeepsPauseAndSupportedSchedule() throws {
        let policy = NetworkShareRefreshPolicy(paused: true, interval: 900)
        let data = try JSONEncoder().encode(policy)
        #expect(try JSONDecoder().decode(NetworkShareRefreshPolicy.self, from: data) == policy)
    }

    @Test func oldOrInvalidPersistedSchedulesAreNormalized() throws {
        let missing = try JSONDecoder().decode(NetworkShareRefreshPolicy.self, from: Data("{}".utf8))
        #expect(missing == NetworkShareRefreshPolicy())
        let invalid = try JSONDecoder().decode(NetworkShareRefreshPolicy.self,
                                              from: Data("{\"paused\":true,\"interval\":-1}".utf8))
        #expect(invalid == NetworkShareRefreshPolicy(paused: true))
    }
}
