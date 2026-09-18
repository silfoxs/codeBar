import SwiftUI

/// Untinted system glass; accessibility and older systems use native materials.
struct GlassSurface: View {
    var cornerRadius: CGFloat = 18
    var clearGlass = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if reduceTransparency {
            shape.fill(Color(nsColor: .windowBackgroundColor))
        } else if #available(macOS 26.0, *) {
            Color.clear.glassEffect(clearGlass ? .clear : .regular, in: shape)
        } else {
            shape.fill(.regularMaterial)
        }
    }
}
