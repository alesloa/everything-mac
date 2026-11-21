import SwiftUI
import IndexCore

struct SearchField: View {
    @Binding var text: String
    var focused: FocusState<Bool>.Binding
    var onChange: () -> Void
    @ObservedObject var model: AppModel
    var body: some View {
        HStack(spacing: 10) {
            FolderSidebarToggle(model: model).frame(width: 38, height: 36)
                .glassSurface(in: Capsule())
            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search everything…", text: $text)
                    .textFieldStyle(.plain).font(.system(size: 15))
                    .focused(focused)
                    .onChange(of: text) { onChange() }
                if !text.isEmpty {
                    Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .help("Clear search").accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 13)
            .frame(height: 36)
            .glassSurface(in: Capsule())
            SearchFiltersButton(model: model, workspace: model.workspace)
                .controlSize(.large)
        }
        .padding(.vertical, 10)
    }
}
