import SwiftUI

struct SearchField: View {
    @Binding var text: String
    @Binding var matchPath: Bool
    var focused: FocusState<Bool>.Binding
    var onChange: () -> Void
    var body: some View {
        HStack {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search everything…", text: $text)
                .textFieldStyle(.plain).font(.system(size: 15))
                .focused(focused)
                .onChange(of: text) { onChange() }
            Toggle("Match path", isOn: $matchPath).toggleStyle(.switch)
                .onChange(of: matchPath) { onChange() }
        }
        .padding(8)
    }
}
