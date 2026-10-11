import Foundation

/// A mapping is explicit owner input. Imported paths never become Mac URLs
/// implicitly, even when they happen to start with a slash or an existing mount.
public struct CatalogPathMapping: Sendable, Codable, Equatable {
    public let sourcePrefix: String
    public let localRoot: URL
    public init(sourcePrefix: String, localRoot: URL) {
        self.sourcePrefix = sourcePrefix; self.localRoot = localRoot
    }
    public func resolve(_ catalogPath: String) throws -> URL {
        guard !sourcePrefix.isEmpty, localRoot.isFileURL, localRoot.path.hasPrefix("/"),
              !catalogPath.contains("\0"), !sourcePrefix.contains("\0") else {
            throw CatalogError.unsafeMapping("The source prefix and local root are invalid.")
        }
        let windows = sourcePrefix.contains("\\") || (sourcePrefix.count >= 2 && sourcePrefix.dropFirst().first == ":")
        var prefix = windows ? sourcePrefix.replacingOccurrences(of: "\\", with: "/") : sourcePrefix
        while prefix.hasSuffix("/") && prefix.count > 1 { prefix.removeLast() }
        let path = windows ? catalogPath.replacingOccurrences(of: "\\", with: "/") : catalogPath
        let comparison: String.CompareOptions = windows ? [.caseInsensitive, .literal] : [.literal]
        let boundary = prefix == "/" ? "/" : prefix + "/"
        let matched = path.range(of: boundary, options: comparison.union(.anchored))
        guard path.compare(prefix, options: comparison) == .orderedSame || matched != nil else {
            throw CatalogError.unsafeMapping("The imported path does not match the selected source prefix.")
        }
        let remainder = matched.map { String(path[$0.upperBound...]) } ?? ""
        let components = remainder.split(separator: "/", omittingEmptySubsequences: false)
        guard components.allSatisfy({ $0 != ".." && $0 != "." && !$0.contains(":") }) else {
            throw CatalogError.unsafeMapping("The imported path contains an unsafe component.")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: localRoot.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw CatalogError.unsafeMapping("The selected local root is not an available folder.")
        }
        let root = localRoot.resolvingSymlinksInPath().standardizedFileURL
        var resolved = root
        for component in components where !component.isEmpty {
            resolved.appendPathComponent(String(component))
            // Resolve each existing ancestor separately: Foundation may leave an
            // entire path unresolved when its final filename does not exist.
            resolved = resolved.resolvingSymlinksInPath().standardizedFileURL
            guard resolved.path == root.path || resolved.path.hasPrefix(root.path == "/" ? "/" : root.path + "/") else {
                throw CatalogError.unsafeMapping("The imported path resolves outside the selected local root.")
            }
        }
        return resolved
    }
}
