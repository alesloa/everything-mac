import Foundation

public struct NetworkShareRefreshPolicy: Sendable, Codable, Equatable {
    // These are application preference choices, not server refresh guarantees.
    public static let intervals: [TimeInterval] = [60, 300, 900, 3600]
    public static let defaultInterval: TimeInterval = 300

    public let paused: Bool
    public let interval: TimeInterval

    public init(paused: Bool = false, interval: TimeInterval = defaultInterval) {
        self.paused = paused
        self.interval = Self.intervals.contains(interval) ? interval : Self.defaultInterval
    }

    private enum CodingKeys: String, CodingKey { case paused, interval }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(paused: try container.decodeIfPresent(Bool.self, forKey: .paused) ?? false,
                  interval: try container.decodeIfPresent(TimeInterval.self, forKey: .interval)
                    ?? Self.defaultInterval)
    }
}
