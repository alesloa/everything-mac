import SwiftUI
import AppKit

@main
struct EverythingMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var background = AppModel()
    var body: some Scene {
        WindowGroup("Everything-Mac", id: "search", for: String.self) { windowID in
            SearchWindowRoot(background: background, delegate: appDelegate, windowID: windowID.wrappedValue)
        }
        .commands { FocusedSearchCommands() }
        Settings {
            SearchSettingsRoot(background: background, delegate: appDelegate)
        }
    }
}
