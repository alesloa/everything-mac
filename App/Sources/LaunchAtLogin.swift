import ServiceManagement

// Thin wrapper over SMAppService for the "Open at Login" setting (macOS 13+).
// register()/unregister() are the modern replacement for the deprecated
// SMLoginItemSetEnabled — no helper bundle needed for the main app itself.
enum LaunchAtLogin {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    // Returns the resulting state so the UI can reflect what actually happened
    // (the call can throw — e.g. the app isn't in a location macOS will launch).
    @discardableResult
    static func set(_ enabled: Bool) -> Bool {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            // Silent-skip, matching the engine's error policy: surface the real state
            // back to the toggle rather than throwing up a dialog.
        }
        return isEnabled
    }
}
