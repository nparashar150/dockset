import SwiftUI

/// Analog face on the left, digital time and date on the right.
///
/// On a side shelf the same parts stack into a 76pt column: face on top, time
/// under it, and no date - there is no room and it is the least useful part.
///
/// The readout and the face are factored out because World Clock is the same
/// tile pointed at a different time zone.
struct ClockTile: View {
    var instance: WidgetInstance
    var context: WidgetContext

    var body: some View {
        ClockReadout(
            now: context.now,
            zone: .current,
            caption: ClockFormat.date(context.now, zone: .current),
            // Compact clock is the time and nothing else.
            compactCaption: nil,
            expanded: instance.expanded,
            vertical: context.position.isVertical
        )
    }
}

// MARK: - Shared readout

/// Face + time + caption. Shared by Clock and World Clock.
struct ClockReadout: View {
    var now: Date
    var zone: TimeZone
    var caption: String
    /// Caption for the compact tile; `nil` renders the time alone.
    var compactCaption: String?
    var expanded: Bool
    /// Column layout for a side shelf.
    var vertical: Bool = false
    /// Line under the time in the column, shrunk to fit rather than truncated.
    var columnLabel: String?
    /// Tiny trailing marker on that line - World Clock's "+1" / "−1".
    var columnBadge: String?

    var body: some View {
        WidgetSurface {
            if vertical {
                column
            } else if expanded {
                // The face in the badge every tile leads with, so a clock and
                // the tile beside it share one left edge for their pictures.
                HStack(spacing: 10) {
                    TileBadge {
                        AnalogClockFace(now: now, zone: zone, diameter: 26)
                    }
                    TileReading(value: ClockFormat.time(now, zone: zone), caption: caption)
                    Spacer(minLength: 0)
                }
            } else {
                VStack(spacing: 2) {
                    time
                    if let compactCaption { text(compactCaption) }
                }
            }
        }
    }

    // MARK: Column

    private var column: some View {
        let parts = ClockFormat.compactTime(now, zone: zone)
        return VStack(spacing: 2) {
            // In the badge square, as on the wide card, so the side column
            // leads with the same mark in the same frame.
            TileBadge(size: 32) {
                AnalogClockFace(now: now, zone: zone, diameter: 22)
            }
            HStack(alignment: .firstTextBaseline, spacing: 1.5) {
                Text(parts.time)
                    .font(WidgetStyle.value(15))
                    .foregroundStyle(WidgetStyle.primary)
                    .monospacedDigit()
                    .rollingValue(parts.time)
                if let meridiem = parts.meridiem {
                    Text(meridiem)
                        .font(WidgetStyle.label(8))
                        .foregroundStyle(WidgetStyle.secondary)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            if let columnLabel {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(columnLabel)
                        .font(WidgetStyle.caption(10))
                        .foregroundStyle(WidgetStyle.secondary)
                    if let columnBadge {
                        Text(columnBadge)
                            .font(WidgetStyle.label(8))
                            .foregroundStyle(WidgetStyle.secondary.opacity(0.8))
                            .monospacedDigit()
                    }
                }
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            }
        }
    }

    private var time: some View {
        Text(ClockFormat.time(now, zone: zone))
            .font(WidgetStyle.value(21))
            .foregroundStyle(WidgetStyle.primary)
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.75)
    }

    private func text(_ string: String) -> some View {
        Text(string)
            .font(WidgetStyle.caption(12))
            .foregroundStyle(WidgetStyle.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }
}

// MARK: - Formatting

enum ClockFormat {
    /// Locale's own clock - 24h or 12h with a meridiem, whichever the user has.
    static func time(_ date: Date, zone: TimeZone) -> String {
        var style = Date.FormatStyle.dateTime.hour().minute()
        style.timeZone = zone
        return date.formatted(style)
    }

    static func date(_ date: Date, zone: TimeZone) -> String {
        var style = Date.FormatStyle.dateTime.weekday(.abbreviated).day().month(.abbreviated)
        style.timeZone = zone
        return date.formatted(style)
    }

    /// The column's time, with a 12-hour locale's meridiem split off so the
    /// figure itself stays big in 56pt of usable width.
    static func compactTime(_ date: Date, zone: TimeZone) -> (time: String, meridiem: String?) {
        var style = Date.FormatStyle.dateTime.hour(.defaultDigits(amPM: .omitted)).minute()
        style.timeZone = zone
        let time = date.formatted(style)
        guard isTwelveHour else { return (time, nil) }
        var calendar = Calendar.current
        calendar.timeZone = zone
        let hour = calendar.component(.hour, from: date)
        return (time, hour < 12 ? meridiemSymbols.am : meridiemSymbols.pm)
    }

    private static var isTwelveHour: Bool {
        switch Locale.current.hourCycle {
        case .oneToTwelve, .zeroToEleven: true
        default: false
        }
    }

    /// Resolved once: the symbols only change with the locale, and a
    /// DateFormatter per frame would be a silly price for two strings.
    private static let meridiemSymbols: (am: String, pm: String) = {
        let formatter = DateFormatter()
        formatter.locale = .current
        return (formatter.amSymbol ?? "AM", formatter.pmSymbol ?? "PM")
    }()
}

// MARK: - Face

/// A drawn clock face: thin rim, quarter ticks, hour and minute hands.
struct AnalogClockFace: View {
    var now: Date
    var zone: TimeZone
    var diameter: CGFloat = 30

    private var hands: (hour: Double, minute: Double) {
        var calendar = Calendar.current
        calendar.timeZone = zone
        let parts = calendar.dateComponents([.hour, .minute], from: now)
        let minute = Double(parts.minute ?? 0)
        let hour = Double((parts.hour ?? 0) % 12) + minute / 60
        return (hour / 12 * 360, minute / 60 * 360)
    }

    var body: some View {
        let angles = hands
        ZStack {
            Circle()
                .strokeBorder(WidgetStyle.secondary.opacity(0.45), lineWidth: 1.2)
            ForEach(0..<4, id: \.self) { quarter in
                tick.rotationEffect(.degrees(Double(quarter) * 90))
            }
            hand(length: diameter * 0.26, width: 2.2, degrees: angles.hour)
            hand(length: diameter * 0.37, width: 1.6, degrees: angles.minute)
        }
        .frame(width: diameter, height: diameter)
    }

    private var tick: some View {
        Capsule()
            .fill(WidgetStyle.secondary.opacity(0.45))
            .frame(width: 1.2, height: diameter * 0.1)
            .offset(y: -diameter * 0.39)
    }

    /// Offsetting by half the length before rotating pivots the hand on the
    /// centre of the face rather than its own middle.
    private func hand(length: CGFloat, width: CGFloat, degrees: Double) -> some View {
        Capsule()
            .fill(WidgetStyle.primary)
            .frame(width: width, height: length)
            .offset(y: -length / 2)
            .rotationEffect(.degrees(degrees))
    }
}
