import Foundation

public enum SearchFilter: String, CaseIterable, Sendable, Hashable, Codable {
    case all, files, folders, images, documents, audio, video, archives

    // Display names and extension membership come from this application's
    // built-in filter definitions in SearchFilter.swift.
    public var title: String {
        switch self {
        case .all: "Everything"
        case .files: "Files"
        case .folders: "Folders"
        case .images: "Images"
        case .documents: "Documents"
        case .audio: "Audio"
        case .video: "Video"
        case .archives: "Archives"
        }
    }
    public var queryFragment: String {
        switch self {
        case .all: ""
        case .files: "file:"
        case .folders: "folder:"
        case .images: "ext:avif;bmp;gif;heic;heif;ico;jpeg;jpg;png;psd;raw;svg;tif;tiff;webp"
        case .documents: "ext:csv;doc;docx;epub;htm;html;key;md;numbers;odt;pages;pdf;ppt;pptx;rtf;txt;xls;xlsx"
        case .audio: "ext:aac;aif;aiff;alac;flac;m4a;mid;midi;mp3;ogg;opus;wav;wma"
        case .video: "ext:avi;m4v;mkv;mov;mp4;mpeg;mpg;webm;wmv"
        case .archives: "ext:7z;bz2;cab;gz;gzip;rar;tar;tgz;xz;zip"
        }
    }
    public func applying(to text: String) -> String {
        guard self != .all else { return text }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? queryFragment : "(\(text)) \(queryFragment)"
    }
    public func applying(to query: Query) -> Query {
        guard self != .all else { return query }
        var query = query
        if query.regex {
            query.regex = false
            query.text = "regex:\(Query.quotedLiteral(query.text))"
        }
        query.text = applying(to: query.text)
        return query
    }
}

public extension Query {
    // Quoting preserves actual owner-entered filenames, paths and regex values,
    // including literal quotes/backslashes and characters used as operators.
    static func quotedLiteral(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

public struct AdvancedSearchCriteria: Sendable {
    public var name = ""
    public var excludedName = ""
    public var extensions = ""
    public var location = ""
    public var directParent = false
    public var minimumSize = ""
    public var maximumSize = ""
    public var modifiedFrom = ""
    public var modifiedThrough = ""
    public var regularExpression = ""
    public var filter: SearchFilter = .all

    public init() {}

    public var queryText: String {
        var terms: [String] = []
        func add(_ key: String, _ value: String) {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { terms.append("\(key):\(Query.quotedLiteral(trimmed))") }
        }
        add("name", name)
        let excluded = excludedName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !excluded.isEmpty { terms.append("NOT name:\(Query.quotedLiteral(excluded))") }
        add("ext", extensions)
        add(directParent ? "parent" : "path", location)
        if !minimumSize.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { add("size", ">=" + minimumSize) }
        if !maximumSize.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { add("size", "<=" + maximumSize) }
        if !modifiedFrom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { add("dm", ">=" + modifiedFrom) }
        if !modifiedThrough.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { add("dm", "<=" + modifiedThrough) }
        add("regex", regularExpression)
        return filter.applying(to: terms.joined(separator: " "))
    }
    public var validationError: QueryValidationError? { Query(text: queryText).validationError }
}
