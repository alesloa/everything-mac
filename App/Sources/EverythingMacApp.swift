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

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?

    func applicationWillTerminate(_ notification: Notification) {
        guard let index = model?.index else { return }
        let sem = DispatchSemaphore(value: 0)
        Task.detached {
            await index.flush()
            sem.signal()
        }
        // Bounded wait so a slow flush (large index) or an actor busy mid-scan
        // can't hang the quit. Correctness holds either way: the next launch
        // replays FSEvents since the last successful flush.
        _ = sem.wait(timeout: .now() + 5)
    }
}
