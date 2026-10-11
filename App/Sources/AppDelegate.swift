import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?

    func applicationWillTerminate(_ notification: Notification) {
        guard let index = model?.index else { return }
        let sem = DispatchSemaphore(value: 0)
        Task.detached {
            await index.flush()
            sem.signal()
        }
        // The index flush has a bounded wait so quitting cannot hang on a scan.
        _ = sem.wait(timeout: .now() + 5)
    }
}
