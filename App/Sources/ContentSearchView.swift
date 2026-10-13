import SwiftUI
import IndexCore

struct ContentSearchView: View {
    @StateObject private var model: ContentSearchModel
    private let query: Query?
    private let folderPath: String?
    private let folderSelection: FolderSearchScope?

    init(index: SearchIndex, query: Query?, selectedPaths: [String] = [], folderPath: String? = nil,
         folderSelection: FolderSearchScope? = nil) {
        self.query = query; self.folderPath = folderPath
        self.folderSelection = folderSelection
        _model = StateObject(wrappedValue: ContentSearchModel(index: index, query: query,
            selectedPaths: selectedPaths, folderPath: folderPath, folderSelection: folderSelection))
    }

    // Source: all fixed labels describe the owner's content-search request,
    // ContentSearchOptions bounds, or formats implemented in ContentSearchReader.
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Search file contents").font(.title2)
            Text("UTF-8 and BOM-marked UTF-16 text, source files, HTML as text, and PDF text. iCloud files, dataless files, and symbolic links are skipped.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                TextField("Literal text", text: $model.literal).textFieldStyle(.roundedBorder)
                    .disabled(model.isRunning)
                    .onSubmit { if !model.isRunning && !model.literal.isEmpty { model.start() } }
                Button(model.isRunning ? "Cancel" : "Search") {
                    if model.isRunning { model.cancel() } else { model.start() }
                }.disabled(!model.isRunning && model.literal.isEmpty)
            }
            controls.disabled(model.isRunning)
            status
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(model.progress.results) { hit in
                        VStack(alignment: .leading, spacing: 4) {
                            // Source: the actual FileStore path, unchanged read
                            // descriptor's literal count, and extracted file text.
                            Text(hit.path).font(.headline).textSelection(.enabled)
                            Text("Occurrences: \(hit.occurrenceCount.formatted())")
                                .font(.caption).foregroundStyle(.secondary)
                            Text(hit.excerpt).font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                        }
                        Divider()
                    }
                    ForEach(model.progress.errors) { error in
                        // Source: candidate path and caught filesystem error.
                        Text(error.path + "\n" + error.message).font(.callout).textSelection(.enabled)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(20).frame(minWidth: 620, minHeight: 520)
        .onDisappear { model.cancel() }
        .onChange(of: query) { _, new in
            model.updateScope(query: new, folderPath: folderPath, folderSelection: folderSelection)
        }
        .onChange(of: folderPath.map { Array($0.utf8) }) { _, _ in
            model.updateScope(query: query, folderPath: folderPath, folderSelection: folderSelection)
        }
        .onChange(of: folderSelection) { _, new in
            model.updateScope(query: query, folderPath: folderPath, folderSelection: new)
        }
    }

    // Source: scope values are the supplied validated Query, actual indexed
    // folder path and the folder URL explicitly selected in NSOpenPanel.
    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Within current filename query", isOn: $model.useFilenameQuery)
                .disabled(model.query == nil)
            if model.useFilenameQuery, let query = model.query {
                Text(query.text).font(.caption).textSelection(.enabled)
            }
            if let selection = model.folderSelection {
                FolderSearchScopeDetails(selection: selection)
            } else if let scope = model.folderPath {
                Text(scope).font(.caption).textSelection(.enabled)
            }
            HStack {
                Button("Choose folder…") { model.chooseFolder() }
                if let picked = model.pickedFolderPath {
                    Text(picked).font(.caption).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    Button("Clear") { model.pickedFolderPath = nil }
                }
                Spacer()
                Picker("Formats", selection: $model.options.fileKind) {
                    Text("All supported").tag(ContentSearchFileKind.all)
                    Text("Text / source / HTML").tag(ContentSearchFileKind.text)
                    Text("PDF").tag(ContentSearchFileKind.pdf)
                }.frame(width: 220)
            }
            HStack {
                Toggle("Ignore case", isOn: $model.options.caseInsensitive)
                Toggle("Ignore accents", isOn: $model.options.diacriticInsensitive)
                Toggle("Allow network file reads", isOn: $model.options.allowsNetwork)
            }
            HStack {
                Stepper("File limit: \((model.options.maxFileBytes / 1_024 / 1_024).formatted()) MiB",
                        value: megabyteLimit, in: 1...512)
                Stepper("Workers: \(model.options.concurrency.formatted())", value: $model.options.concurrency, in: 1...8)
                Stepper("PDF pages: \(model.options.maxPDFPages.formatted())", value: $model.options.maxPDFPages, in: 1...2_000)
            }.font(.caption)
            Stepper("Result limit: \(model.options.maxResults.formatted())", value: $model.options.maxResults, in: 100...100_000, step: 100)
                .font(.caption)
        }
    }

    private var megabyteLimit: Binding<Int> {
        Binding(get: { model.options.maxFileBytes / 1_024 / 1_024 },
                set: { model.options.maxFileBytes = $0 * 1_024 * 1_024 })
    }

    // Source: every displayed number is a count/byte total from this scan's
    // ContentSearchProgress; validation and filesystem messages come from errors.
    private var status: some View {
        VStack(alignment: .leading, spacing: 4) {
            if model.isRunning {
                ProgressView(value: Double(model.progress.completed), total: Double(max(1, model.progress.candidates)))
            }
            Text("Completed: \(model.progress.completed.formatted()) / \(model.progress.candidates.formatted()) · Searched: \(model.progress.searched.formatted()) · Skipped: \(model.progress.skipped.formatted())")
                .font(.caption)
            Text("Matching files: \(model.progress.matchingFiles.formatted()) · Shown: \(model.progress.results.count.formatted()) · Bytes read: \(model.progress.bytesRead.formatted())")
                .font(.caption)
            if let error = model.progress.failure { Text(error).foregroundStyle(.red).textSelection(.enabled) }
        }
    }
}
