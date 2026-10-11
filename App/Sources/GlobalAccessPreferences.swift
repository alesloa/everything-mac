import AppKit
import Carbon
import Combine

struct GlobalShortcutBinding: Codable, Equatable, Sendable {
    let keyCode: UInt32
    let modifiers: UInt32
    let keyLabel: String

    // Source: the recorded NSEvent and Carbon's modifier constants define the displayed binding.
    var displayName: String {
        var result = ""
        if modifiers & UInt32(controlKey) != 0 { result += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { result += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { result += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { result += "⌘" }
        return result + keyLabel
    }

    var isValid: Bool {
        let allowed = UInt32(controlKey | optionKey | shiftKey | cmdKey)
        let required = UInt32(controlKey | optionKey | cmdKey)
        return keyCode <= UInt32(UInt16.max) && modifiers & ~allowed == 0 && modifiers & required != 0
            && !keyLabel.isEmpty && !Self.modifierKeyCodes.contains(keyCode)
    }

    // Source: Carbon's virtual key constants identify modifier-only events and named keys.
    private static let modifierKeyCodes: Set<UInt32> = [
        UInt32(kVK_Command), UInt32(kVK_Shift), UInt32(kVK_RightShift), UInt32(kVK_CapsLock),
        UInt32(kVK_Option), UInt32(kVK_RightOption), UInt32(kVK_Control), UInt32(kVK_RightControl),
        UInt32(kVK_Function),
    ]

    static func capture(_ event: NSEvent) -> Self? {
        var modifiers: UInt32 = 0
        if event.modifierFlags.contains(.control) { modifiers |= UInt32(controlKey) }
        if event.modifierFlags.contains(.option) { modifiers |= UInt32(optionKey) }
        if event.modifierFlags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        if event.modifierFlags.contains(.command) { modifiers |= UInt32(cmdKey) }
        let code = UInt32(event.keyCode)
        let label: String
        switch Int(event.keyCode) {
        case kVK_Space: label = "Space"
        case kVK_Return: label = "↩"
        case kVK_Tab: label = "⇥"
        case kVK_Delete: label = "⌫"
        case kVK_ForwardDelete: label = "⌦"
        case kVK_LeftArrow: label = "←"
        case kVK_RightArrow: label = "→"
        case kVK_UpArrow: label = "↑"
        case kVK_DownArrow: label = "↓"
        case kVK_Home: label = "↖"
        case kVK_End: label = "↘"
        case kVK_PageUp: label = "⇞"
        case kVK_PageDown: label = "⇟"
        default:
            if let index = functionKeyCodes.firstIndex(of: Int(event.keyCode)) {
                return Self(keyCode: code, modifiers: modifiers, keyLabel: "F\(index + 1)").validated
            }
            guard let characters = event.charactersIgnoringModifiers, !characters.isEmpty,
                  !characters.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
            else { return nil }
            label = characters.uppercased()
        }
        let binding = Self(keyCode: code, modifiers: modifiers, keyLabel: label)
        return binding.validated
    }

    private var validated: Self? { isValid ? self : nil }

    // Source: Carbon's ordered F1–F20 virtual key constants supply function-key names instead of private-use glyphs.
    private static let functionKeyCodes = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7,
                                          kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12, kVK_F13, kVK_F14,
                                          kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20]
}

@MainActor
final class GlobalAccessPreferences: ObservableObject {
    static let shared = GlobalAccessPreferences()

    // Source: these explicit app defaults enable menu-bar access and leave a global binding opt-in.
    @Published var showMenuBarItem: Bool { didSet { defaults.set(showMenuBarItem, forKey: Self.menuBarKey) } }
    @Published var shortcutEnabled: Bool { didSet { defaults.set(shortcutEnabled, forKey: Self.enabledKey) } }
    @Published var shortcut: GlobalShortcutBinding? {
        didSet {
            if let shortcut, let data = try? JSONEncoder().encode(shortcut) {
                defaults.set(data, forKey: Self.shortcutKey)
            } else {
                defaults.removeObject(forKey: Self.shortcutKey)
            }
        }
    }
    @Published var recordingShortcut = false
    @Published var registrationStatus: OSStatus?

    private let defaults: UserDefaults
    private static let menuBarKey = "pref.globalAccess.menuBar"
    private static let enabledKey = "pref.globalAccess.shortcutEnabled"
    private static let shortcutKey = "pref.globalAccess.shortcut"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        showMenuBarItem = defaults.object(forKey: Self.menuBarKey) == nil || defaults.bool(forKey: Self.menuBarKey)
        shortcutEnabled = defaults.bool(forKey: Self.enabledKey)
        if let data = defaults.data(forKey: Self.shortcutKey),
           let stored = try? JSONDecoder().decode(GlobalShortcutBinding.self, from: data), stored.isValid {
            shortcut = stored
        } else {
            shortcut = nil
            shortcutEnabled = false
        }
    }

    func setShortcut(_ binding: GlobalShortcutBinding) {
        guard binding.isValid else { return }
        shortcut = binding
        shortcutEnabled = true
        recordingShortcut = false
    }

    func clearShortcut() {
        shortcutEnabled = false
        shortcut = nil
        recordingShortcut = false
    }
}

@MainActor
protocol GlobalHotKeyRegistering: AnyObject {
    var onTrigger: (@MainActor () -> Void)? { get set }
    func replace(with binding: GlobalShortcutBinding?) -> OSStatus
}

@MainActor
final class GlobalShortcutRegistration {
    private let registrar: any GlobalHotKeyRegistering
    private let preferences: GlobalAccessPreferences
    private var subscription: AnyCancellable?

    init(preferences: GlobalAccessPreferences, registrar: any GlobalHotKeyRegistering,
         onTrigger: @escaping @MainActor () -> Void) {
        self.preferences = preferences
        self.registrar = registrar
        registrar.onTrigger = onTrigger
        subscription = preferences.$shortcut.combineLatest(preferences.$shortcutEnabled, preferences.$recordingShortcut)
            .sink { [weak self] shortcut, enabled, recording in
                guard let self else { return }
                let status = self.registrar.replace(with: enabled && !recording ? shortcut : nil)
                self.preferences.registrationStatus = status == noErr ? nil : status
            }
    }

    func shutdown() {
        subscription = nil
        _ = registrar.replace(with: nil)
        registrar.onTrigger = nil
    }
}
