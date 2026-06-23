import SwiftUI
import AppKit
import IndexCore

// Pick which mounted drives to index and manage arbitrary excluded folders. Both edit
// the shared SettingsModel.pathPrefixes; turning a volume off adds its mount path as an
// excluded prefix. Like the Exclude tab, changes take effect on "Apply & Re-index".
struct VolumesSettingsView: View {
    @ObservedObject var edit: SettingsModel
    var apply: () -> Void
    @State private var volumes: [VolumeInfo] = []

    struct VolumeInfo: Identifiable {
        let id = UUID()
        let name: String
        let path: String
        let isBoot: Bool
    }

    var body: some View {
        Form {
            Section("Drives to index") {
                ForEach(volumes) { v in
                    Toggle(isOn: volumeBinding(v)) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(v.name)
                            Text(v.isBoot ? v.path + "  (boot volume)" : v.path)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    // Excluding the entire boot volume would empty the index — exclude
                    // individual folders below instead.
                    .disabled(v.isBoot)
                }
                if volumes.isEmpty { Text("No local volumes found.").foregroundStyle(.secondary) }
            }
            Section("Excluded folders") {
                if userPaths.isEmpty {
                    Text("None").foregroundStyle(.secondary)
                } else {
                    ForEach(userPaths, id: \.self) { p in
                        HStack {
                            Text(p)
                                .font(.system(.body, design: .monospaced))
                                .lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button(role: .destructive) { edit.pathPrefixes.removeAll { $0 == p } } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
                Button("Add Folder…") { addFolder() }
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
        .onAppear { volumes = Self.localVolumes() }
    }

    // A volume is "indexed" unless its mount path is in the excluded prefixes.
    private func volumeBinding(_ v: VolumeInfo) -> Binding<Bool> {
        Binding(get: { !edit.pathPrefixes.contains(v.path) },
                set: { include in
                    if include {
                        edit.pathPrefixes.removeAll { $0 == v.path }
                    } else if !edit.pathPrefixes.contains(v.path) {
                        edit.pathPrefixes.append(v.path)
                    }
                })
    }

    // Hide the firmlink/system prefixes the app manages internally so the list only
    // shows folders the user actually added.
    private var userPaths: [String] {
        edit.pathPrefixes.filter {
            !$0.hasPrefix("/private/var/folders") && !$0.hasPrefix("/System/Volumes")
        }
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.title = "Exclude Folder"
        panel.prompt = "Exclude"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            let p = url.path
            if !edit.pathPrefixes.contains(p) { edit.pathPrefixes.append(p) }
        }
    }

    static func localVolumes() -> [VolumeInfo] {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeIsLocalKey]
        guard let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) else { return [] }
        var out: [VolumeInfo] = []
        for u in urls {
            guard let vals = try? u.resourceValues(forKeys: Set(keys)), vals.volumeIsLocal == true else { continue }
            out.append(VolumeInfo(name: vals.volumeName ?? u.lastPathComponent,
                                  path: u.path, isBoot: u.path == "/"))
        }
        return out
    }
}
