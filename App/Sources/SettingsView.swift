import SwiftUI
import IndexCore

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var namesText = ""
    @State private var excludeHidden = false

    var body: some View {
        Form {
            Section("Excluded folder names (one per line)") {
                TextEditor(text: $namesText)
                    .frame(height: 120)
                    .font(.system(.body, design: .monospaced))
            }
            Toggle("Exclude hidden files", isOn: $excludeHidden)
            Button("Apply & Re-index") {
                let names = Set(namesText.split(separator: "\n").map(String.init).filter { !$0.isEmpty })
                model.applyRules(ExcludeRules(names: names,
                                              pathPrefixes: model.rules.pathPrefixes,
                                              excludeHidden: excludeHidden))
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear {
            namesText = model.rules.names.sorted().joined(separator: "\n")
            excludeHidden = model.rules.excludeHidden
        }
    }
}
