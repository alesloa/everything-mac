import SwiftUI
import AppKit
import IndexCore

@MainActor
final class ContentSearchModel: ObservableObject {
    @Published var literal = ""
    @Published var useFilenameQuery: Bool
    @Published var pickedFolderPath: String?
    @Published var options = ContentSearchOptions()
    @Published private(set) var progress = ContentSearchProgress()
    @Published private(set) var isRunning = false
    @Published private(set) var query: Query?
    @Published private(set) var folderPath: String?
    @Published private(set) var folderSelection: FolderSearchScope?
    private let index: SearchIndex
    private let selectedPaths: [String]
    private var task: Task<Void, Never>?
    private var generation = UUID()

    init(index: SearchIndex, query: Query?, selectedPaths: [String], folderPath: String? = nil,
         folderSelection: FolderSearchScope? = nil) {
        self.index = index; self.selectedPaths = selectedPaths; self.folderPath = folderPath
        self.folderSelection = folderSelection
        let validQuery = query?.validationError == nil ? query : nil
        self.query = validQuery
        useFilenameQuery = validQuery != nil
    }

    func updateScope(query: Query?, folderPath: String? = nil, folderSelection: FolderSearchScope? = nil) {
        guard self.query != query || !Self.samePath(self.folderPath, folderPath)
                || self.folderSelection != folderSelection else { return }
        cancel()
        progress = ContentSearchProgress()
        self.query = query?.validationError == nil ? query : nil
        self.folderPath = folderPath
        self.folderSelection = folderSelection
        if self.query == nil { useFilenameQuery = false }
    }

    func start() {
        cancel()
        let run = UUID(); generation = run
        progress = ContentSearchProgress(); isRunning = true
        let request = ContentSearchRequest(literal: literal, filenameQuery: query,
            restrictToFilenameQuery: useFilenameQuery, folderPath: folderPath,
            pickedFolderPath: pickedFolderPath, folderSelection: folderSelection, options: options)
        let updates = ContentSearchService.events(index: index, request: request)
        task = Task { [weak self] in
            for await update in updates {
                guard !Task.isCancelled, let self, self.generation == run else { break }
                self.progress = update
                if update.finished { self.isRunning = false }
            }
        }
    }

    func cancel() {
        generation = UUID(); task?.cancel(); task = nil; isRunning = false
    }

    private static func samePath(_ lhs: String?, _ rhs: String?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): true
        case (let a?, let b?): a.utf8.elementsEqual(b.utf8)
        default: false
        }
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        // Source: the owner's requested explicit folder scope.
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if let path = pickedFolderPath ?? folderSelection?.included.first?.path ?? folderPath ?? selectedPaths.first {
            panel.directoryURL = URL(fileURLWithPath: path).deletingLastPathComponent()
        }
        panel.begin { [weak self] result in
            guard result == .OK, let url = panel.url else { return }
            Task { @MainActor in self?.pickedFolderPath = url.path }
        }
    }
}
