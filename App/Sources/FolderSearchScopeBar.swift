import SwiftUI
import IndexCore

struct FolderSearchScopeBar: View {
    let selection: FolderSearchScope
    let onSelect: (FolderSearchScope?) -> Void

    var body: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    // Source: the actual included/excluded paths in this tab's
                    // FolderSearchScope and the owner's visible scope controls.
                    if selection.included.isEmpty {
                        Text("All Indexed Folders").font(.caption)
                    }
                    ForEach(selection.included, id: \.pathBytes) { path in
                        chip(path, excluded: false)
                    }
                    ForEach(selection.excluded, id: \.pathBytes) { path in
                        chip(path, excluded: true)
                    }
                }
            }.scrollIndicators(.hidden).frame(height: 24)
            Button { onSelect(nil) } label: { Image(systemName: "xmark.circle") }
                .buttonStyle(.plain)
                // Source: onSelect(nil) clears this tab's search-only restrictions.
                .help("Clear folder selection and exclusions")
                .accessibilityLabel("Clear folder selection and exclusions")
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .accessibilityIdentifier("folder-search-scope")
    }

    private func chip(_ path: FolderScope, excluded: Bool) -> some View {
        HStack(spacing: 5) {
            Text(excluded ? "Exclude:" : "Include:").foregroundStyle(.secondary)
            Text(path.path).lineLimit(1).truncationMode(.middle).frame(maxWidth: 300)
            Button { remove(path, excluded: excluded) } label: {
                Image(systemName: "xmark").font(.system(size: 9))
            }.buttonStyle(.plain)
                .accessibilityLabel(excluded ? "Remove folder exclusion" : "Remove included folder")
        }
        .font(.caption).padding(.horizontal, 7).padding(.vertical, 4)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
        .help(path.path)
    }

    private func remove(_ path: FolderScope, excluded: Bool) {
        let included = excluded ? selection.included : selection.included.filter { $0.pathBytes != path.pathBytes }
        let exclusions = excluded ? selection.excluded.filter { $0.pathBytes != path.pathBytes } : selection.excluded
        let next = FolderSearchScope(included: included, excluded: exclusions)
        onSelect(next.included.isEmpty && next.excluded.isEmpty ? nil : next)
    }
}

private extension FolderScope {
    var pathBytes: [UInt8] { Array(path.utf8) }
}
