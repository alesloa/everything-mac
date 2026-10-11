import SwiftUI
import IndexCore

struct SearchField: View {
    @Binding var text: String
    var focused: FocusState<Bool>.Binding
    var onChange: () -> Void
    @ObservedObject var model: AppModel
    var body: some View {
        HStack {
            FolderSidebarToggle(model: model).frame(width: 28, height: 26)
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search everything…", text: $text)
                .textFieldStyle(.plain).font(.system(size: 15))
                .focused(focused)
                .onChange(of: text) { onChange() }
            if !text.isEmpty {
                // Source: this application's clear-search action resets the entered query.
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help("Clear search").accessibilityLabel("Clear search")
            }
            SearchFiltersButton(model: model, workspace: model.workspace)
        }
        .padding(8)
    }
}
