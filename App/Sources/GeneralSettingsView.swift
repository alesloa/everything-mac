import SwiftUI
import IndexCore

struct GeneralSettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var launchAtLogin = LaunchAtLogin.isEnabled

    var body: some View {
        Form {
            Section("Startup") {
                Toggle("Open EverythingMac at login", isOn: $launchAtLogin)
                    // set() reflects the real resulting state — if registration fails
                    // the toggle snaps back instead of lying.
                    .onChange(of: launchAtLogin) { launchAtLogin = LaunchAtLogin.set(launchAtLogin) }
            }
            GlobalAccessSettingsView()
            Section("Index") {
                LabeledContent("Objects indexed", value: model.total.formatted())
                if let s = Self.cacheStats() {
                    LabeledContent("Cache size",
                                   value: ByteCountFormatter.string(fromByteCount: s.size, countStyle: .file))
                    if let modified = s.modified {
                        LabeledContent("Last saved",
                                       value: modified.formatted(date: .abbreviated, time: .shortened))
                    }
                } else {
                    // Source: FileManager did not return usable attributes for this cache path.
                    LabeledContent("Cache", value: "Unavailable")
                }
                Button(model.scanning ? "Rebuilding…" : "Rebuild Index Now") { model.rebuildIndex() }
                    .disabled(model.scanning)
            }
        }
        .formStyle(.grouped)
        .padding(20)
    }

    // Size + mtime of the on-disk index cache (~/Library/Application Support/...).
    static func cacheStats() -> (size: Int64, modified: Date?)? {
        let path = IndexActor.cacheURL().path
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = (attrs[.size] as? NSNumber)?.int64Value else { return nil }
        // Source: FileManager's modificationDate attribute; omit an absent date.
        let date = attrs[.modificationDate] as? Date
        return (size, date)
    }
}
