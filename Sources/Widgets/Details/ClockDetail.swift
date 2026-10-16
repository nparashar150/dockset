import SwiftUI

/// The local clock said at length: the time to the second, the date written
/// out in full, and the zone the machine is actually keeping.
///
/// The thinnest panel in the app, deliberately. A clock knows the time and
/// nothing else, so the honest list of what its tile leaves out is short -
/// seconds, the weekday and year the card has to abbreviate away, and the name
/// of the zone. Anything more would be invented reasons to be large.
struct ClockDetail: View {
    var instance: WidgetInstance
    var context: WidgetContext

    var body: some View {
        // The seconds have to be driven from here. `WidgetDetailChrome`
        // assigns its root view once when the panel opens, so `context.now` is
        // frozen for as long as it stays up and a second hand read from it
        // would sit perfectly still.
        TimelineView(.periodic(from: .now, by: 1)) { tick in
            let now = tick.date
            // On the sky for this hour, with the sun where it is: the panel
            // is the time of day before it is a number.
            DetailCard(dark: true) {
                SkyBackdrop(date: now, zone: .current)
            } content: {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 2) {
                        ClockPanelTime(now: now, zone: .current, size: 46)
                        Text(ClockPanelFormat.fullDate(now, zone: .current))
                            .font(WidgetStyle.label(13))
                            .foregroundStyle(Color.panelInk.opacity(0.8))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    .padding(.top, 18)

                    HStack(spacing: 8) {
                        StatChip(label: "Time zone",
                                 value: ClockPanelFormat.zoneName(.current, at: now))
                        StatChip(label: "UTC", value: ClockPanelFormat.gmt(.current, at: now))
                            .frame(width: 92)
                    }
                }
            }
        }
    }
}

// MARK: - Shared panel parts
//
// Clock and World Clock are one panel pointed at two different zones, the same
// way their tiles are one readout pointed at two different zones. These live
// here for the same reason `ClockReadout` lives in ClockTile.swift.

/// The time to the second, in whichever clock the locale runs.
///
/// Built from the tile's own formatter rather than a second one, so the panel
/// and the card that opened it can never disagree about 24h versus 12h. The
/// seconds and the meridiem are stepped down and greyed: they are what the
/// panel adds, not what it leads with.
struct ClockPanelTime: View {
    var now: Date
    var zone: TimeZone
    var size: CGFloat

    var body: some View {
        let parts = ClockFormat.compactTime(now, zone: zone)
        let seconds = ClockPanelFormat.seconds(now, zone: zone)
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            Text(parts.time)
                .font(WidgetStyle.value(size))
                .foregroundStyle(WidgetStyle.primary)
                .monospacedDigit()
                .rollingValue(parts.time)
            Text(":\(seconds)")
                .font(WidgetStyle.value(size * 0.5))
                .foregroundStyle(WidgetStyle.secondary)
                .monospacedDigit()
                .rollingValue(seconds)
            if let meridiem = parts.meridiem {
                Text(meridiem)
                    .font(WidgetStyle.label(size * 0.36))
                    .foregroundStyle(WidgetStyle.secondary)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }
}

/// A label and a figure on one line - the row idiom the system panel uses.
struct ClockPanelRow: View {
    var label: String
    var value: String

    var body: some View {
        HStack(spacing: 12) {
            Text(label)
                .font(WidgetStyle.caption(11))
                .foregroundStyle(WidgetStyle.secondary)
            Spacer(minLength: 0)
            Text(value)
                .font(WidgetStyle.label(11))
                .monospacedDigit()
                .foregroundStyle(WidgetStyle.primary)
                .rollingValue(value)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }
}

/// What the panels add to `ClockFormat`, which stops at what a tile can fit.
enum ClockPanelFormat {
    /// The date the tile abbreviates to "Fri, 25 Sep", written out.
    static func fullDate(_ date: Date, zone: TimeZone) -> String {
        var style = Date.FormatStyle.dateTime.weekday(.wide).day().month(.wide).year()
        style.timeZone = zone
        return date.formatted(style)
    }

    /// Two digits always, so the figure beside the minutes does not jump width
    /// nine times a minute.
    static func seconds(_ date: Date, zone: TimeZone) -> String {
        var calendar = Calendar.current
        calendar.timeZone = zone
        let value = calendar.component(.second, from: date)
        return value < 10 ? "0\(value)" : "\(value)"
    }

    /// The zone as the system names it, and named for the half of the year it
    /// is currently in: a zone on summer time is "British Summer Time", not
    /// the standard name it will go back to in October.
    static func zoneName(_ zone: TimeZone, at date: Date) -> String {
        let style: NSTimeZone.NameStyle = zone.isDaylightSavingTime(for: date)
            ? .daylightSaving : .standard
        return zone.localizedName(for: style, locale: .current) ?? zone.identifier
    }

    /// "GMT+1", "GMT+5:30". Minutes only where the zone has them, and the
    /// typographic minus so the sign carries the digits' own weight.
    static func gmt(_ zone: TimeZone, at date: Date) -> String {
        let total = zone.secondsFromGMT(for: date)
        let sign = total < 0 ? "\u{2212}" : "+"
        let minutes = abs(total) / 60
        let rest = minutes % 60
        guard rest != 0 else { return "GMT\(sign)\(minutes / 60)" }
        return "GMT\(sign)\(minutes / 60):\(rest < 10 ? "0" : "")\(rest)"
    }

    /// How far a zone runs from this one, in words. Computed at a date rather
    /// than in the abstract because the gap moves twice a year, and the two
    /// zones rarely change on the same weekend.
    static func difference(_ zone: TimeZone, at date: Date) -> String {
        let delta = zone.secondsFromGMT(for: date) - TimeZone.current.secondsFromGMT(for: date)
        guard delta != 0 else { return "Same time as here" }
        let minutes = abs(delta) / 60
        var parts: [String] = []
        if minutes / 60 > 0 { parts.append("\(minutes / 60) hour\(minutes / 60 == 1 ? "" : "s")") }
        if minutes % 60 > 0 { parts.append("\(minutes % 60) min") }
        return parts.joined(separator: " ") + (delta > 0 ? " ahead" : " behind")
    }
}
