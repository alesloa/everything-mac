import SwiftUI

struct StatusBar: View {
    var total: Int
    var scanning: Bool
    var shares: [NetworkShareStatus] = []
    var matches: Int? = nil
    var ordering = false
    var selected = 0
    var body: some View {
        HStack(spacing: 6) {
            // Source: the exact accepted query count, or published index count before a query finishes.
            Text("\((matches ?? total).formatted()) objects")
            if scanning {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.6)
                    .frame(width: 12, height: 12)
                Text("Indexing…")
            }
            ForEach(shares.filter { $0.scanning || $0.isOffline }) { s in
                Text("·")
                if s.scanning {
                    Text("Indexing \(s.share.name)… \(s.count.formatted())")
                } else {
                    Image(systemName: "bolt.horizontal.circle")
                    Text("\(s.share.name) offline")
                }
            }
            Spacer()
            // Source: the complete native selection's row-range count.
            if selected > 0 { Text("\(selected.formatted()) selected") }
            if ordering {
                // Source: the active result list's background ordering task.
                ProgressView().controlSize(.small)
                Text("Sorting…")
            }
        }
        .font(.system(size: 11)).foregroundStyle(.secondary)
        .padding(.horizontal, 10).padding(.vertical, 4)
    }
}
