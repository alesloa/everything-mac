import SwiftUI
import IndexCore

// Index-shaping exclude rules. Edits stay in the shared SettingsModel until the user
// hits "Apply & Re-index", which rebuilds the index with the new rules (changing any
// of these alters the cache fingerprint, so a rebuild is required to take effect).
struct ExcludeSettingsView: View {
    @ObservedObject var edit: SettingsModel
    var apply: () -> Void

    var body: some View {
        Form {
            Section("Skip these while indexing") {
                Toggle("Developer folders (node_modules, Pods, .venv; build/dist/target in projects)",
                       isOn: $edit.excludeDevFolders)
                Toggle("Version-control folders (.git, .hg, .svn)", isOn: $edit.excludeVCSFolders)
                Toggle("The Trash", isOn: $edit.excludeTrash)
                Toggle("Hidden files and folders", isOn: $edit.excludeHidden)
            }
            Section("Excluded folder names (one per line)") {
                TextEditor(text: $edit.namesText)
                    .frame(height: 70)
                    .font(.system(.body, design: .monospaced))
            }
            Section {
                TextEditor(text: $edit.filePatternsText)
                    .frame(height: 70)
                    .font(.system(.body, design: .monospaced))
            } header: {
                Text("Excluded file patterns (one per line)")
            } footer: {
                Text("Wildcards allowed: \"*.tmp\", \"*.log\", \"Thumbs.db\". Matches file names only.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                HStack {
                    Spacer()
                    Button("Apply & Re-index", action: apply)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .formStyle(.grouped)
        .padding(20)
    }
}
