import SwiftUI
import IndexCore

struct FolderSidebarView: View {
    let snapshot: FolderSnapshot?
    let selectedScope: FolderScope?
    let onSelect: (FolderScope?) -> Void
    let onClose: () -> Void
    @State private var expanded: Set<[UInt8]> = []

    // These labels describe the owner's requested indexed-folder search scope.
    private let allLabel = "All Indexed Folders"
    private let folderLabel = "Folders"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(folderLabel).font(.headline)
                Spacer()
                // Source: the owner's requested reset when the sidebar closes.
                Button(action: onClose) { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close folder sidebar")
                    .help("Search all indexed folders and hide the sidebar")
            }.padding(12)
            Button { onSelect(nil) } label: {
                Label(allLabel, systemImage: "internaldrive")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(selectedScope == nil ? Color.accentColor.opacity(0.15) : .clear)
            }.buttonStyle(.plain).padding(.horizontal, 4)
            if let snapshot {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(snapshot.roots, id: \.self) { id in
                            folder(id, snapshot: snapshot, depth: 0)
                        }
                    }
                }
            }
            // Source: AppModel.setFolderSidebarVisible clears the location scope.
            Text("Closing this sidebar searches all indexed folders.")
                .font(.caption).foregroundStyle(.secondary).padding(10)
        }
        .frame(minWidth: 180, idealWidth: 230, maxWidth: 320)
    }

    private func folder(_ id: UInt32, snapshot: FolderSnapshot, depth: Int) -> AnyView {
        guard let record = snapshot.record(for: id) else { return AnyView(EmptyView()) }
        let children = snapshot.children(of: id)
        // Folder names, paths, and totals below come from this immutable index snapshot.
        let scope = FolderScope(record: record)
        let expansion = Array(record.path.utf8)
        let selected = selectedScope?.path.utf8.elementsEqual(record.path.utf8) == true
        return AnyView(VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Button {
                    if expanded.contains(expansion) { expanded.remove(expansion) } else { expanded.insert(expansion) }
                } label: {
                    Image(systemName: expanded.contains(expansion) ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9)).frame(width: 12)
                        .opacity(children.isEmpty ? 0 : 1)
                }.buttonStyle(.plain).disabled(children.isEmpty)
                Button { onSelect(scope) } label: {
                    Label(record.name.isEmpty ? record.path : record.name, systemImage: "folder")
                        .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.plain).help(record.path)
            }
            .padding(.leading, CGFloat(depth) * 14 + 6).padding(.trailing, 8).padding(.vertical, 5)
            .background(selected ? Color.accentColor.opacity(0.15) : .clear)
            if expanded.contains(expansion) {
                ForEach(children, id: \.self) { child in folder(child, snapshot: snapshot, depth: depth + 1) }
            }
        })
    }
}
