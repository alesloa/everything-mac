import AppKit
import SwiftUI

// Source: the owner's requested permanent expand/collapse control. Labels and
// button state describe this window's folderSidebarVisible preference.
struct FolderSidebarToggle: NSViewRepresentable {
    @ObservedObject var model: AppModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton()
        button.setButtonType(.pushOnPushOff)
        button.bezelStyle = .texturedRounded
        button.image = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: nil)
        button.imagePosition = .imageOnly
        button.identifier = NSUserInterfaceItemIdentifier("folder-sidebar-toggle")
        button.setAccessibilityIdentifier("folder-sidebar-toggle")
        button.target = context.coordinator
        button.action = #selector(Coordinator.toggleSidebar(_:))
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.model = model
        button.state = model.folderSidebarVisible ? .on : .off
        button.contentTintColor = model.folderSidebarVisible ? .controlAccentColor : .secondaryLabelColor
        button.setAccessibilityLabel(model.folderSidebarVisible ? "Collapse folder sidebar" : "Expand folder sidebar")
        button.toolTip = model.folderSidebarVisible ? "Collapse folders" : "Expand folders"
    }

    @MainActor final class Coordinator: NSObject {
        var model: AppModel
        init(model: AppModel) { self.model = model }
        @objc func toggleSidebar(_ sender: NSButton) { model.setFolderSidebarVisible(sender.state == .on) }
    }
}
