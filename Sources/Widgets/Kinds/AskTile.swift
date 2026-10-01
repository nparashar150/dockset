import SwiftUI

/// A question away. The card's click opens the panel, which is where the
/// question is typed, so the tile itself is only the mark and an invitation:
/// or, once something has been asked, what the last answer was about.
struct AskTile: View {
    var instance: WidgetInstance
    var context: WidgetContext

    private var caption: String {
        guard !context.isPreview, let title = AskService.shared.title else { return "Quick answers" }
        return title
    }

    var body: some View {
        WidgetSurface {
            if context.position.isVertical {
                VStack(spacing: 5) {
                    TileBadge(size: 32) { glyph(13) }
                    Text("Ask")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(WidgetStyle.primary)
                }
            } else {
                HStack(spacing: 10) {
                    TileBadge { glyph(16) }
                    TileReading(value: "Ask", caption: caption)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func glyph(_ size: CGFloat) -> some View {
        Image(systemName: "sparkle")
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(WidgetStyle.primary)
    }
}
