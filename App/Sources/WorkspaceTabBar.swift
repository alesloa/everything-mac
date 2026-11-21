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
            HStack(spacing: 10) {
                Button { model.historyBack() } label: { Image(systemName: "chevron.left") }
                    .disabled(!workspace.canGoBack).help("Previous search").accessibilityLabel("Previous search")
                Button { model.historyForward() } label: { Image(systemName: "chevron.right") }
                    .disabled(!workspace.canGoForward).help("Next search").accessibilityLabel("Next search")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(workspace.window.tabs) { tab in
                            let isSelected = tab.id == workspace.window.selectedTabID
                            HStack(spacing: 8) {
                                Button { model.selectSearchTab(tab.id) } label: {
                                    Text(tab.state.query.isEmpty ? "New Search" : tab.state.query)
                                        .fontWeight(isSelected ? .semibold : .regular)
                                        .lineLimit(1).frame(maxWidth: 180)
                                }
                                .buttonStyle(.plain)
                                .accessibilityAddTraits(isSelected ? .isSelected : [])
                                Button { model.closeSearchTab(tab.id) } label: {
                                    Image(systemName: "xmark").font(.caption2)
                                }.buttonStyle(.plain).help("Close tab").accessibilityLabel("Close tab")
                            }
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(isSelected ? Styling.accent.opacity(0.20) : .clear, in: Capsule())
                        }
                    }
                }
                Button { model.newSearchTab() } label: { Image(systemName: "plus") }
                    .disabled(!workspace.canAddTab).help("New tab").accessibilityLabel("New tab")
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 12).padding(.vertical, 4)
            .glassSurface(in: Capsule())
            .padding(.bottom, 8)
        }
    }
}
