import SwiftUI
import IndexCore

// Source: fixed interface labels below are application definitions; query titles come from owner-entered saved state.
struct WorkspaceTabBar: View {
    @EnvironmentObject var model: AppModel
    var body: some View { WorkspaceTabStrip(workspace: model.workspace).environmentObject(model) }
}

private struct WorkspaceTabStrip: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var workspace: SearchWorkspaceController

    var body: some View {
        if workspace.window.tabs.count > 1 {
        HStack(spacing: 8) {
            Button { model.historyBack() } label: { Image(systemName: "chevron.left") }
                .disabled(!workspace.canGoBack).help("Previous search")
            Button { model.historyForward() } label: { Image(systemName: "chevron.right") }
                .disabled(!workspace.canGoForward).help("Next search")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(workspace.window.tabs) { tab in
                        HStack(spacing: 6) {
                            Button { model.selectSearchTab(tab.id) } label: {
                                Text(tab.state.query.isEmpty ? "New Search" : tab.state.query)
                                    .lineLimit(1).frame(maxWidth: 180)
                            }
                            .buttonStyle(.plain)
                            Button { model.closeSearchTab(tab.id) } label: {
                                Image(systemName: "xmark").font(.caption2)
                            }.buttonStyle(.plain).help("Close tab")
                        }
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(tab.id == workspace.window.selectedTabID ? Color.accentColor.opacity(0.15) : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                    }
                }
            }
            Button { model.newSearchTab() } label: { Image(systemName: "plus") }
                .disabled(!workspace.canAddTab).help("New tab")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10).padding(.vertical, 5)
        }
    }
}
