import SwiftUI
import IndexCore

// Source: paths are the owner's captured folder selection. Labels describe
// FolderSearchScope's inclusion-union and exclusion behavior.
struct FolderSearchScopeDetails: View {
    let selection: FolderSearchScope?

    var body: some View {
        if let selection {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    if selection.included.isEmpty {
                        Text("All indexed folders").font(.caption)
                    } else {
                        ForEach(selection.included, id: \.pathBytes) { scope in
                            Text("Include: \(scope.path)").font(.caption).textSelection(.enabled)
                        }
                    }
                    ForEach(selection.excluded, id: \.pathBytes) { scope in
                        Text("Exclude: \(scope.path)").font(.caption).textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 140)
        }
    }
}

private extension FolderScope {
    var pathBytes: [UInt8] { Array(path.utf8) }
}
