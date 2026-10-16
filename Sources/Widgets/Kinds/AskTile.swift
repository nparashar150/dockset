import SwiftUI

/// A question away. The card's click opens the panel, which is where the
/// question is typed, so the tile itself is only the mark and one line: how
/// many coding agents are running and how many are working, or, with none,
/// what the last answer was about.
struct AskTile: View {
    var instance: WidgetInstance
    var context: WidgetContext

    private var caption: String {
        guard !context.isPreview else { return "Quick answers" }
        let scanner = AgentScanner.shared
        if !scanner.agents.isEmpty {
            let count = scanner.agents.count == 1 ? "1 agent" : "\(scanner.agents.count) agents"
            return scanner.working > 0 ? "\(count) · \(scanner.working) working" : count
        }
        return AskService.shared.title ?? "Quick answers"
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
        // Slowly: the count on the shelf does not need the panel's pace, and
        // a scan is a walk of the whole process table.
        .task {
            guard !context.isPreview else { return }
            while !Task.isCancelled {
                await AgentScanner.shared.refresh()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    private func glyph(_ size: CGFloat) -> some View {
        Image(systemName: "sparkle")
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(WidgetStyle.primary)
    }
}
