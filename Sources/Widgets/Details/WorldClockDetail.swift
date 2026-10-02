import SwiftUI

/// The world clock said at length: the city's time to the second, its date,
/// how far it runs from here, and the next twelve hours in both places at once.
///
/// The strip is the part the tile can never be. A card shows one instant in one
/// city; the question anyone actually has about another zone is when the two
/// overlap. Every column is the same moment formatted twice, so nothing here is
/// predicted - the zone's own rules do the arithmetic, daylight saving changes
/// included.
///
/// One zone, because one widget carries one zone: `zone` and `city` are single
/// config keys, and a panel listing the shelf's other world clocks would have
/// to reach for state this window is not handed.
struct WorldClockDetail: View {
    var instance: WidgetInstance
    var context: WidgetContext

    /// The tile's keys and the tile's fallbacks, so the panel cannot report a
    /// different city than the card that opened it.
    private var zone: TimeZone {
        TimeZone(identifier: instance.config.string("zone", default: "Europe/London")) ?? .current
    }

    private var city: String { instance.config.string("city", default: "London") }

    var body: some View {
        // Never `context.now`: the chrome assigns its root view once, so the
        // frozen date would leave the seconds and the strip standing still.
        TimelineView(.periodic(from: .now, by: 1)) { tick in
            let now = tick.date
            // Their sky, not ours: the card is the time of day in the city.
            DetailCard {
                SkyBackdrop(date: now, zone: zone)
            } content: {
                VStack(alignment: .leading, spacing: 8) {
                    headline(now)

                    HStack(spacing: 8) {
                        StatChip(label: "Here", value: ClockFormat.time(now, zone: .current))
                            .frame(width: 88)
                        StatChip(label: "Difference",
                                 value: ClockPanelFormat.difference(zone, at: now))
                    }

                    strip(now)
                        .padding(10)
                        .glassPane()
                }
            }
        }
    }

    // MARK: Headline

    private func headline(_ now: Date) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                ClockPanelTime(now: now, zone: zone, size: 34)
                Text(city)
                    .font(WidgetStyle.label(15))
                    .foregroundStyle(WidgetStyle.primary)
                // The tile's own "Tomorrow" / "Yesterday", against a date the
                // tile only ever has room to abbreviate.
                Text([ClockPanelFormat.fullDate(now, zone: zone),
                      WorldClockTile.dayHint(now, zone: zone)]
                        .compactMap { $0 }.joined(separator: " · "))
                    .font(WidgetStyle.caption(11))
                    .foregroundStyle(WidgetStyle.secondary)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            Spacer(minLength: 0)
        }
    }

    // MARK: Twelve hours

    /// Your hours along the top, theirs underneath, shaded where their day is.
    ///
    /// Read as a pair of rows it answers the only question the tile provokes:
    /// what time is it there when it is a reasonable hour here.
    private func strip(_ now: Date) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 2) {
                ForEach(Self.hours(from: now), id: \.self) { hour in
                    VStack(spacing: 3) {
                        Text(Self.hourLabel(hour, zone: .current))
                            .font(WidgetStyle.caption(10))
                            .foregroundStyle(WidgetStyle.secondary)
                        Text(Self.hourLabel(hour, zone: zone))
                            .font(WidgetStyle.label(11))
                            .foregroundStyle(WidgetStyle.primary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 3)
                            .background {
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .fill(Self.isDaylight(hour, zone: zone)
                                          ? Color(red: 1, green: 0.85, blue: 0.5).opacity(0.22) : .clear)
                            }
                    }
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(maxWidth: .infinity)
                }
            }
            HStack(spacing: 12) {
                Text("Next 12 hours")
                    .font(WidgetStyle.caption(10))
                    .foregroundStyle(WidgetStyle.secondary)
                Spacer(minLength: 0)
                // Names the band rather than implying a sunrise, see below.
                Text("Shaded 6am–6pm in \(city)")
                    .font(WidgetStyle.caption(10))
                    .foregroundStyle(WidgetStyle.secondary)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.8)
        }
    }

    /// This hour there and the eleven after it, taken from the local hour
    /// boundary so the columns line up with a clock rather than with whenever
    /// the panel happened to open.
    private static func hours(from now: Date) -> [Date] {
        let start = Calendar.current.dateInterval(of: .hour, for: now)?.start ?? now
        return (0..<12).compactMap { Calendar.current.date(byAdding: .hour, value: $0, to: start) }
    }

    /// The hour alone, as the weather strip does it: twelve columns have no
    /// room for "2 PM", and read together they are an axis rather than a clock.
    private static func hourLabel(_ date: Date, zone: TimeZone) -> String {
        var style = Date.FormatStyle.dateTime.hour(.defaultDigits(amPM: .omitted))
        style.timeZone = zone
        return date.formatted(style)
    }

    /// Daytime by the clock - 6am to 6pm - and not by the sun.
    ///
    /// Nothing in the app knows when the sun rises in an arbitrary city: the
    /// weather service holds one place and carries no sunrise even for that,
    /// and a second request for a shaded strip is not worth making. A stated
    /// band is honest, an implied sunrise is not, which is why the caption
    /// under the strip names the hours out loud.
    private static func isDaylight(_ date: Date, zone: TimeZone) -> Bool {
        var calendar = Calendar.current
        calendar.timeZone = zone
        return (6..<18).contains(calendar.component(.hour, from: date))
    }
}
