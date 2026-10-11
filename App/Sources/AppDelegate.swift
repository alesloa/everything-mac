import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static private(set) var isTerminating = false
    weak var model: AppModel?
    private var backgroundModel: AppModel?
    private var globalAccess: GlobalAccessController?
    private var restoredSearchWindows = false

    func restoreSearchWindowsIfNeeded(library: WorkspaceLibrary,
                                     open: @MainActor (String) -> Void) {
        guard !restoredSearchWindows else { return }
        restoredSearchWindows = true
        for id in library.unclaimedWindowIDs { open(id) }
    }

    func configureGlobalAccess(model: AppModel, preferences: GlobalAccessPreferences = .shared,
                               registrar: any GlobalHotKeyRegistering = CarbonGlobalHotKey(),
                               openSearchWindow: @escaping @MainActor () -> Void,
                               openSettings: @escaping @MainActor () -> Void) {
        guard globalAccess == nil else { return }
        backgroundModel = model
        globalAccess = GlobalAccessController(model: model, preferences: preferences, registrar: registrar,
                                             openSearchWindow: openSearchWindow, openSettings: openSettings)
    }

    func updateActiveModel(_ model: AppModel) { self.model = model }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        globalAccess?.showSearch()
        return globalAccess == nil
    }

    func applicationWillTerminate(_ notification: Notification) {
        Self.isTerminating = true
        for window in SearchWindowRegistry.shared.windows {
            SearchWindowRegistry.shared.model(for: window)?.persistWorkspace()
        }
        backgroundModel?.workspace.library.flush()
        globalAccess?.shutdown()
        guard let index = (backgroundModel ?? model)?.index else { return }
        let sem = DispatchSemaphore(value: 0)
        Task.detached {
            await index.flush()
            sem.signal()
        }
        // The index flush has a bounded wait so quitting cannot hang on a scan.
        _ = sem.wait(timeout: .now() + 5)
    }
}
