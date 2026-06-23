public struct ExcludeRules: Sendable, Codable, Equatable {
    public var names: Set<String>
    public var pathPrefixes: [String]
    public var excludeHidden: Bool
    // When on, regenerable developer build/dependency directories are skipped on top
    // of the user's own `names`. Unambiguous names (see `devFolderNames`) are skipped
    // anywhere; generic English-word names (see `markerScopedDevFolderNames`) are only
    // skipped inside a directory that also holds a project marker, so a personal
    // ~/Documents/build isn't silently hidden by a tool whose whole job is recall.
    public var excludeDevFolders: Bool
    // Version-control internals (.git/.hg/.svn). Separate toggle from dev folders so a
    // user can re-index a build dir to find one file WITHOUT also pulling every churny
    // .git blob on disk back into the index.
    public var excludeVCSFolders: Bool
    // The Trash (~/.Trash and per-volume /.Trashes). A "deleted" file still turning up
    // in search confuses users — the point of deleting is for it to be gone — so Trash
    // is skipped by default; toggle off to search inside it.
    public var excludeTrash: Bool

    public init(names: Set<String> = [], pathPrefixes: [String] = [],
                excludeHidden: Bool = false, excludeDevFolders: Bool = true,
                excludeVCSFolders: Bool = true, excludeTrash: Bool = true) {
        self.names = names
        self.pathPrefixes = pathPrefixes
        self.excludeHidden = excludeHidden
        self.excludeDevFolders = excludeDevFolders
        self.excludeVCSFolders = excludeVCSFolders
        self.excludeTrash = excludeTrash
    }

    // Settings saved before excludeDevFolders/excludeVCSFolders existed lack those
    // keys. Decode each as ON when absent so upgrading enables skipping WITHOUT
    // discarding the user's custom names (a hard decode failure would reset rules to
    // defaults). The three original fields are still hard-decoded — identical to the
    // synthesized conformance this replaces, so no pre-existing blob decodes worse.
    private enum CodingKeys: String, CodingKey {
        case names, pathPrefixes, excludeHidden, excludeDevFolders, excludeVCSFolders, excludeTrash
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        names = try c.decode(Set<String>.self, forKey: .names)
        pathPrefixes = try c.decode([String].self, forKey: .pathPrefixes)
        excludeHidden = try c.decode(Bool.self, forKey: .excludeHidden)
        excludeDevFolders = try c.decodeIfPresent(Bool.self, forKey: .excludeDevFolders) ?? true
        excludeVCSFolders = try c.decodeIfPresent(Bool.self, forKey: .excludeVCSFolders) ?? true
        excludeTrash = try c.decodeIfPresent(Bool.self, forKey: .excludeTrash) ?? true
    }

    // Unambiguous regenerable build output / dependency / tool-cache directories.
    // Skipped by exact name at ANY depth — the scanner skips the whole subtree and
    // never descends. These names essentially never name real user data.
    public static let devFolderNames: Set<String> = [
        // JS / web frameworks & tooling
        "node_modules", "bower_components",
        ".next", ".nuxt", ".svelte-kit", ".astro", ".angular", ".turbo", ".parcel-cache",
        // Swift / Xcode
        ".build", "DerivedData",
        // CocoaPods / Carthage
        "Pods", "Carthage",
        // JVM
        ".gradle",
        // Rust / Cargo
        ".cargo", ".rustup",
        // Python
        "__pycache__", ".pytest_cache", ".mypy_cache", ".tox", ".eggs", "venv", ".venv",
        // Infra / misc caches
        ".terraform", ".cache",
    ]

    // Generic real-English directory names that ALSO happen to be common build output
    // (build, dist, target, …). Skipped ONLY when the containing directory also holds
    // a project marker (see `projectMarkers`), proving it's a code project — so a
    // standalone ~/Documents/build or a "vendor" business folder stays searchable.
    public static let markerScopedDevFolderNames: Set<String> = [
        "build", "dist", "target", "out", "vendor", "coverage",
    ]

    // Files whose presence in a directory marks that directory as a code-project root.
    public static let projectMarkers: Set<String> = [
        "Cargo.toml", "package.json", "go.mod", "pom.xml",
        "build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts",
        "CMakeLists.txt", "Makefile", "GNUmakefile", "composer.json", "Gemfile",
        "pyproject.toml", "setup.py", "setup.cfg", "tsconfig.json", "Package.swift",
        ".git",
    ]

    // Version-control metadata directories, gated by excludeVCSFolders.
    public static let vcsFolderNames: Set<String> = [".git", ".hg", ".svn"]

    public static let defaults = ExcludeRules(
        names: [],
        pathPrefixes: ["/private/var/folders", "/System/Volumes/Data/private/var/folders"],
        excludeHidden: false,
        excludeDevFolders: true,
        excludeVCSFolders: true
    )

    /// `inProjectDir` must be true when the directory being listed contains a project
    /// marker — callers detect that once per directory (see `projectMarkers`) and pass
    /// it for every child, so the generic marker-scoped names are only skipped there.
    public func shouldExclude(name: String, path: String, isHidden: Bool,
                              inProjectDir: Bool = false) -> Bool {
        if excludeHidden && isHidden { return true }
        if names.contains(name) { return true }
        if excludeVCSFolders && Self.vcsFolderNames.contains(name) { return true }
        if excludeDevFolders {
            if Self.devFolderNames.contains(name) { return true }
            if inProjectDir && Self.markerScopedDevFolderNames.contains(name) { return true }
        }
        for prefix in pathPrefixes where path.hasPrefix(prefix) { return true }
        return false
    }

    /// Deterministic 64-bit fingerprint of the user-controllable rule fields (FNV-1a
    /// over a canonical encoding). Unlike Swift's per-run-seeded Hasher this is stable
    /// across launches, so the on-disk index cache can detect when the rules that
    /// shaped it no longer match the active rules and force a rebuild.
    public func fingerprint() -> UInt64 {
        var hash: UInt64 = 1469598103934665603 // FNV-1a offset basis
        func mix(_ s: String) { for b in s.utf8 { hash = (hash ^ UInt64(b)) &* 1099511628211 } }
        mix(excludeHidden ? "H1" : "H0")
        mix(excludeDevFolders ? "D1" : "D0")
        mix(excludeVCSFolders ? "V1" : "V0")
        mix("N"); for n in names.sorted() { mix(n); mix("\u{1}") }
        mix("P"); for p in pathPrefixes { mix(p); mix("\u{1}") }
        return hash
    }
}
