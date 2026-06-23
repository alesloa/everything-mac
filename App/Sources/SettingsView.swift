import SwiftUI
import IndexCore

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var namesText = ""
    @State private var excludeHidden = false
    @State private var excludeDevFolders = true
    @State private var excludeVCSFolders = true

    var body: some View {
        Form {
            Section("Excluded folder names (one per line)") {
                TextEditor(text: $namesText)
                    .frame(height: 120)
                    .font(.system(.body, design: .monospaced))
            }
            Toggle("Skip developer folders (node_modules, Pods, .venv; build/dist/target only inside projects)",
                   isOn: $excludeDevFolders)
            Toggle("Skip version-control folders (.git, .hg, .svn)", isOn: $excludeVCSFolders)
            Toggle("Exclude hidden files", isOn: $excludeHidden)
            Button("Apply & Re-index") {
                let names = Set(namesText.split(separator: "\n").map(String.init).filter { !$0.isEmpty })
                model.applyRules(ExcludeRules(names: names,
                                              pathPrefixes: model.rules.pathPrefixes,
                                              excludeHidden: excludeHidden,
                                              excludeDevFolders: excludeDevFolders,
                                              excludeVCSFolders: excludeVCSFolders))
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear {
            namesText = model.rules.names.sorted().joined(separator: "\n")
            excludeHidden = model.rules.excludeHidden
            excludeDevFolders = model.rules.excludeDevFolders
            excludeVCSFolders = model.rules.excludeVCSFolders
        }
    }
}
