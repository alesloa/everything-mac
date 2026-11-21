import SwiftUI

enum Styling {
    static let rowFont = Font.system(size: 13)
    static let accent = Color(red: 0, green: 0.47, blue: 0.65)
}

extension View {
    @ViewBuilder
    func translucentWindow() -> some View {
        if #available(macOS 26.0, *) {
            containerBackground(.thinMaterial, for: .window)
        } else {
            self
        }
    }

    @ViewBuilder
    func glassSurface<S: InsettableShape>(in shape: S) -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(.regular, in: shape)
        } else {
            background(.regularMaterial, in: shape)
        }
    }

    @ViewBuilder
    func glassAction(prominent: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            if prominent { buttonStyle(.glassProminent) }
            else { buttonStyle(.glass) }
        } else {
            if prominent { buttonStyle(.borderedProminent) }
            else { buttonStyle(.bordered) }
        }
    }
}
