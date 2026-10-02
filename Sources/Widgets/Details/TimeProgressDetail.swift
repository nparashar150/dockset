import Foundation
import SwiftUI

/// All three spans at once - which is the one thing the tile cannot do.
///
/// Its period name is a button that pages day → month → year, so a card only
/// ever answers one of the three questions and you have to click twice to see
/// the other two. Here they stack, and the comparison is the point: a day
/// three quarters gone sitting above a year barely past three quarters is a
/// different feeling from either number alone.
///
/// Nothing is read but the calendar, same as the tile - real intervals around
/// the current moment, so DST days and leap years stay honest. Each row
/// carries the figure behind its percentage, because "73%" of a year is a mood
/// and "98 days left" is something you can act on.
struct TimeProgressDetail: View {
    var instance: WidgetInstance
    var context: WidgetContext

    var body: some View {
        // A minute is the coarsest tick that keeps "7h 32m left" true. It has
        // to be a schedule rather than `context.now`: the panel's root view is
        // assigned once when it opens, so that clock is frozen for as long as
        // the panel stays up and every row would sit perfectly still.
        TimelineView(.periodic(from: .now, by: 60)) { tick in
            let now = tick.date
            let shown = Span(rawValue: period) ?? .year
            let gone = fraction(Calendar.current.dateInterval(of: shown.component, for: now), now: now)
            // The span on the tile as one enormous figure, then all three as
            // tracks to compare: how much of it is gone is the whole reading.
            DetailCard {
                MeshBackdrop(color: accent)
            } content: {
                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(alignment: .firstTextBaseline, spacing: 2) {
                            // Light, like every other panel's figure.
                            Text("\(Int(gone * 100))")
                                .font(.system(size: 44, weight: .light))
                                .foregroundStyle(WidgetStyle.primary)
                                .rollingValue(Int(gone * 100))
                            Text("%")
                                .font(.system(size: 22, weight: .light))
                                .foregroundStyle(.white.opacity(0.7))
                        }
                        .monospacedDigit()
                        Text("of \(shown.title(now)) gone")
                            .font(WidgetStyle.label(13))
                            .foregroundStyle(.white.opacity(0.75))
                    }

                    VStack(spacing: 5) {
                        ForEach(Span.allCases, id: \.self) { row($0, now: now) }
                    }
                }
            }
        }
    }

    /// The tile's catalog colour.
    private var accent: Color {
        Color(hex: WidgetCatalog.accentHex(.progress) ?? PaletteColor.teal.hex)
    }

    // MARK: Rows

    /// A row is also the tile's period control: clicking one puts that span on
    /// the card, which is the same write the tile's own name makes.
    ///
    /// The library draws live previews, where a write must never fire - and a
    /// button that refused to act would still swallow the click that adds the
    /// widget - so there the rows are plain text.
    @ViewBuilder
    private func row(_ span: Span, now: Date) -> some View {
        if context.isPreview {
            line(span, now: now)
        } else {
            Button { pick(span) } label: {
                line(span, now: now).contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Show \(span.spoken) on the tile")
            .accessibilityAddTraits(span.rawValue == period ? [.isSelected] : [])
        }
    }

    private func line(_ span: Span, now: Date) -> some View {
        let interval = Calendar.current.dateInterval(of: span.component, for: now)
        let fraction = fraction(interval, now: now)
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                // The span showing on the shelf is the one in full ink. The
                // panel is not a settings sheet, but it does have to say which
                // of the three the card behind it is currently answering.
                Text(span.title(now))
                    .font(WidgetStyle.label(13))
                    .foregroundStyle(span.rawValue == period ? WidgetStyle.primary
                                                             : WidgetStyle.secondary)
                Spacer(minLength: 4)
                Text(remaining(span, end: interval?.end, now: now))
                    .font(WidgetStyle.caption(11))
                    .foregroundStyle(WidgetStyle.secondary)
                    .monospacedDigit()
                percent(fraction)
            }
            .lineLimit(1)
            bar(fraction)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .glassPane(cornerRadius: 12)
        // The span the tile is showing is lit, so the panel says which of
        // the three the card behind it is answering.
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.white.opacity(span.rawValue == period ? 0.55 : 0), lineWidth: 1)
        }
        // One row is one fact; read out as four labels it becomes a mouthful.
        .accessibilityElement(children: .combine)
    }

    /// Bold figure, quiet sign - the tile's own treatment, so a percentage
    /// does not change character on its way from the shelf into the panel.
    private func percent(_ fraction: Double) -> some View {
        let value = Int(fraction * 100)
        return HStack(spacing: 0) {
            Text("\(value)")
                .foregroundStyle(WidgetStyle.primary)
                .rollingValue(value)
            Text("%")
                .foregroundStyle(WidgetStyle.secondary)
        }
        .font(.system(size: 13, weight: .bold))
        .monospacedDigit()
    }

    /// A plain bar rather than the tile's 52-segment run: that run is a
    /// texture that works at 156pt across, and three of them stacked read as
    /// stripes. What these three are for is being compared, and a solid fill
    /// is what the eye compares fastest.
    private func bar(_ fraction: Double) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.14))
                Capsule()
                    .fill(.white.opacity(0.8))
                    .frame(width: geometry.size.width * fraction)
            }
        }
        .frame(height: 6)
    }

    // MARK: Figures

    /// 0…1 through the span, clamped. A missing interval means the calendar
    /// could not place the date at all - nothing rather than no progress - but
    /// a bar has to be drawn at some length, and empty is the honest one.
    private func fraction(_ interval: DateInterval?, now: Date) -> Double {
        guard let interval, interval.duration > 0 else { return 0 }
        return min(1, max(0, now.timeIntervalSince(interval.start) / interval.duration))
    }

    /// What is actually left, in the unit the span is lived in: a day in hours
    /// and minutes, the longer spans in days.
    private func remaining(_ span: Span, end: Date?, now: Date) -> String {
        guard let end else { return "-" }
        switch span {
        case .day:
            // Rounded up, so the last half-minute of the day reads "1m left"
            // rather than "0m left".
            let minutes = Int((max(0, end.timeIntervalSince(now)) / 60).rounded(.up))
            return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m left"
                                 : "\(minutes)m left"
        case .month, .year:
            // Counted in calendar days from the start of today, so today
            // counts as a day you still have and a DST change cannot shave one
            // off an otherwise whole month.
            let calendar = Calendar.current
            let days = calendar.dateComponents([.day],
                                               from: calendar.startOfDay(for: now),
                                               to: end).day ?? 0
            return days == 1 ? "1 day left" : "\(days) days left"
        }
    }

    // MARK: Data

    /// The tile's key and the tile's fallback, so the two cannot disagree
    /// about which span the card is showing.
    private var period: String {
        instance.config.string("period", default: "year")
    }

    /// Writes the span the tile shows. Animated for the same reason the tile
    /// animates its own cycle: the bar and the figure move rather than cut.
    private func pick(_ span: Span) {
        withAnimation(.snappy(duration: 0.3)) {
            WidgetWriter.write(instance) { config in
                config.set("period", .string(span.rawValue))
            }
        }
    }

    /// The tile's three spans, raw values included: both sides read the same
    /// config key, so a span added there has to be added here too or the panel
    /// silently drops it.
    private enum Span: String, CaseIterable {
        case day, month, year

        var component: Calendar.Component {
            switch self {
            case .day: .day
            case .month: .month
            case .year: .year
            }
        }

        /// The tile's label for the span - the weekday, the month's name, the
        /// year - rather than the abstract word for it.
        func title(_ now: Date) -> String {
            switch self {
            case .day: now.formatted(.dateTime.weekday(.wide))
            case .month: now.formatted(.dateTime.month(.wide))
            case .year: now.formatted(.dateTime.year())
            }
        }

        /// "September" means nothing read aloud out of context; this is what
        /// the row is actually about.
        var spoken: String {
            switch self {
            case .day: "today"
            case .month: "this month"
            case .year: "this year"
            }
        }
    }
}
