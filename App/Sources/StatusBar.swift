import SwiftUI

struct StatusBar: View {
    var total: Int
    var shown: Int
    var scanning: Bool
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
            Spacer()
            Text("\(shown.formatted()) results")
        }
        .font(.system(size: 11)).foregroundStyle(.secondary)
        .padding(.horizontal, 10).padding(.vertical, 4)
    }
}
