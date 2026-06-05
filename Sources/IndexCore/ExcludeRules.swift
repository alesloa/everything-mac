public struct ExcludeRules: Sendable, Codable, Equatable {
    public var names: Set<String>
    public var pathPrefixes: [String]
    public var excludeHidden: Bool

    public init(names: Set<String> = [], pathPrefixes: [String] = [], excludeHidden: Bool = false) {
        self.names = names
        self.pathPrefixes = pathPrefixes
        self.excludeHidden = excludeHidden
    }

    public static let defaults = ExcludeRules(
        names: [".git", "node_modules"],
        pathPrefixes: ["/private/var/folders", "/System/Volumes/Data/private/var/folders"],
        excludeHidden: false
    )

    public func shouldExclude(name: String, path: String, isHidden: Bool) -> Bool {
        if excludeHidden && isHidden { return true }
        if names.contains(name) { return true }
        for prefix in pathPrefixes where path.hasPrefix(prefix) { return true }
        return false
    }
}
