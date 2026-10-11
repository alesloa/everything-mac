import AppKit
import SwiftUI
import IndexCore

@main struct SearchFiltersTests {
    @MainActor static func main() {
        Task { @MainActor in
            do { try await run(); print("PASS: multi-type and size filters search, persist, restore and clear without changing the entered query"); exit(EXIT_SUCCESS) }
            catch { print("FAIL: \(error.localizedDescription)"); exit(EXIT_FAILURE) }
        }
        NSApplication.shared.run()
    }

    @MainActor private static func run() async throws {
        let suite = "EverythingMac.SearchFilters.\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { preferences.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        var store = FileStore()
        let root = store.append(name: directory.path, parent: FileStore.noParent, size: 0, mtime: 0, isDir: true, volID: 1)
        for (name, size) in [("report.jpg", UInt64(700_000_000)), ("report.mp4", 1_500_000_000),
                             ("report.pdf", 700_000_000), ("report-small.jpg", 500_000_000), ("report-big.mp4", 2_000_000_000)] {
            store.append(name: name, parent: root, size: size, mtime: 0, isDir: false, volID: 1)
        }
        let fixture = store
        let index = IndexActor(rules: .defaults, preferencesSuiteName: suite,
            cacheURL: directory.appendingPathComponent("index.idx"), diskScanner: { _, _, _ in fixture }, networkMounts: { [] })
        try require(await index.rescanAll(), "Fixture scan failed")
        let model = AppModel(index: index, preferences: preferences)
        model.workspace.activate(defaultState: SearchWorkspaceState())
        model.query = "report"; model.fuzzy = false
        model.setSearchFilter(.files)
        model.toggleSearchFilter(.images)
        try require(model.searchFilters.types == [.images], "Selecting Images left the broad Files filter active")
        let filters = SearchFilters(types: [.images, .video], over: SearchSizeLimit(amount: "500"),
            under: SearchSizeLimit(amount: "2", unit: .gigabytes))
        model.setSearchFilters(filters)
        try await waitUntil { model.totalMatches == 2 }
        try require(Set(model.results.map(\.name)) == ["report.jpg", "report.mp4"] && model.query == "report",
                    "Filter union, strict range or entered query changed")
        let saved = try model.saveCurrentSearch(name: "Large media", isCustomFilter: true)
        try require(saved.state.effectiveFilters == filters, "Saved search dropped size/type choices")
        let originalTab = model.workspace.window.selectedTabID
        model.newSearchTab()
        model.setSearchFilters(SearchFilters(under: SearchSizeLimit(amount: "500")))
        model.selectSearchTab(originalTab)
        try require(model.searchFilters == filters, "Tab selection did not restore complete filters")
        let fresh = AppModel(index: index, preferences: preferences)
        model.savePrefs(); fresh.loadPrefs()
        try require(fresh.searchFilters == filters, "Preference reload dropped filters")
        model.setSearchFilters(SearchFilters(over: SearchSizeLimit(amount: "invalid")))
        try require(model.searchFilters == filters, "Invalid size replaced the valid filter")
        model.setSearchFilters(SearchFilters())
        try await waitUntil { model.totalMatches == 5 }
        try require(model.query == "report" && model.searchFilters.isEmpty, "Clearing filters erased the query")
        model.openSavedSearch(saved)
        try await waitUntil { model.totalMatches == 2 }
        try require(model.searchFilters == filters, "Opening bookmark did not restore filters")
        model.setSearchFilters(SearchFilters(), customFilterID: saved.id)
        model.toggleSearchFilter(.documents)
        try require(model.workspaceSnapshot.customFilterID == saved.id, "Menu type toggle discarded the saved filter")
        try require(model.filterSummary(for: model.workspaceSnapshot).contains(saved.name), "Active saved-filter name missing from summary")
        model.setSearchFilters(SearchFilters())

        // Render real SwiftUI/AppKit controls with fixture values, without operating
        // the owner's application or using its preferences or file paths.
        model.setSearchFilters(filters)
        try await capturePopover(model, to: "/tmp/everything-search-filters-popover.png")
        model.searchFilters = SearchFilters(types: filters.types, over: filters.over, under: SearchSizeLimit(amount: "400"))
        try await capturePopover(model, to: "/tmp/everything-search-filters-invalid.png")
        model.searchFilters = filters
        model.workspace.library.flush()
        let library = WorkspaceLibrary(preferences: preferences)
        try require(library.archive.savedSearches.first?.state.effectiveFilters == filters, "Archive reload dropped bookmark filters")
    }

    @MainActor private static func capturePopover(_ model: AppModel, to path: String) async throws {
        let view = NSHostingView(rootView: SearchFiltersPopover(model: model, workspace: model.workspace, close: {})
            .background(Color(nsColor: .windowBackgroundColor)))
        view.frame = NSRect(origin: .zero, size: view.fittingSize)
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view
        window.orderFront(nil)
        try await Task.sleep(for: .milliseconds(100))
        view.layoutSubtreeIfNeeded()
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-x", "-l", String(window.windowNumber), path]
        try capture.run(); capture.waitUntilExit()
        try require(capture.terminationStatus == 0, "Native filter window capture failed")
        window.close()
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw NSError(domain: "SearchFiltersTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    @MainActor private static func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<1000 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        try require(false, "Timed out waiting for filtered results")
    }
}
