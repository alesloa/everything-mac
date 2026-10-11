import Testing
import Foundation
@testable import IndexCore

@Test func excludesByNameAndPath() {
    let rules = ExcludeRules(
        names: [".git", "node_modules"],
        pathPrefixes: ["/private/var/folders"],
        excludeHidden: false
    )
    #expect(rules.shouldExclude(name: ".git", path: "/a/.git", isHidden: true))
    #expect(rules.shouldExclude(name: "node_modules", path: "/p/node_modules", isHidden: false))
    #expect(rules.shouldExclude(name: "x", path: "/private/var/folders/x", isHidden: false))
    #expect(!rules.shouldExclude(name: "report.pdf", path: "/a/report.pdf", isHidden: false))
}

@Test func excludesHiddenWhenEnabled() {
    let rules = ExcludeRules(names: [], pathPrefixes: [], excludeHidden: true,
                             excludeDevFolders: false, excludeVCSFolders: false)
    #expect(rules.shouldExclude(name: ".ssh", path: "/u/.ssh", isHidden: true))
    #expect(!rules.shouldExclude(name: "visible", path: "/u/visible", isHidden: false))
}

@Test func skipsUnambiguousDevFoldersByDefault() {
    let rules = ExcludeRules.defaults
    #expect(rules.excludeDevFolders)
    // Unambiguous names are skipped anywhere — no project marker required.
    #expect(rules.shouldExclude(name: "node_modules", path: "/p/node_modules", isHidden: false))
    #expect(rules.shouldExclude(name: ".venv", path: "/p/.venv", isHidden: true))
    #expect(rules.shouldExclude(name: "DerivedData", path: "/x/DerivedData", isHidden: false))
    #expect(rules.shouldExclude(name: "Pods", path: "/x/Pods", isHidden: false))
    // A normal user folder is still indexed.
    #expect(!rules.shouldExclude(name: "Documents", path: "/u/Documents", isHidden: false))
    // Dangerously generic names that collide with system/user dirs are NOT skipped.
    #expect(!rules.shouldExclude(name: "bin", path: "/usr/bin", isHidden: false))
    #expect(!rules.shouldExclude(name: "lib", path: "/usr/lib", isHidden: false))
}

@Test func genericDevFoldersSkippedOnlyInsideProjects() {
    let rules = ExcludeRules.defaults
    // Outside a project dir (no marker) generic names stay searchable.
    #expect(!rules.shouldExclude(name: "build", path: "/u/Documents/build", isHidden: false, inProjectDir: false))
    #expect(!rules.shouldExclude(name: "target", path: "/u/Documents/target", isHidden: false, inProjectDir: false))
    #expect(!rules.shouldExclude(name: "vendor", path: "/u/Documents/vendor", isHidden: false, inProjectDir: false))
    // Inside a directory that holds a project marker, they are skipped.
    #expect(rules.shouldExclude(name: "build", path: "/code/app/build", isHidden: false, inProjectDir: true))
    #expect(rules.shouldExclude(name: "target", path: "/code/app/target", isHidden: false, inProjectDir: true))
    #expect(rules.shouldExclude(name: "vendor", path: "/code/app/vendor", isHidden: false, inProjectDir: true))
}

@Test func skipsVCSFoldersByDefaultAndCanBeDisabled() {
    let on = ExcludeRules.defaults
    #expect(on.excludeVCSFolders)
    #expect(on.shouldExclude(name: ".git", path: "/x/.git", isHidden: true))
    #expect(on.shouldExclude(name: ".hg", path: "/x/.hg", isHidden: true))
    #expect(on.shouldExclude(name: ".svn", path: "/x/.svn", isHidden: true))
    let off = ExcludeRules(names: [], pathPrefixes: [], excludeHidden: false,
                           excludeDevFolders: true, excludeVCSFolders: false)
    #expect(!off.shouldExclude(name: ".git", path: "/x/.git", isHidden: false))
}

@Test func devFolderSkippingCanBeDisabled() {
    let rules = ExcludeRules(names: [], pathPrefixes: [], excludeHidden: false,
                             excludeDevFolders: false, excludeVCSFolders: false)
    #expect(!rules.shouldExclude(name: "node_modules", path: "/p/node_modules", isHidden: false))
    #expect(!rules.shouldExclude(name: "target", path: "/r/target", isHidden: false, inProjectDir: true))
}

@Test func skipsTrashByDefaultAndCanBeDisabled() {
    let on = ExcludeRules.defaults
    #expect(on.excludeTrash)
    #expect(on.shouldExclude(name: ".Trash", path: "/Users/me/.Trash", isHidden: true))
    #expect(on.shouldExclude(name: ".Trashes", path: "/Volumes/Disk/.Trashes", isHidden: true))
    let off = ExcludeRules(names: [], pathPrefixes: [], excludeHidden: false,
                           excludeDevFolders: false, excludeVCSFolders: false, excludeTrash: false)
    #expect(!off.shouldExclude(name: ".Trash", path: "/Users/me/.Trash", isHidden: false))
}

@Test func excludesFilesByWildcardAndExactName() {
    let rules = ExcludeRules(excludeFilePatterns: ["*.tmp", "Thumbs.db", "*cache*"])
    // Wildcard, anchored to the whole filename.
    #expect(rules.shouldExcludeFile(name: "scratch.tmp"))
    #expect(rules.shouldExcludeFile(name: "report.TMP"))           // case-insensitive
    #expect(!rules.shouldExcludeFile(name: "tmpfile"))             // *.tmp doesn't match (no dot+end)
    // Exact name (no wildcard) is an exact, case-insensitive filename match.
    #expect(rules.shouldExcludeFile(name: "thumbs.db"))
    #expect(!rules.shouldExcludeFile(name: "xThumbs.db"))          // exact, not substring
    // Wildcards on both sides = contains.
    #expect(rules.shouldExcludeFile(name: "my.cache.file"))
    // Anything not listed stays.
    #expect(!rules.shouldExcludeFile(name: "report.pdf"))
    // Empty pattern set never excludes.
    #expect(!ExcludeRules().shouldExcludeFile(name: "anything.tmp"))
}

@Test func fingerprintChangesWithTrashAndFilePatterns() {
    let base = ExcludeRules.defaults
    var noTrash = base; noTrash.excludeTrash = false
    #expect(base.fingerprint() != noTrash.fingerprint())
    var withPatterns = base; withPatterns.excludeFilePatterns = ["*.log"]
    #expect(base.fingerprint() != withPatterns.fingerprint())
    // Same fields → same fingerprint (deterministic across instances).
    #expect(base.fingerprint() == ExcludeRules.defaults.fingerprint())
}

@Test func roundTripsFilePatternsThroughCodable() throws {
    let rules = ExcludeRules(excludeFilePatterns: ["*.tmp", "*.log"])
    let data = try JSONEncoder().encode(rules)
    let back = try JSONDecoder().decode(ExcludeRules.self, from: data)
    #expect(back.excludeFilePatterns == ["*.tmp", "*.log"])
    // Legacy blob without the key decodes to an empty pattern list (not a failure).
    let legacy = #"{"names":[],"pathPrefixes":[],"excludeHidden":false}"#
    let decoded = try JSONDecoder().decode(ExcludeRules.self, from: Data(legacy.utf8))
    #expect(decoded.excludeFilePatterns.isEmpty)
}

@Test func decodesLegacyRulesWithoutNewKeys() throws {
    // Settings saved before the dev/VCS toggles existed must decode with both skips
    // ON and the user's custom names intact — not fail and silently reset to defaults.
    let legacy = #"{"names":["my_custom"],"pathPrefixes":["/tmp"],"excludeHidden":true}"#
    let rules = try JSONDecoder().decode(ExcludeRules.self, from: Data(legacy.utf8))
    #expect(rules.names.contains("my_custom"))
    #expect(rules.excludeHidden)
    #expect(rules.excludeDevFolders)
    #expect(rules.excludeVCSFolders)
}
