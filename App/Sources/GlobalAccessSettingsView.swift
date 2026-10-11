import SwiftUI
import AppKit
import Carbon

// Source: labels describe the owner's approved global-access feature; binding/status values come from recorded events and Carbon.
enum GlobalAccessCopy {
    static let section = "Global Access"
    static let menuBar = "Show EverythingMac in the menu bar"
    static let enabled = "Enable global search shortcut"
    static let shortcut = "Shortcut"
    static let unset = "Not set"
    static let record = "Record Shortcut…"
    static let recording = "Press a shortcut with Command, Control, or Option."
    static let cancel = "Cancel"
    static let clear = "Clear"
    static let registrationFailed = "The shortcut could not be registered."
    static let show = "Show Search"
    static let hide = "Hide Search"
    static let newWindow = "New Search Window"
    static let settings = "Settings…"
    static let quit = "Quit EverythingMac"
    static let appName = "EverythingMac"

    static func registrationError(_ status: OSStatus) -> String {
        "\(registrationFailed) macOS status: \(status)"
    }

    static func indexStatus(count: Int, scanning: Bool) -> String {
        // Source: the background AppModel publishes the index's current count and actual scanning state.
        scanning ? "Indexing… \(count.formatted()) objects" : "\(count.formatted()) objects indexed"
    }
}

struct GlobalAccessSettingsView: View {
    @ObservedObject private var preferences: GlobalAccessPreferences

    init(preferences: GlobalAccessPreferences = .shared) {
        self.preferences = preferences
    }

    var body: some View {
        Section(GlobalAccessCopy.section) {
            Toggle(GlobalAccessCopy.menuBar, isOn: $preferences.showMenuBarItem)
            Toggle(GlobalAccessCopy.enabled, isOn: $preferences.shortcutEnabled)
                .disabled(preferences.shortcut == nil)
            LabeledContent(GlobalAccessCopy.shortcut,
                           value: preferences.shortcut?.displayName ?? GlobalAccessCopy.unset)
            HStack {
                if preferences.recordingShortcut {
                    Text(GlobalAccessCopy.recording).font(.caption)
                    Button(GlobalAccessCopy.cancel) { preferences.recordingShortcut = false }
                } else {
                    Button(GlobalAccessCopy.record) { preferences.recordingShortcut = true }
                    Button(GlobalAccessCopy.clear) { preferences.clearShortcut() }
                        .disabled(preferences.shortcut == nil)
                }
            }
            if let status = preferences.registrationStatus {
                Text(GlobalAccessCopy.registrationError(status))
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
            GlobalShortcutRecorder(preferences: preferences)
                .frame(width: 1, height: 1)
                .accessibilityHidden(true)
        }
        .onDisappear { preferences.recordingShortcut = false }
    }
}

private struct GlobalShortcutRecorder: NSViewRepresentable {
    @ObservedObject var preferences: GlobalAccessPreferences

    func makeNSView(context: Context) -> RecorderView { RecorderView(preferences: preferences) }

    func updateNSView(_ view: RecorderView, context: Context) {
        view.updateRecording(preferences.recordingShortcut)
    }

    final class RecorderView: NSView {
        private let preferences: GlobalAccessPreferences
        private weak var previousResponder: NSResponder?
        private var recording = false
        override var acceptsFirstResponder: Bool { true }

        init(preferences: GlobalAccessPreferences) {
            self.preferences = preferences
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        func updateRecording(_ recording: Bool) {
            guard recording != self.recording else { return }
            self.recording = recording
            if recording {
                previousResponder = window?.firstResponder
                window?.makeFirstResponder(self)
            } else if window?.firstResponder === self {
                window?.makeFirstResponder(previousResponder)
            }
        }

        override func keyDown(with event: NSEvent) {
            guard recording else { super.keyDown(with: event); return }
            if event.keyCode == UInt16(kVK_Escape) {
                preferences.recordingShortcut = false
            } else if let binding = GlobalShortcutBinding.capture(event) {
                preferences.setShortcut(binding)
            } else {
                NSSound.beep()
            }
        }

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard recording else { return super.performKeyEquivalent(with: event) }
            keyDown(with: event)
            return true
        }
    }
}
