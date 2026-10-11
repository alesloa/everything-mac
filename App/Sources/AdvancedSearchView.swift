import SwiftUI
import IndexCore

struct AdvancedSearchView: View {
    // Form labels and syntax guidance are the application's UI vocabulary defined
    // here; submitted query text comes only from the owner's form entries.
    let initialQuery: String
    let onApply: (String) -> Void
    let onCancel: () -> Void
    @State private var criteria = AdvancedSearchCriteria()
    @State private var includeInitialQuery = true

    init(initialQuery: String = "", onApply: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        self.initialQuery = initialQuery; self.onApply = onApply; self.onCancel = onCancel
    }
    private var queryText: String {
        guard includeInitialQuery, !initialQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return criteria.queryText
        }
        guard !criteria.queryText.isEmpty else { return initialQuery }
        return "(\(initialQuery)) (\(criteria.queryText))"
    }
    private var validationError: QueryValidationError? { Query(text: queryText).validationError }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Advanced Search").font(.title2.bold())
            Form {
                if !initialQuery.isEmpty { Toggle("Narrow the current search", isOn: $includeInitialQuery) }
                Picker("Filter", selection: $criteria.filter) {
                    ForEach(SearchFilter.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                TextField("Name contains", text: $criteria.name)
                TextField("Name excludes", text: $criteria.excludedName)
                TextField("Extensions separated by ;", text: $criteria.extensions)
                TextField("Location", text: $criteria.location)
                Toggle("Only this direct parent folder", isOn: $criteria.directParent)
                HStack {
                    TextField("Minimum size", text: $criteria.minimumSize)
                    TextField("Maximum size", text: $criteria.maximumSize)
                }
                Text("Sizes accept bytes, KB/MB/GB, or KiB/MiB/GiB.").font(.caption).foregroundStyle(.secondary)
                HStack {
                    TextField("Modified from", text: $criteria.modifiedFrom)
                    TextField("Modified through", text: $criteria.modifiedThrough)
                }
                Text("Dates accept YYYY-MM-DD, today, or yesterday in your local time zone.")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("Regular expression", text: $criteria.regularExpression)
            }
            .formStyle(.columns)
            Text(queryText).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            if let error = validationError {
                Text(error.localizedDescription).foregroundStyle(.red).font(.callout)
            }
            Text("Spaces and AND combine terms; OR and | bind first. NOT and ! exclude terms. Use () or <> for groups. Quote regex values that contain spaces or operators.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Search") { onApply(queryText) }.keyboardShortcut(.defaultAction)
                    .disabled(validationError != nil)
            }
        }
        .padding(20)
        .frame(width: 620)
    }
}
