import SwiftUI
import AppKit
import UniformTypeIdentifiers
import IndexCore

/// Static control labels implement the owner's requested import, catalog scope,
/// mapping and export feature. Row labels/metadata come from validated imported
/// documents or a native immutable index snapshot; missing metadata stays blank.
struct CatalogBrowserView: View {
    @Bindable var store: CatalogStore
    @State private var exportFormat: CatalogFormat = .efu
    @State private var exportScope: CatalogExportScope = .allMatching
    @State private var sourcePrefix = ""
    @State private var mappingCatalogID: UUID?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("File catalogs").font(.title2)
                Spacer()
                Button("Import…", action: importCatalog).disabled(store.isWorking)
                Button("Done") { dismiss() }
            }
            HStack {
                Picker("Scope", selection: $store.scope) {
                    ForEach(CatalogSearchScope.allCases) { Text($0.label).tag($0) }
                }.frame(width: 290)
                Picker("Catalog", selection: $store.catalogID) {
                    Text("All catalogs").tag(UUID?.none)
                    ForEach(store.catalogs) { Text($0.name).tag(Optional($0.id)) }
                }
                Button("Remove") { if let id = store.catalogID { store.removeCatalog(id) } }
                    .disabled(store.catalogID == nil || store.isWorking)
            }
            HStack {
                TextField("Search catalogs", text: Binding(get: { store.query.text }, set: { store.query.text = $0 }))
                    .textFieldStyle(.roundedBorder)
                Picker("Sort", selection: $store.sort) { ForEach(CatalogSort.allCases) { Text($0.label).tag($0) } }.frame(width: 170)
                Toggle("Ascending", isOn: $store.ascending).toggleStyle(.checkbox)
                Button("Refresh") { store.search() }
            }
            Table(store.rows, selection: $store.selection) {
                TableColumn("Name") { hit in Text(hit.nativeRecord?.name ?? hit.record.name).lineLimit(1) }
                TableColumn("Path") { hit in Text(hit.record.path).lineLimit(1).help(hit.record.path) }.width(min: 230)
                TableColumn("Source") { hit in Text(sourceName(hit)) }.width(140)
                TableColumn("Size") { hit in
                    if let size = hit.record.size { Text(size.formatted(.number)).monospacedDigit() }
                }.width(100)
                TableColumn("Modified") { hit in
                    if let date = hit.record.modified { Text(date.date.formatted(date: .numeric, time: .shortened)) }
                }.width(160)
            }
            .contextMenu(forSelectionType: CatalogResultID.self) { ids in
                if let hit = store.rows.first(where: { ids.contains($0.id) }) {
                    Button("Open") { store.open(hit) }.disabled(!store.canOpen(hit))
                    Button("Copy path") { copyPath(hit) }
                }
            } primaryAction: { ids in
                if let hit = store.rows.first(where: { ids.contains($0.id) }) { store.open(hit) }
            }
            HStack {
                // These counts come from this search's full match count and
                // displayed hit array, never a guessed progress or wait time.
                Text("\(store.matchCount.formatted()) matches · \(store.rows.count.formatted()) shown")
                    .font(.caption).foregroundStyle(.secondary)
                if store.isSearching || store.isWorking { ProgressView().controlSize(.small) }
                Spacer()
                if store.isWorking { Button("Cancel operation") { store.cancelWork() } }
                Picker("Export", selection: $exportScope) { ForEach(CatalogExportScope.allCases) { Text($0.label).tag($0) } }.frame(width: 220)
                Picker("Format", selection: $exportFormat) { ForEach(CatalogFormat.allCases) { Text($0.label).tag($0) } }.frame(width: 120)
                Button("Export…", action: export).disabled(store.isWorking || (exportScope == .selected && store.selection.isEmpty))
            }
            Divider()
            HStack {
                Picker("Map catalog", selection: $mappingCatalogID) {
                    Text("Choose catalog").tag(UUID?.none)
                    ForEach(store.catalogs) { Text($0.name).tag(Optional($0.id)) }
                }.frame(width: 230)
                TextField("Imported source prefix", text: $sourcePrefix).textFieldStyle(.roundedBorder)
                Button("Choose local folder…", action: mapCatalog).disabled(mappingCatalogID == nil || sourcePrefix.isEmpty)
                Button("Clear mapping") { if let id = mappingCatalogID { store.clearMapping(for: id) } }.disabled(mappingCatalogID == nil)
            }
            if let id = mappingCatalogID, let mapping = store.mappings[id] {
                // Both values are the owner's saved explicit path mapping.
                Text(mapping.sourcePrefix + " → " + mapping.localRoot.path)
                    .font(.caption).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
            // This behavior description is sourced from CatalogPathMapping.resolve
            // and the explicit opening guard in CatalogStore.open.
            Text("Catalog files open only after you map their source prefix to a local folder. All matching exports use source order and include rows beyond the display limit.")
                .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            if let error = store.errorMessage {
                HStack { Text(error).foregroundStyle(.red).textSelection(.enabled); Spacer(); Button("Dismiss") { store.errorMessage = nil } }
            }
        }
        .padding(18).frame(minWidth: 1060, minHeight: 610)
    }
    private func sourceName(_ hit: CatalogSearchHit) -> String {
        // This native label denotes the owner's requested live-index scope.
        hit.nativeRecord != nil ? "Live index" : store.catalogs.first(where: { $0.id == hit.record.id.catalog })?.name ?? ""
    }
    private func importCatalog() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.allowedContentTypes = ["efu", "csv", "txt", "tsv"].compactMap { UTType(filenameExtension: $0) }
        if panel.runModal() == .OK, let url = panel.url { store.importCatalog(url) }
    }
    private func export() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: exportFormat.rawValue)].compactMap { $0 }
        if panel.runModal() == .OK, let url = panel.url { store.export(to: url, format: exportFormat, scope: exportScope) }
    }
    private func mapCatalog() {
        guard let id = mappingCatalogID else { return }
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
        if panel.runModal() == .OK, let url = panel.url { store.setMapping(for: id, prefix: sourcePrefix, root: url) }
    }
    private func copyPath(_ hit: CatalogSearchHit) {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(hit.record.path, forType: .string)
    }
}
