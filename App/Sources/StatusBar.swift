import SwiftUI

struct StatusBar: View {
    var total: Int
    var shown: Int
    var scanning: Bool
    var shares: [NetworkShareStatus] = []
    var matches: Int? = nil
    var body: some View {
        HStack(spacing: 6) {
            if scanning {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.6)
                    .frame(width: 12, height: 12)
                Text("Indexing… \(total.formatted()) files")
            } else {
                Text("\(total.formatted()) objects")
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
            // Source: shown rows and the total count from the same accepted SearchReport.
            if let matches { Text("\(shown.formatted()) shown · \(matches.formatted()) matches") }
            else { Text("\(shown.formatted()) results") }
        }
        .font(.system(size: 11)).foregroundStyle(.secondary)
        .padding(.horizontal, 10).padding(.vertical, 4)
    }
}
