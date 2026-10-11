import SwiftUI

struct SearchField: View {
    @Binding var text: String
    @Binding var matchPath: Bool
    @Binding var fuzzy: Bool
    var wholeWord: Bool
    var focused: FocusState<Bool>.Binding
    var onChange: () -> Void
    var fuzzyAvailable = true
    var body: some View {
        HStack {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search everything…", text: $text)
                .textFieldStyle(.plain).font(.system(size: 15))
                .focused(focused)
                .onChange(of: text) { onChange() }
            Toggle("Match path", isOn: $matchPath).toggleStyle(.switch)
                .onChange(of: matchPath) { onChange() }
            // Source: the owner's request for fuzzy file search; the switch reflects
            // the persisted AppModel search option, never inferred file metadata.
            Toggle("Fuzzy", isOn: $fuzzy).toggleStyle(.switch)
                .disabled(wholeWord || !fuzzyAvailable)
                .onChange(of: fuzzy) { onChange() }
        }
        .padding(8)
    }
}
