public struct ExcludeRules: Sendable, Codable, Equatable {
    public var names: Set<String>
    public var pathPrefixes: [String]
    public var excludeHidden: Bool
    // When on, a curated set of regenerable developer build/dependency directories
    // (see `devFolderNames`) is skipped on top of the user's own `names`. Kept as a
    // separate toggle so the user's custom list stays clean and the whole bundle can
    // be turned off in one click. Defaults on — these folders hold huge numbers of
    // churny files that bloat the index and trigger constant live re-scans.
    public var excludeDevFolders: Bool

    public init(names: Set<String> = [], pathPrefixes: [String] = [],
                excludeHidden: Bool = false, excludeDevFolders: Bool = true) {
        self.names = names
        self.pathPrefixes = pathPrefixes
        self.excludeHidden = excludeHidden
        self.excludeDevFolders = excludeDevFolders
    }

    // Settings saved before `excludeDevFolders` existed lack that key. Decode it as
    // ON when absent so upgrading enables dev-folder skipping WITHOUT discarding the
    // user's custom names (a hard decode failure would reset rules to defaults).
    private enum CodingKeys: String, CodingKey {
        case names, pathPrefixes, excludeHidden, excludeDevFolders
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        names = try c.decode(Set<String>.self, forKey: .names)
        pathPrefixes = try c.decode([String].self, forKey: .pathPrefixes)
        excludeHidden = try c.decode(Bool.self, forKey: .excludeHidden)
        excludeDevFolders = try c.decodeIfPresent(Bool.self, forKey: .excludeDevFolders) ?? true
    }

    // Regenerable build output and dependency/cache directories common to dev work.
    // Matched by exact folder name at ANY depth — the scanner skips the whole subtree
    // and never descends into it. Deliberately omits dangerously generic names (bin,
    // lib, out, tmp, src) that collide with system or user folders and would hide
    // real results.
    public static let devFolderNames: Set<String> = [
        // Version control
        ".git", ".hg", ".svn",
        // JS / web frameworks & tooling
        "node_modules", "bower_components",
        ".next", ".nuxt", ".svelte-kit", ".astro", ".angular",
        ".turbo", ".parcel-cache",
        // Build / distribution output
        "build", "dist",
        // Rust / Cargo
        "target", ".cargo", ".rustup",
        // Swift / Xcode
        ".build", "DerivedData",
        // CocoaPods / Carthage
        "Pods", "Carthage",
        // JVM
        ".gradle",
        // Python
        "venv", ".venv", "__pycache__", ".pytest_cache", ".mypy_cache", ".tox", ".eggs",
        // Go / PHP / Ruby dependencies
        "vendor",
        // Infra / misc caches
        ".terraform", ".cache", "coverage",
    ]

    public static let defaults = ExcludeRules(
        names: [],
        pathPrefixes: ["/private/var/folders", "/System/Volumes/Data/private/var/folders"],
        excludeHidden: false,
        excludeDevFolders: true
    )

    public func shouldExclude(name: String, path: String, isHidden: Bool) -> Bool {
        if excludeHidden && isHidden { return true }
        if names.contains(name) { return true }
        if excludeDevFolders && Self.devFolderNames.contains(name) { return true }
        for prefix in pathPrefixes where path.hasPrefix(prefix) { return true }
        return false
    }
}
