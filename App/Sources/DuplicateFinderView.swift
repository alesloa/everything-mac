import AppKit
import SwiftUI
import IndexCore

struct DuplicateFinderView: View {
    let index: SearchIndex
    let query: Query?
    let selectedPaths: [String]
    var folderPath: String? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var model = DuplicateFinderModel()
    @State private var scope: Scope = .query
    @State private var method: Method = .contents
    @State private var folder: String?
    @State private var otherFolder: String?
    @State private var allowsNetwork = false
    @State private var allowsCloud = false

    private enum Scope: Hashable { case selection, query, folder, comparison }
    private enum Method: Hashable { case nameAndSize, contents }

    // Source: labels below name the duplicate and folder-comparison actions requested
    // by the owner; file paths, sizes, hashes and counts come from DuplicateFinder reports.
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Duplicate Files").font(.title2.bold())
            Picker("Scope", selection: $scope) {
                Text("Selected files").tag(Scope.selection)
                Text("Current query").tag(Scope.query)
                Text("Folder").tag(Scope.folder)
                Text("Compare folders").tag(Scope.comparison)
            }.pickerStyle(.segmented).disabled(model.running)
            if scope == .selection {
                Text("\(selectedPaths.count) selected paths").font(.caption).foregroundStyle(.secondary)
            } else if scope == .query {
                if let query {
                    Text(query.text).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    if let error = query.validationError { Text(error.localizedDescription).foregroundStyle(.red) }
                }
                Text("Uses every matching file in the captured index snapshot.")
                    .font(.caption).foregroundStyle(.secondary)
                if let folderPath { Text(folderPath).font(.caption).textSelection(.enabled) }
            } else {
                folderPicker("Folder", path: $folder)
                if scope == .comparison { folderPicker("Compare with", path: $otherFolder) }
            }
            if scope != .comparison {
                Picker("Check", selection: $method) {
                    Text("Same name and size").tag(Method.nameAndSize)
                    Text("SHA-256 contents").tag(Method.contents)
                }.pickerStyle(.segmented).disabled(model.running)
                Text(method == .contents
                     ? "Checks actual sizes first, then hashes matching-size files. Results describe files at verification time."
                     : "Groups actual names and sizes. These candidates may contain different contents.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Toggle("Include network files", isOn: $allowsNetwork)
                Toggle("Include downloaded iCloud files", isOn: $allowsCloud)
            }.font(.caption).disabled(model.running)
            progressView
            Divider()
            resultView.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            HStack {
                Spacer()
                Button("Close") { model.stop(); dismiss() }.keyboardShortcut(.cancelAction)
                if model.running { Button("Cancel Check") { model.cancel() } }
                else {
                    Button(scope == .comparison ? "Compare" : "Find Duplicates", action: run)
                        .keyboardShortcut(.defaultAction).disabled(!canRun)
                }
            }
        }
        .padding(20).frame(width: 800, height: 640)
        .onAppear { if !selectedPaths.isEmpty { scope = .selection } }
        .onDisappear { model.stop() }
    }

    private var canRun: Bool {
        switch scope {
        case .selection: !selectedPaths.isEmpty
        case .query: query != nil && query?.validationError == nil
        case .folder: folder != nil
        case .comparison: folder != nil && otherFolder != nil
        }
    }

    private func folderPicker(_ label: String, path: Binding<String?>) -> some View {
        HStack {
            Text(label).frame(width: 95, alignment: .leading)
            Text(path.wrappedValue ?? "").lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Choose…") {
                let panel = NSOpenPanel()
                panel.canChooseFiles = false; panel.canChooseDirectories = true
                panel.allowsMultipleSelection = false
                if panel.runModal() == .OK { path.wrappedValue = panel.url?.path }
            }.disabled(model.running)
        }
    }

    @ViewBuilder private var progressView: some View {
        if let progress = model.progress, model.running {
            HStack {
                ProgressView().controlSize(.small)
                Text(phaseLabel(progress.phase))
                Spacer()
                Text("\(progress.inspectedFiles) inspected · \(progress.hashedFiles)/\(progress.hashCandidates) hashed · \(progress.bytesRead) bytes read")
                    .monospacedDigit()
            }.font(.caption)
        }
    }

    @ViewBuilder private var resultView: some View {
        if let report = model.report {
            VStack(alignment: .leading, spacing: 10) {
                Text(report.cancelled ? "Check cancelled" : "\(report.groups.count) groups · \(report.inspectedFiles) files inspected · \(report.hashedFiles) files hashed")
                    .font(.callout).monospacedDigit()
                if !report.cancelled, report.groups.isEmpty { Text("No matching groups in this check.").foregroundStyle(.secondary) }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(report.groups) { group in
                            VStack(alignment: .leading, spacing: 6) {
                                Text("\(group.files.count) files · \(group.size) bytes each").font(.headline)
                                if let digest = group.sha256 {
                                    Text("SHA-256: \(digest)").font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                                }
                                ForEach(group.files) { file in
                                    pathRow(file.path, detail: file.modificationDate.formatted())
                                }
                            }
                        }
                        skippedView(report.skipped)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        } else if let comparison = model.comparison {
            VStack(alignment: .leading, spacing: 10) {
                Text(comparison.cancelled ? "Comparison cancelled" : "\(comparison.entries.count) relative paths · \(comparison.inspectedFiles) files inspected · \(comparison.hashedFiles) files hashed")
                    .font(.callout).monospacedDigit()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(comparison.entries) { entry in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(entry.relativePath).font(.headline).textSelection(.enabled)
                                    Spacer()
                                    Text(statusLabel(entry.status)).font(.caption).foregroundStyle(.secondary)
                                }
                                if let path = entry.leftPath { pathRow(path, detail: entry.leftSize.map { "\($0) bytes" }) }
                                if let path = entry.rightPath { pathRow(path, detail: entry.rightSize.map { "\($0) bytes" }) }
                                if let digest = entry.sha256 {
                                    Text("SHA-256: \(digest)").font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                                }
                            }
                        }
                        skippedView(comparison.skipped)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func pathRow(_ path: String, detail: String?) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(path).font(.caption).textSelection(.enabled)
                if let detail { Text(detail).font(.caption2).foregroundStyle(.secondary) }
            }
            Spacer()
            Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                .controlSize(.small)
        }
    }

    @ViewBuilder private func skippedView(_ skipped: [DuplicateSkippedFile]) -> some View {
        if !skipped.isEmpty {
            DisclosureGroup("\(skipped.count) skipped entries") {
                LazyVStack(alignment: .leading) {
                    ForEach(skipped.indices, id: \.self) { index in
                        Text("\(skipped[index].path) — \(skipLabel(skipped[index].reason))")
                            .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
            }
        }
    }

    private func run() {
        let options = DuplicateOptions(allowsNetwork: allowsNetwork, allowsDownloadedCloudFiles: allowsCloud)
        let check: DuplicateMethod = method == .contents ? .contents : .nameAndSize
        switch scope {
        case .selection: model.find(.paths(selectedPaths), method: check, options: options)
        case .query:
            guard let query, query.validationError == nil else { return }
            model.find(.query(snapshot: index.readSnapshot(), query: query, folderPath: folderPath), method: check, options: options)
        case .folder:
            guard let folder else { return }
            model.find(.folder(folder), method: check, options: options)
        case .comparison:
            guard let folder, let otherFolder else { return }
            model.compare(folder, otherFolder, options: options)
        }
    }

    private func phaseLabel(_ phase: DuplicateProgress.Phase) -> String {
        switch phase {
        case .inspecting: "Inspecting files"
        case .hashing: "Hashing contents"
        case .validating: "Revalidating files"
        case .finished: "Finished"
        }
    }

    private func statusLabel(_ status: FolderComparisonEntry.Status) -> String {
        switch status {
        case .sameContents: "SHA-256 verified match"
        case .differentContents: "Different contents"
        case .onlyLeft: "Only in first folder"
        case .onlyRight: "Only in second folder"
        case .unverified: "Unverified"
        }
    }

    private func skipLabel(_ reason: DuplicateSkipReason) -> String {
        switch reason {
        case .unavailable: "Unavailable"
        case .symbolicLink: "Symbolic link"
        case .specialFile: "Not a regular file"
        case .network: "Network file excluded"
        case .cloud: "Cloud file excluded or not downloaded"
        case .changed: "Changed or unavailable during verification"
        }
    }
}
