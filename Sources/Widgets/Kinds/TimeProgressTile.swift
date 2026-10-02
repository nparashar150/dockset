import Foundation
import SwiftUI

/// How much of the current day, month or year has already gone.
///
/// Three layouts share one number: `bars` (176×78), `ring` (148×76) and
/// `percentage` (112×62). The fraction comes from the real calendar interval
/// around `context.now`, so there is nothing to stub out in the library.
///
/// A click on the period name - and only on the name - moves the span on:
/// day → month → year. The card's own click belongs to the shelf, so the
/// control is as small as the thing it changes. The choice is `period` in the
/// widget's own config, the same key the catalog seeds, so it survives a
/// relaunch and follows the widget between profiles.
struct TimeProgressTile: View {
    var instance: WidgetInstance
    var context: WidgetContext

    /// One bar per 3pt of the 156pt content width.
    private static let barCount = 52

    /// Shortest span first, so a click reads as zooming out.
    private static let periods = ["day", "month", "year"]

    private var period: Calendar.Component {
        switch instance.config.string("period", default: "year") {
        case "day": .day
        case "month": .month
        default: .year
        }
    }

    /// 0…1 through the current period. A calendar interval - not a fixed
    /// 24h/365d - so DST days and leap years stay honest.
    private var fraction: Double {
        let calendar = Calendar.current
        guard let span = calendar.dateInterval(of: period, for: context.now),
              span.duration > 0 else { return 0 }
        let elapsed = context.now.timeIntervalSince(span.start) / span.duration
        return min(1, max(0, elapsed))
    }

    private var percent: Int { Int(fraction * 100) }

    private var label: String {
        switch period {
        case .day: context.now.formatted(.dateTime.weekday(.wide))
        case .month: context.now.formatted(.dateTime.month(.wide))
        default: context.now.formatted(.dateTime.year())
        }
    }

    var body: some View {
        WidgetSurface {
            Group {
                if context.position.isVertical {
                    // The 52-bar run cannot survive 56pt of usable width, so a
                    // column always rings - whatever the horizontal layout is.
                    if instance.config.string("layout", default: "bars") == "percentage" {
                        columnPercentage
                    } else {
                        columnRing
                    }
                } else {
                    switch instance.config.string("layout", default: "bars") {
                    case "ring": ringLayout
                    case "percentage": percentageLayout
                    default: barsLayout
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Every layout reads `period`, so one write swaps the span in place and
    /// leaves the chosen layout alone. A value from elsewhere that isn't one of
    /// the three lands on the first span rather than sticking.
    private func cycle() {
        let current = instance.config.string("period", default: "year")
        let index = Self.periods.firstIndex(of: current) ?? Self.periods.count - 1
        let next = Self.periods[(index + 1) % Self.periods.count]
        withAnimation(.snappy(duration: 0.3)) {
            WidgetWriter.write(instance) { config in
                config.set("period", .string(next))
            }
        }
    }

    // MARK: Layouts

    private var barsLayout: some View {
        VStack(alignment: .leading, spacing: 7) {
            // The shelf's two type styles: the figure as the value, the span
            // as the caption, on one line above the run of bars.
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                percentText(19)
                periodLabel(12)
                Spacer(minLength: 0)
            }
            bars
        }
    }

    private var bars: some View {
        let filled = Int(fraction * Double(Self.barCount))
        return HStack(spacing: 4.0 / 3.0) {
            ForEach(0..<Self.barCount, id: \.self) { index in
                RoundedRectangle(cornerRadius: 0.85, style: .continuous)
                    // Softened from full ink: a run of 52 solid white bars was
                    // the brightest thing on the shelf.
                    .fill(WidgetStyle.primary.opacity(index < filled ? 0.62 : 0.12))
                    .frame(width: 5.0 / 3.0)
            }
        }
        .frame(height: 16)
    }

    private var ringLayout: some View {
        // The ring in the badge every tile leads with.
        HStack(spacing: 10) {
            TileBadge { TileRing(progress: fraction) }
            VStack(alignment: .leading, spacing: 1) {
                percentText(19)
                periodLabel(12)
            }
            Spacer(minLength: 0)
        }
    }

    private var percentageLayout: some View {
        VStack(spacing: 1) {
            percentText(22)
            periodLabel(11)
        }
    }

    // MARK: Column layouts (76pt wide, 56pt usable)

    /// 76×80: ring with the figure inside, period beneath.
    private var columnRing: some View {
        VStack(spacing: 5) {
            ZStack {
                // The shelf's ring weight, as TileRing draws it.
                Circle()
                    .stroke(WidgetStyle.primary.opacity(0.1), lineWidth: 3)
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(WidgetStyle.primary.opacity(0.85),
                            style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                percentText(13)
                    .minimumScaleFactor(0.6)
                    .padding(.horizontal, 3)
            }
            .frame(width: 44, height: 44)

            periodLabel(10)
        }
    }

    /// 76×58: the figure over the period, nothing else.
    private var columnPercentage: some View {
        VStack(spacing: 1) {
            percentText(21)
                .minimumScaleFactor(0.6)
            periodLabel(10)
        }
    }

    // MARK: Pieces

    /// The period name, and the tile's one control: clicking it moves the span
    /// on. Only the name is clickable, because a target that filled the card
    /// would beat the shelf's own click and the card would stop opening.
    ///
    /// The library draws live previews, where an action must never write
    /// config - and a button that refused to act would still swallow the
    /// click - so there the name is plain text and wears no chevron.
    ///
    /// `prominent` is the bars layout, where the name is the tile's headline
    /// rather than a caption under the figure.
    ///
    /// No disc behind the chevron: `TileGlyph` (see StopwatchTile) is for a
    /// control standing on its own on a card, where nothing else says it can
    /// be pressed. This one is inside a line of type and already reads as part
    /// of the word it changes - the same shape the Stock tile's ticker wears.
    @ViewBuilder
    private func periodLabel(_ size: CGFloat, prominent: Bool = false) -> some View {
        if context.isPreview {
            periodText(size, prominent: prominent)
        } else {
            Button(action: cycle) {
                HStack(spacing: 2) {
                    periodText(size, prominent: prominent)
                    // Sized off the name beside it: the caption drops from
                    // 13pt to 10pt in the 76pt column, where a fixed glyph
                    // would out-shout the word it belongs to.
                    Image(systemName: "chevron.right")
                        .font(.system(size: size - 2, weight: .semibold))
                        .foregroundStyle(WidgetStyle.secondary)
                }
                // Inside the row, so the target is the name and the glyph and
                // not a pixel more of the card.
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Show the next period")
        }
    }

    /// "September" is wider than 56pt at full size, and the chevron takes a
    /// further 9pt of it, so the name scales rather than truncating to
    /// "Septem…".
    private func periodText(_ size: CGFloat, prominent: Bool) -> some View {
        Text(label)
            .font(prominent ? WidgetStyle.label(size) : WidgetStyle.caption(size))
            .foregroundStyle(prominent ? WidgetStyle.primary : WidgetStyle.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }

    /// The figure is bold and primary, the sign is quieter - reads as one
    /// number rather than a number shouting a unit.
    private func percentText(_ size: CGFloat) -> some View {
        HStack(spacing: 0) {
            Text(percent.formatted())
                .foregroundStyle(WidgetStyle.primary)
            Text("%")
                .foregroundStyle(WidgetStyle.secondary)
        }
        .font(.system(size: size, weight: .semibold))
        .monospacedDigit()
        .lineLimit(1)
    }
}
