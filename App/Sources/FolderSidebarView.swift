import SwiftUI
import IndexCore

struct FolderSidebarView: View {
    let snapshot: FolderSnapshot?
    let selectedScope: FolderSearchScope?
    let onSelect: (FolderSearchScope?) -> Void
    @ObservedObject var treeState: FolderSidebarState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Source: the owner's requested indexed-folder selection controls.
            Text("Folders").font(.headline).padding(12)
            Button { onSelect(nil) } label: {
                Label("All Indexed Folders", systemImage: "internaldrive")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(selectedScope == nil ? Color.accentColor.opacity(0.15) : .clear)
            }.buttonStyle(.plain).padding(.horizontal, 4)
            FolderOutlineView(snapshot: snapshot, selection: selectedScope,
                              state: treeState, onSelect: onSelect)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Source: NSOutlineView's native multiple selection and this search's context menu.
            Text("Shift-click a range. Command-click individual folders. Right-click to exclude.")
                .font(.caption).foregroundStyle(.secondary).padding(10)
        }
        .frame(minWidth: 180, idealWidth: 230, maxWidth: 320, maxHeight: .infinity, alignment: .topLeading)
    }
}
