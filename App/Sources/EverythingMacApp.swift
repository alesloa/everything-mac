import SwiftUI
import AppKit

@main
struct EverythingMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()
    var body: some Scene {
        WindowGroup("Everything-Mac") {
            ContentView().environmentObject(model)
                .frame(minWidth: 800, minHeight: 500)
                .onAppear {
                    appDelegate.model = model
                    model.bootstrap()
                }
        }
        .commands { AppCommands(model: model) }
        Settings {
            SettingsView().environmentObject(model)
        }
    }
}
