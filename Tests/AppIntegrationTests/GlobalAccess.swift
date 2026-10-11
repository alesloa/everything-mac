import AppKit
import Carbon
import SwiftUI
import IndexCore

@MainActor
private final class MockRegistrar: GlobalHotKeyRegistering {
    var onTrigger: (@MainActor () -> Void)?
    var bindings: [GlobalShortcutBinding?] = []
    var status: OSStatus = noErr
    func replace(with binding: GlobalShortcutBinding?) -> OSStatus {
        bindings.append(binding)
        return binding == nil ? noErr : status
    }
}

@main
struct GlobalAccessTests {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let suite = "global-access-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = GlobalAccessPreferences(defaults: defaults)
        precondition(preferences.showMenuBarItem && !preferences.shortcutEnabled && preferences.shortcut == nil)
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.control, .option], timestamp: 0,
                                    windowNumber: 0, context: nil, characters: "j", charactersIgnoringModifiers: "j",
                                    isARepeat: false, keyCode: UInt16(kVK_ANSI_J))!
        let binding = GlobalShortcutBinding.capture(event)!
        precondition(binding.displayName == "⌃⌥J" && binding.keyCode == UInt32(kVK_ANSI_J))
        let bareKey = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                      windowNumber: 0, context: nil, characters: "j", charactersIgnoringModifiers: "j",
                                      isARepeat: false, keyCode: UInt16(kVK_ANSI_J))!
        precondition(GlobalShortcutBinding.capture(bareKey) == nil, "A plain typing key must not become a global shortcut")
        precondition(!GlobalShortcutBinding(keyCode: UInt32(kVK_Command), modifiers: UInt32(cmdKey), keyLabel: "⌘").isValid)

        let registrar = MockRegistrar()
        var triggerCount = 0
        let registration = GlobalShortcutRegistration(preferences: preferences, registrar: registrar) { triggerCount += 1 }
        precondition(registrar.bindings.last! == nil)
        preferences.setShortcut(binding)
        precondition(registrar.bindings.last! == binding && preferences.registrationStatus == nil)
        registrar.onTrigger?()
        precondition(triggerCount == 1)
        preferences.recordingShortcut = true
        precondition(registrar.bindings.last! == nil, "Recording must temporarily release the old shortcut")
        preferences.recordingShortcut = false
        precondition(registrar.bindings.last! == binding)
        registrar.status = OSStatus(eventHotKeyExistsErr)
        preferences.shortcutEnabled = false
        preferences.shortcutEnabled = true
        precondition(preferences.registrationStatus == OSStatus(eventHotKeyExistsErr))
        precondition(GlobalAccessCopy.registrationError(OSStatus(eventHotKeyExistsErr)).contains(String(eventHotKeyExistsErr)))
        let restored = GlobalAccessPreferences(defaults: defaults)
        precondition(restored.shortcut == binding && restored.shortcutEnabled)
        registration.shutdown()
        precondition(registrar.bindings.last! == nil && registrar.onTrigger == nil)
        preferences.clearShortcut()

        // Exercise native ownership/collision paths with uncommon modifier combinations; no synthesized keystrokes are sent.
        let first = CarbonGlobalHotKey()
        let second = CarbonGlobalHotKey()
        let nativeBinding = GlobalShortcutBinding(keyCode: UInt32(kVK_F19),
                                                 modifiers: UInt32(controlKey | optionKey | cmdKey), keyLabel: "F19")
        let alternateBinding = GlobalShortcutBinding(keyCode: UInt32(kVK_F18),
                                                    modifiers: UInt32(controlKey | optionKey | cmdKey), keyLabel: "F18")
        precondition(first.replace(with: nativeBinding) == noErr, "The native hotkey must register")
        let collision = second.replace(with: nativeBinding)
        precondition(collision != noErr, "A duplicate native registration must surface an OSStatus error")
        precondition(first.replace(with: alternateBinding) == noErr)
        precondition(second.replace(with: nativeBinding) == noErr, "Replacing a binding must release its old key")
        precondition(second.replace(with: nil) == noErr)
        precondition(first.replace(with: nil) == noErr)

        let model = AppModel(index: IndexActor(rules: .defaults), preferences: defaults)
        model.total = 73
        preferences.showMenuBarItem = false
        var opened = 0
        var settingsOpened = 0
        let controller = GlobalAccessController(model: model, preferences: preferences, registrar: MockRegistrar(),
                                                openSearchWindow: { opened += 1 }, openSettings: { settingsOpened += 1 })
        precondition(!controller.hasMenuBarItem)
        preferences.showMenuBarItem = true
        precondition(controller.hasMenuBarItem)
        preferences.showMenuBarItem = false
        precondition(!controller.hasMenuBarItem)
        controller.showSearch()
        precondition(opened == 1, "An app with no search windows must request a new window")

        let window = NSWindow(contentRect: NSRect(x: 40, y: 40, width: 300, height: 200),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let windowRegistration = GlobalAccessWindowRegistration.RegistrationView(model: model)
        window.contentView = windowRegistration
        precondition(SearchWindowRegistry.shared.model(for: window) === model)
        let oldSignal = model.focusSearchSignal
        controller.showSearch()
        precondition(opened == 1 && model.focusSearchSignal == oldSignal + 1 && window.isVisible)
        controller.toggleSearch()
        precondition(!window.isVisible, "Hide must order out the registered search window")
        controller.showSearch()
        precondition(window.isVisible && opened == 1, "Showing a hidden search must reuse it")
        controller.newSearchWindow()
        precondition(opened == 2)
        window.close()
        precondition(SearchWindowRegistry.shared.model(for: window) == nil, "Closed windows must leave the registry")
        controller.showSearch()
        precondition(opened == 3)
        let menu = NSMenu()
        controller.menuNeedsUpdate(menu)
        precondition(menu.items.contains { $0.title == "73 objects indexed" && !$0.isEnabled })
        model.scanning = true
        controller.menuNeedsUpdate(menu)
        precondition(menu.items.contains { $0.title == "Indexing… 73 objects" })
        controller.shutdown()

        let delegate = AppDelegate()
        precondition(!delegate.applicationShouldTerminateAfterLastWindowClosed(NSApp))
        var retainedModel: AppModel? = AppModel(index: model.index, preferences: defaults)
        weak var backgroundReference = retainedModel
        delegate.configureGlobalAccess(model: retainedModel!, preferences: preferences, registrar: MockRegistrar(),
                                       openSearchWindow: { opened += 1 }, openSettings: { settingsOpened += 1 })
        retainedModel = nil
        precondition(backgroundReference != nil, "Background indexing must outlive the last search window")
        backgroundReference = nil
        delegate.updateActiveModel(model)
        precondition(delegate.model === model)
        let beforeReopen = opened
        precondition(!delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false))
        precondition(opened == beforeReopen + 1, "Dock reopen must create a search when the final window closed")
        print("PASS: recorded shortcuts, real native collisions/replacement, menu-bar toggles, and background window lifecycle")
    }
}
