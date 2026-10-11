import Foundation

enum FinderInfoRequest {
    // Paths are interpreter arguments; the AppleScript program never includes filename text.
    static let script = """
    on run paths
        tell application id "com.apple.finder"
            repeat with filePath in paths
                open information window of (POSIX file (contents of filePath) as alias)
            end repeat
            activate
        end tell
    end run
    """

    static func arguments(for paths: [String]) -> [String] { ["-l", "AppleScript", "-"] + paths }
}
