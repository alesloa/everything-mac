import AppKit
import SwiftUI
import Combine

@MainActor
final class SearchWindowRegistry {
    static let shared = SearchWindowRegistry()
    private let models = NSMapTable<NSWindow, AppModel>.weakToWeakObjects()

    var windows: [NSWindow] {
        let registered = models.keyEnumerator().allObjects.compactMap { $0 as? NSWindow }
        let ordered = NSApp.orderedWindows.filter { models.object(forKey: $0) != nil }
        return ordered + registered.filter { candidate in !ordered.contains { $0 === candidate } }
    }

    func attach(_ window: NSWindow, model: AppModel) {
        models.setObject(model, forKey: window)
        QuickLookController.shared.registerOwnerWindow(window)
    }
    func detach(_ window: NSWindow) {
        models.removeObject(forKey: window)
        QuickLookController.shared.unregisterOwnerWindow(window)
    }
    func model(for window: NSWindow) -> AppModel? { models.object(forKey: window) }
}

struct GlobalAccessWindowRegistration: NSViewRepresentable {
    let model: AppModel

    func makeNSView(context: Context) -> RegistrationView { RegistrationView(model: model) }
    func updateNSView(_ view: RegistrationView, context: Context) { view.model = model; view.attach() }

    final class RegistrationView: NSView {
        var model: AppModel
        private var closeObserver: AnyCancellable?
        private weak var attachedWindow: NSWindow?

        init(model: AppModel) { self.model = model; super.init(frame: .zero) }
        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); attach() }

        func attach() {
            guard let window else { return }
            if let previous = attachedWindow, previous !== window { SearchWindowRegistry.shared.detach(previous) }
            attachedWindow = window
            SearchWindowRegistry.shared.attach(window, model: model)
            closeObserver = NotificationCenter.default.publisher(for: NSWindow.willCloseNotification, object: window)
                .sink { [weak window] _ in
                    MainActor.assumeIsolated {
                        if let window {
                            if !AppDelegate.isTerminating {
                                SearchWindowRegistry.shared.model(for: window)?.workspace.closeWindow()
                            }
                            SearchWindowRegistry.shared.detach(window)
                        }
                    }
                }
        }
    }
}

@MainActor
final class GlobalAccessController: NSObject, NSMenuDelegate {
    private let preferences: GlobalAccessPreferences
    private let backgroundModel: AppModel
    private let openSearchWindow: @MainActor () -> Void
    private let openSettings: @MainActor () -> Void
    private var item: NSStatusItem?
    private var subscription: AnyCancellable?
    private var shortcuts: GlobalShortcutRegistration?
    var hasMenuBarItem: Bool { item != nil }

    init(model: AppModel, preferences: GlobalAccessPreferences = .shared,
         registrar: any GlobalHotKeyRegistering = CarbonGlobalHotKey(),
         openSearchWindow: @escaping @MainActor () -> Void,
         openSettings: @escaping @MainActor () -> Void) {
        backgroundModel = model
        self.preferences = preferences
        self.openSearchWindow = openSearchWindow
        self.openSettings = openSettings
        super.init()
        shortcuts = GlobalShortcutRegistration(preferences: preferences, registrar: registrar) { [weak self] in
            self?.showSearch()
        }
        subscription = preferences.$showMenuBarItem.sink { [weak self] visible in self?.setMenuBarVisible(visible) }
    }

    private func setMenuBarVisible(_ visible: Bool) {
        if !visible {
            if let item { NSStatusBar.system.removeStatusItem(item) }
            item = nil
            return
        }
        guard item == nil else { return }
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: GlobalAccessCopy.appName)
        statusItem.button?.toolTip = GlobalAccessCopy.appName
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        item = statusItem
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let visible = SearchWindowRegistry.shared.windows.contains { $0.isVisible && !$0.isMiniaturized } && !NSApp.isHidden
        append(menu, title: visible ? GlobalAccessCopy.hide : GlobalAccessCopy.show, action: #selector(toggleSearch))
        append(menu, title: GlobalAccessCopy.newWindow, action: #selector(newSearchWindow))
        menu.addItem(.separator())
        let status = NSMenuItem(title: GlobalAccessCopy.indexStatus(count: backgroundModel.total, scanning: backgroundModel.scanning),
                                action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())
        append(menu, title: GlobalAccessCopy.settings, action: #selector(showSettings))
        append(menu, title: GlobalAccessCopy.quit, action: #selector(quit))
    }

    private func append(_ menu: NSMenu, title: String, action: Selector) {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
        entry.target = self
        menu.addItem(entry)
    }

    func showSearch() {
        if let window = SearchWindowRegistry.shared.windows.first {
            window.deminiaturize(nil)
            window.makeKeyAndOrderFront(nil)
            SearchWindowRegistry.shared.model(for: window)?.focusSearch()
        } else {
            openSearchWindow()
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func toggleSearch() {
        let windows = SearchWindowRegistry.shared.windows
        if windows.contains(where: { $0.isVisible && !$0.isMiniaturized }) && !NSApp.isHidden {
            windows.forEach { $0.orderOut(nil) }
        } else {
            showSearch()
        }
    }

    @objc func newSearchWindow() { openSearchWindow(); NSApp.activate(ignoringOtherApps: true) }
    @objc private func showSettings() { openSettings(); NSApp.activate(ignoringOtherApps: true) }
    @objc private func quit() { NSApp.terminate(nil) }

    func shutdown() {
        subscription = nil
        shortcuts?.shutdown()
        shortcuts = nil
        if let item { NSStatusBar.system.removeStatusItem(item) }
        item = nil
    }
}
