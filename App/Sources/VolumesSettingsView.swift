import SwiftUI
import AppKit
import IndexCore

// Pick which mounted drives to index and manage arbitrary excluded folders. Both edit
// the shared SettingsModel.pathPrefixes; turning a volume off adds its mount path as an
// excluded prefix. Like the Exclude tab, changes take effect on "Apply & Re-index".
struct VolumesSettingsView: View {
    @ObservedObject var edit: SettingsModel
    var apply: () -> Void
    @EnvironmentObject var model: AppModel
    @State private var volumes: [VolumeInfo] = []
    @State private var mountedShares: [MountTable.Mount] = []
    @State private var shareNotice: String?
    @State private var refreshPolicies: [String: NetworkShareRefreshPolicy] = [:]

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
            Section {
                if edit.networkShares.isEmpty {
                    Text("None").foregroundStyle(.secondary)
                }
                ForEach(edit.networkShares) { share in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(share.name)
                                Text(shareDetail(share)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if let status = shareStatus(share), status.scanning || status.queued {
                                Button("Cancel") { Task { await model.index.cancelShareRefresh(share) } }
                                    .buttonStyle(.borderless)
                            } else {
                                Button("Refresh") { Task { await model.index.refreshShare(share) } }
                                    .buttonStyle(.borderless)
                                    .disabled(!isApplied(share) || mountPath(of: share) == nil)
                            }
                            if mountPath(of: share) == nil, share.url != nil {
                                Button("Connect") { model.reconnectShare(share); refreshMounts(after: 3) }
                                    .buttonStyle(.borderless)
                            }
                            Button(role: .destructive) { edit.networkShares.removeAll { $0.source == share.source } } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                        }
                        HStack {
                            Toggle("Pause automatic refresh", isOn: pauseBinding(share))
                                .toggleStyle(.checkbox)
                            Spacer()
                            Picker("Refresh every", selection: intervalBinding(share)) {
                                ForEach(NetworkShareRefreshPolicy.intervals, id: \.self) { interval in
                                    Text(Duration.seconds(interval).formatted(.units(allowed: [.hours, .minutes], width: .wide)))
                                        .tag(interval)
                                }
                            }
                            .frame(maxWidth: 240)
                        }
                        .disabled(!isApplied(share))
                        if let status = shareStatus(share), status.scanning {
                            Text("Indexing… \(status.count.formatted()) objects")
                                .font(.caption).foregroundStyle(.secondary)
                        } else if let status = shareStatus(share), status.queued {
                            Text("Refresh queued")
                                .font(.caption).foregroundStyle(.secondary)
                        } else if let refreshed = shareStatus(share)?.lastRefreshed {
                            Text("Last refreshed \(refreshed.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Button("Add Network Volume…") { addNetworkVolume() }
                if let shareNotice {
                    Text(shareNotice).font(.caption).foregroundStyle(.orange)
                }
            } header: {
                Text("Network volumes")
            } footer: {
                // Scheduling values come from NetworkShareRefreshPolicy; progress
                // and completion dates above come from IndexActor's scan status.
                Text("Mounted volumes refresh in the background on this schedule and after reconnecting. Pausing stops automatic refresh; Refresh runs one scan. Cached files stay searchable while a volume is offline. Apply changes before managing a newly added volume.")
                    .font(.caption).foregroundStyle(.secondary)
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
        .onAppear {
            volumes = Self.localVolumes()
            mountedShares = MountTable.networkMounts()
            loadRefreshPolicies()
        }
        .onChange(of: model.shares) { mountedShares = MountTable.networkMounts() }
        .onChange(of: model.rules.networkShares) { loadRefreshPolicies() }
    }

    private func mountPath(of share: NetworkShare) -> String? {
        mountedShares.first { $0.source == share.source }?.path
    }

    private func shareStatus(_ share: NetworkShare) -> NetworkShareStatus? {
        model.shares.first { $0.share.source == share.source }
    }

    private func isApplied(_ share: NetworkShare) -> Bool {
        model.rules.networkShares.contains { $0.source == share.source }
    }

    private func loadRefreshPolicies() {
        Task {
            for share in model.rules.networkShares {
                refreshPolicies[share.source] = await model.index.currentShareRefreshPolicy(for: share)
            }
        }
    }

    private func updatePolicy(_ policy: NetworkShareRefreshPolicy, for share: NetworkShare) {
        refreshPolicies[share.source] = policy
        Task { await model.index.setShareRefreshPolicy(policy, for: share) }
    }

    private func pauseBinding(_ share: NetworkShare) -> Binding<Bool> {
        Binding(get: { (refreshPolicies[share.source] ?? NetworkShareRefreshPolicy()).paused }, set: { paused in
            let previous = refreshPolicies[share.source] ?? NetworkShareRefreshPolicy()
            updatePolicy(NetworkShareRefreshPolicy(paused: paused, interval: previous.interval), for: share)
        })
    }

    private func intervalBinding(_ share: NetworkShare) -> Binding<TimeInterval> {
        Binding(get: { (refreshPolicies[share.source] ?? NetworkShareRefreshPolicy()).interval }, set: { interval in
            let previous = refreshPolicies[share.source] ?? NetworkShareRefreshPolicy()
            updatePolicy(NetworkShareRefreshPolicy(paused: previous.paused, interval: interval), for: share)
        })
    }

    private func shareDetail(_ share: NetworkShare) -> String {
        if let p = mountPath(of: share) { return share.source + "  ·  " + p }
        return share.source + "  ·  not mounted"
    }

    private func refreshMounts(after seconds: Double = 0) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { mountedShares = MountTable.networkMounts() }
    }

    // Picking a share (or any folder on it) in the panel mounts it, exactly like
    // Finder. The whole share is indexed: a folder inside it just identifies it.
    private func addNetworkVolume() {
        let panel = NSOpenPanel()
        panel.title = "Add Network Volume"
        panel.message = "Choose a network volume, or any folder on it. The whole volume will be indexed."
        panel.prompt = "Add"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Volumes")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let mount = MountTable.networkMount(containing: url.path) else {
            shareNotice = "\(url.lastPathComponent) is on a local volume."
            return
        }
        let share = NetworkShare(mount: mount)
        if !edit.networkShares.contains(where: { $0.source == share.source }) {
            edit.networkShares.append(share)
        }
        shareNotice = url.path == mount.path ? nil
            : "Added the whole volume \"\(share.name)\" that contains \(url.lastPathComponent)."
        refreshMounts()
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
