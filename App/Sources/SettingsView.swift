import SwiftUI
import IndexCore

// Editable working copy of the index's ExcludeRules, shared across the Exclude and
// Volumes tabs. Search/Results/General settings bind AppModel directly (they apply
// live); only the index-shaping rules need an explicit "Apply & Re-index".
@MainActor final class SettingsModel: ObservableObject {
    @Published var namesText = ""
    @Published var filePatternsText = ""
    @Published var pathPrefixes: [String] = []
    @Published var excludeHidden = false
    @Published var excludeDevFolders = true
    @Published var excludeVCSFolders = true
    @Published var excludeTrash = true

    func load(from rules: ExcludeRules) {
        namesText = rules.names.sorted().joined(separator: "\n")
        filePatternsText = rules.excludeFilePatterns.joined(separator: "\n")
        pathPrefixes = rules.pathPrefixes
        excludeHidden = rules.excludeHidden
        excludeDevFolders = rules.excludeDevFolders
        excludeVCSFolders = rules.excludeVCSFolders
        excludeTrash = rules.excludeTrash
    }

    func makeRules() -> ExcludeRules {
        func lines(_ s: String) -> [String] {
            s.split(whereSeparator: \.isNewline)
             .map { $0.trimmingCharacters(in: .whitespaces) }
             .filter { !$0.isEmpty }
        }
        return ExcludeRules(names: Set(lines(namesText)),
                            pathPrefixes: pathPrefixes,
                            excludeHidden: excludeHidden,
                            excludeDevFolders: excludeDevFolders,
                            excludeVCSFolders: excludeVCSFolders,
                            excludeTrash: excludeTrash,
                            excludeFilePatterns: lines(filePatternsText))
    }
}

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var edit = SettingsModel()

    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
            SearchSettingsView()
                .tabItem { Label("Search", systemImage: "magnifyingglass") }
            ExcludeSettingsView(edit: edit, apply: apply)
                .tabItem { Label("Exclude", systemImage: "nosign") }
            VolumesSettingsView(edit: edit, apply: apply)
                .tabItem { Label("Volumes", systemImage: "externaldrive") }
        }
        .frame(width: 540, height: 480)
        .onAppear { edit.load(from: model.rules) }
        // Re-seed if the rules change underneath us (e.g. a rebuild triggered from the
        // menu while Settings is open). After our own Apply the values are identical,
        // so this is a no-op there.
        .onChange(of: model.rules) { edit.load(from: model.rules) }
    }

    private func apply() { model.applyRules(edit.makeRules()) }
}
