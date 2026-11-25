import SwiftUI

/// Keeps the same editor alive and the controls on the bottom edge while the field expands above them.
struct ComposerLayout: Layout {
    var expansion: CGFloat
    var spacing: CGFloat = 8

    var animatableData: CGFloat {
        get { expansion }
        set { expansion = newValue }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 320
        let sizes = measure(width: width, subviews: subviews)
        return CGSize(width: width, height: sizes.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = measure(width: bounds.width, subviews: subviews)
        let bottom = bounds.maxY
        subviews[0].place(at: CGPoint(x: bounds.minX, y: bottom), anchor: .bottomLeading,
                          proposal: ProposedViewSize(sizes.leading))
        subviews[1].place(at: CGPoint(x: bounds.minX + sizes.fieldInset, y: bottom - sizes.fieldRise),
                          anchor: .bottomLeading, proposal: ProposedViewSize(sizes.field))
        subviews[2].place(at: CGPoint(x: bounds.maxX, y: bottom), anchor: .bottomTrailing,
                          proposal: ProposedViewSize(sizes.trailing))
        // The model button sits between plus and the voice buttons on the bottom row. Its width stays out
        // of the compact editor measurement so the editor interpolates smoothly on focus, and a long
        // model name is truncated to the room between them.
        if subviews.count > 3 {
            let room = max(0, bounds.width - sizes.leading.width - sizes.trailing.width - 2 * spacing)
            subviews[3].place(at: CGPoint(x: bounds.minX + sizes.leading.width + spacing, y: bottom), anchor: .bottomLeading,
                              proposal: ProposedViewSize(width: room, height: nil))
        }
    }

    private func measure(width: CGFloat, subviews: Subviews)
        -> (leading: CGSize, field: CGSize, trailing: CGSize, fieldInset: CGFloat, fieldRise: CGFloat, height: CGFloat) {
        let leading = subviews[0].sizeThatFits(.unspecified)
        let trailing = subviews[2].sizeThatFits(.unspecified)
        let inlineWidth = width - leading.width - trailing.width - 2 * spacing
        let progress = inlineWidth < 140 ? 1 : min(1, max(0, expansion))
        let fieldWidth = inlineWidth + (width - 16 - inlineWidth) * progress
        let field = subviews[1].sizeThatFits(ProposedViewSize(width: fieldWidth, height: nil))
        let controlsHeight = max(leading.height, trailing.height)
        let inlineRise = max(0, (controlsHeight - field.height) / 2)
        let fieldRise = inlineRise + (controlsHeight + spacing - inlineRise) * progress
        return (leading, field, trailing, (leading.width + spacing) * (1 - progress) + 8 * progress, fieldRise,
                max(controlsHeight, field.height + fieldRise))
    }
}


/// Reveals the controls as the editor clears their row, on the same animation as the layout.
struct ComposerShortcutReveal: ViewModifier, Animatable {
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let reveal = min(1, max(0, (progress - 0.35) / 0.65))
        content
            .opacity(Double(reveal))
            .scaleEffect(0.94 + 0.06 * reveal)
    }
}

