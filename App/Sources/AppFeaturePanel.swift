import Foundation

enum AppFeaturePanel: String, Identifiable {
    case advancedSearch, bookmarks, catalogs, export, duplicates, contentSearch, activity
    var id: String { rawValue }
}
