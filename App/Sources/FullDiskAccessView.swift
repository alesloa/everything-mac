import SwiftUI

struct FullDiskAccessView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.shield")
                .font(.system(size: 48)).foregroundStyle(.orange)
            Text("EverythingMac needs Full Disk Access")
                .font(.title2.bold())
            VStack(alignment: .leading, spacing: 8) {
                Text("EverythingMac indexes every file and folder on your Mac so results appear as you type.")
                Text("Without Full Disk Access, macOS asks for permission folder by folder (Desktop, Documents, Downloads, external drives) and the index stays incomplete.")
                Text("Turn on EverythingMac under System Settings › Privacy & Security › Full Disk Access. Indexing starts automatically once it's granted.")
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: 460)
            .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Button("Open System Settings") { FullDiskAccess.openSettings() }
                    .keyboardShortcut(.defaultAction)
                Button("Continue Without Full Disk Access") { model.continueWithoutFullDiskAccess() }
            }
            .padding(.top, 4)
            HStack(spacing: 4) {
                Text("Already turned it on and nothing happens?")
                Button("Relaunch EverythingMac") { FullDiskAccess.relaunch() }
                    .buttonStyle(.link)
            }
            .font(.callout).foregroundStyle(.secondary)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
    }
}
