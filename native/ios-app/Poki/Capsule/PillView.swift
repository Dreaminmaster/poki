// Adapted from Element X iOS (https://github.com/element-hq/element-x-ios/tree/21758530da454c65969c6ef159b9ca47b9394a7a,
// ElementX/Sources/Other/Pills/PillView.swift).
// Copyright 2025 Element Creations Ltd. Copyright 2023-2025 New Vector Ltd.
// SPDX-License-Identifier: AGPL-3.0-only. See THIRD_PARTY_NOTICES.md.
// Poki's changes: the app's icon in front of its name on the icon's own colour (ESP-376 home board),
// sized from the surrounding font, with a faint edge on a near-black pill in dark mode; no Compound
// colours, status emoji or loading context.

import SwiftUI
import UIKit

/// Sizes shared by the attachment, which reserves the room, and the view, which draws in it.
struct PillMetrics {
    let pointSize: CGFloat

    var height: CGFloat { (pointSize * 1.24).rounded() }
    var icon: CGFloat { height - 6 }
    var labelFont: UIFont { .systemFont(ofSize: (pointSize * 0.82).rounded(), weight: .semibold) }
    var leading: CGFloat { 3 }
    var gap: CGFloat { 4 }
    var trailing: CGFloat { 7 }

    func size(for text: String) -> CGSize {
        let label = (text as NSString).size(withAttributes: [.font: labelFont]).width.rounded(.up)
        return CGSize(width: leading + icon + gap + label + trailing, height: height)
    }
}

struct PillView: View {
    let data: PillTextAttachmentData
    @Environment(\.colorScheme) private var colorScheme

    private var metrics: PillMetrics { PillMetrics(pointSize: data.fontData.pointSize) }

    var body: some View {
        let colors = CapsuleColors.of(data.app)
        HStack(spacing: metrics.gap) {
            Image(data.app.asset)
                .resizable()
                .frame(width: metrics.icon, height: metrics.icon)
                .clipShape(RoundedRectangle(cornerRadius: metrics.icon * 0.27, style: .continuous))
            Text(verbatim: data.label)
                .font(Font(metrics.labelFont))
                .lineLimit(1)
        }
        .foregroundStyle(Color(uiColor: colors.foreground))
        .padding(.leading, metrics.leading)
        .padding(.trailing, metrics.trailing)
        .frame(height: metrics.height)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(Color(uiColor: colors.background), in: .capsule)
        .overlay {
            if colors.edgeInDark, colorScheme == .dark {
                Capsule().strokeBorder(.white.opacity(0.28), lineWidth: 1)
            }
        }
        .accessibilityLabel(Text(verbatim: data.label))
    }
}
