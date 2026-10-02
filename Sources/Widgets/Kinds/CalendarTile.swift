import AppKit
import EventKit
import SwiftUI

/// Today's date and what is next on it. The whole day belongs to the panel.
///
/// Reads EventKit exactly the way `CalendarDetail` does - one single-day fetch
/// on the main actor, every `EKEvent` flattened into a value type the moment
/// the fetch returns - with one difference that matters: it never asks for
/// access. The shelf draws every tile it has the instant it appears, so a tile
/// that requested consent would raise a prompt nobody clicked for, from a
/// process that never becomes frontmost. The panel owns the request; until the
/// answer changes, the tile says which of the two states it is in.
struct CalendarTile: View {
    var instance: WidgetInstance
    var context: WidgetContext

    @State private var access = EKEventStore.authorizationStatus(for: .event)
    @State private var events: [TileEvent] = []

    private var layout: String { instance.config.string("layout", default: "nextEvent") }

    private var showsAllDay: Bool { instance.config.bool("allDay", default: true) }

    /// Identifiers the widget was told to show. Empty means all of them, which
    /// is what the catalog default stores and what the panel's filter writes.
    private var chosen: Set<String> { Set(instance.config.strings("calendars")) }

    /// Only full access can read a day; write-only is no better than none here.
    private var hasAccess: Bool { context.isPreview || access == .fullAccess }

    /// The date layouts are a calendar page, not an agenda, so a shelf full of
    /// them never touches EventKit at all.
    private var needsEvents: Bool { layout != "date" }

    /// Midnight of the day being drawn. Derived from the tick, so the tile
    /// turns the page rather than holding yesterday open.
    private var day: Date { Calendar.current.startOfDay(for: context.now) }

    var body: some View {
        WidgetSurface {
            Group {
                if context.position.isVertical { column } else { wide }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { load() }
        .onChange(of: instance.config.strings("calendars")) { _, _ in load() }
        // `now` ticks every second; a day out of the local cache is cheap but
        // not free. Five minutes is coarse enough to be invisible and still
        // lands on midnight, which is when the page has to turn - and it is
        // also what picks up access granted from the panel, whose store is
        // not this one.
        .onChange(of: Int(context.now.timeIntervalSince1970) / 300) { _, _ in load() }
        // An event added or moved in Calendar while the shelf is up.
        .onReceive(NotificationCenter.default.publisher(for: .EKEventStoreChanged)) { _ in load() }
    }

    // MARK: Wide layouts

    @ViewBuilder
    private var wide: some View {
        switch layout {
        case "date":
            dateBlock(weekday: 12, day: 28)
        case "dateAndEvent":
            HStack(spacing: 12) {
                dateBlock(weekday: 10, day: 24)
                nextEvent
            }
        case "agenda":
            HStack(spacing: 12) {
                dateBlock(weekday: 10, day: 24)
                agenda
            }
        default:
            nextEvent
        }
    }

    /// Title over "time · calendar", which is the panel's own row: two events
    /// at the same hour are told apart by the calendar they came from.
    @ViewBuilder
    private var nextEvent: some View {
        if let event = upcoming.first {
            HStack(alignment: .top, spacing: 8) {
                dot(event.color, size: 7)
                    // Aligned to the cap of the title, not the middle of the
                    // two-line block.
                    .padding(.top, 4)
                VStack(alignment: .leading, spacing: 1) {
                    // The shelf's value and caption styles, a step down for a
                    // title that is words rather than a figure.
                    Text(event.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(WidgetStyle.primary)
                    Text(event.detail)
                        .font(.system(size: 12))
                        .foregroundStyle(WidgetStyle.secondary)
                }
                Spacer(minLength: 0)
            }
            // Truncated rather than wrapped: a second line would not fit the
            // card, and half a clipped title is worse than an honest ellipsis.
            .lineLimit(1)
        } else {
            note(stateLine)
        }
    }

    /// The next few entries, one line each. Three is what a 58pt card holds at
    /// a size that can still be read across a desk.
    @ViewBuilder
    private var agenda: some View {
        let rows = Array(upcoming.prefix(3))
        if rows.isEmpty {
            note(stateLine)
        } else {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(rows) { event in
                    HStack(spacing: 6) {
                        dot(event.color, size: 6)
                        Text(event.timeText)
                            .font(WidgetStyle.label(11))
                            .foregroundStyle(WidgetStyle.primary)
                            .monospacedDigit()
                            // Fixed column so the titles line up under each
                            // other instead of stepping in and out with the
                            // width of each time.
                            .frame(width: 54, alignment: .leading)
                        Text(event.title)
                            .font(WidgetStyle.caption(11))
                            .foregroundStyle(WidgetStyle.secondary)
                        Spacer(minLength: 0)
                    }
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.8)
        }
    }

    // MARK: Column layouts
    //
    // 56pt of usable width and 76pt of height. Four layouts do not survive
    // that intact: "Date + agenda" is the one that genuinely cannot, because
    // three rows of "09:30  Standup" here would each be squeezed past reading
    // size, so it degrades to the date over the single next event - the same
    // thing "Date + next event" shows, which is the part of an agenda a column
    // can actually carry. The rest of the day is one click away in the panel.

    @ViewBuilder
    private var column: some View {
        switch layout {
        case "date":
            dateBlock(weekday: 11, day: 27)
        case "nextEvent":
            columnEvent
        default:
            VStack(spacing: 4) {
                dateBlock(weekday: 9, day: 20)
                columnEvent
            }
        }
    }

    /// Time first and biggest: with no room for a calendar name, the clock is
    /// the only part of a row that is useful at a glance.
    @ViewBuilder
    private var columnEvent: some View {
        if let event = upcoming.first {
            VStack(spacing: 1) {
                HStack(spacing: 3) {
                    dot(event.color, size: 5)
                    // One line that shrinks: in a 76pt column "9:30 AM" wrapped
                    // its meridiem onto a line of its own.
                    Text(event.timeText)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(WidgetStyle.primary)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
                Text(event.title)
                    .font(.system(size: 11))
                    .foregroundStyle(WidgetStyle.secondary)
                    .lineLimit(layout == "nextEvent" ? 2 : 1)
                    .multilineTextAlignment(.center)
            }
            .minimumScaleFactor(0.6)
        } else {
            Text(shortStateLine)
                .font(.system(size: 11))
                .foregroundStyle(WidgetStyle.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
        }
    }

    // MARK: Pieces

    /// Weekday over the day number, the calendar page every Dock has had since
    /// there were Docks. Sized to its content so the agenda beside it keeps
    /// every point it is not using.
    private func dateBlock(weekday: CGFloat, day: CGFloat) -> some View {
        VStack(spacing: 0) {
            // Grey, not the calendar's red: colour on the shelf is kept to
            // small marks, and the dots beside each event already carry it.
            Text(context.now.formatted(.dateTime.weekday(.abbreviated)).uppercased())
                .font(WidgetStyle.label(weekday))
                .foregroundStyle(WidgetStyle.secondary)
            Text(context.now.formatted(.dateTime.day()))
                .font(WidgetStyle.value(day))
                .foregroundStyle(WidgetStyle.primary)
                .monospacedDigit()
        }
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .fixedSize()
    }

    /// The calendar's own colour, the one thing that says which calendar a row
    /// came from when there is no room to name it.
    private func dot(_ color: Color, size: CGFloat) -> some View {
        Circle().fill(color).frame(width: size, height: size)
    }

    private func note(_ text: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: hasAccess ? "calendar" : "calendar.badge.exclamationmark")
                .font(.system(size: 14))
                .foregroundStyle(WidgetStyle.secondary)
            Text(text)
                .font(WidgetStyle.caption(12))
                .foregroundStyle(WidgetStyle.secondary)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    // MARK: What the tile has to say

    /// The shortest honest version of what the panel says at length. Never a
    /// truncation of it, and never a plausible empty day standing in for a day
    /// the tile was not allowed to read.
    private var stateLine: String {
        guard hasAccess else {
            return access == .notDetermined ? "Calendar access not granted" : "Calendar access is off"
        }
        return dayEvents.isEmpty ? "Nothing scheduled" : "Nothing left today"
    }

    /// The same four states in the width a column has for them.
    private var shortStateLine: String {
        guard hasAccess else {
            return access == .notDetermined ? "No access yet" : "Access is off"
        }
        return dayEvents.isEmpty ? "Nothing scheduled" : "Nothing left"
    }

    // MARK: Data

    /// Everything on today that this widget was configured to count.
    private var dayEvents: [TileEvent] {
        // The library has no store behind it and must not reach for one.
        let all = context.isPreview ? TileEvent.samples(on: day) : events
        return showsAllDay ? all : all.filter { !$0.isAllDay }
    }

    private var upcoming: [TileEvent] {
        // Nothing in the library is in the past: the samples are the whole of
        // its day, and hiding them after lunch would leave the preview blank.
        let ahead = context.isPreview ? dayEvents : dayEvents.filter { $0.end > context.now }
        // Timed first, all-day after, which is the order the panel lists them
        // in: an entry with no time does not belong in a queue sorted by time.
        return ahead.filter { !$0.isAllDay } + ahead.filter(\.isAllDay)
    }

    /// Reads the day straight through on the main actor, as the panel does:
    /// EventKit answers a single day out of its local cache, and carrying
    /// `EKEvent`s - neither `Sendable` nor safe to hold - across an isolation
    /// boundary would buy nothing.
    private func load() {
        guard !context.isPreview, needsEvents else { return }

        let status = EKEventStore.authorizationStatus(for: .event)
        // A store built before the grant keeps answering as if it had none
        // until it is told to look again.
        if status != access { CalendarTileStore.shared.reset() }
        access = status
        guard status == .fullAccess else {
            events = []
            return
        }

        let store = CalendarTileStore.shared
        let all = store.calendars(for: .event)
        let wanted = all.filter { chosen.contains($0.calendarIdentifier) }
        // A predicate over no calendars matches nothing, so a filter whose
        // identifiers have all since disappeared falls back to the whole
        // account rather than to an empty day.
        let scope = wanted.isEmpty ? all : wanted
        guard !scope.isEmpty,
              let end = Calendar.current.date(byAdding: .day, value: 1, to: day) else {
            events = []
            return
        }

        let predicate = store.predicateForEvents(withStart: day, end: end, calendars: scope)
        events = store.events(matching: predicate)
            .compactMap(TileEvent.init)
            .sorted { $0.start == $1.start ? $0.title < $1.title : $0.start < $1.start }
    }
}

/// One store, made the first time a calendar tile is drawn.
///
/// Held here rather than in `@State`: the tile is rebuilt on every tick of the
/// clock, and a store in state would mean a fresh connection to the calendar
/// daemon each second, all but one of them thrown away. Making it costs
/// nothing and prompts for nothing; only a request for access would.
@MainActor
private enum CalendarTileStore {
    static let shared = EKEventStore()
}

/// The widget's accent, for the date block and for an event whose calendar has
/// no colour of its own.

/// The dot an event gets when its calendar has no colour of its own.
private let calendarAccent = Color(hex: WidgetCatalog.accentHex(.calendar) ?? PaletteColor.orange.hex)

/// One entry, flattened off its `EKEvent` when the day is read.
///
/// The tile keeps these instead of the events themselves: an `EKEvent` is a
/// live object the store may mutate or invalidate underneath the shelf, and
/// Apple's own advice is to re-fetch rather than hold one.
private struct TileEvent: Identifiable, Hashable {
    var id: String
    var title: String
    var start: Date
    var end: Date
    var isAllDay: Bool
    var calendar: String
    var color: Color

    init(id: String, title: String, start: Date, end: Date,
         isAllDay: Bool = false, calendar: String, color: Color) {
        self.id = id
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.calendar = calendar
        self.color = color
    }

    init?(_ event: EKEvent) {
        guard let start = event.startDate else { return nil }
        let title = (event.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        self.init(
            // Recurring instances share one identifier, so the start has to be
            // part of it or two occurrences on one day collide in the list.
            id: "\(event.eventIdentifier ?? event.calendarItemIdentifier)-\(start.timeIntervalSinceReferenceDate)",
            // An untitled event is a real event; the calendar apps call it this.
            title: title.isEmpty ? "New Event" : title,
            start: start,
            end: event.endDate ?? start,
            isAllDay: event.isAllDay,
            calendar: event.calendar?.title ?? "",
            color: Self.tint(event.calendar))
    }

    /// The calendar's own colour, which is the only thing that makes a dot
    /// mean anything. Falls back to the widget's accent rather than to a
    /// colour no calendar actually uses.
    static func tint(_ calendar: EKCalendar?) -> Color {
        guard let color = calendar?.color else { return calendarAccent }
        return Color(nsColor: color)
    }

    /// Where the clock goes for something that has no clock.
    var timeText: String {
        isAllDay ? "All day" : start.formatted(date: .omitted, time: .shortened)
    }

    /// The panel's second line, and a calendar with no name does not earn a
    /// separator to itself.
    var detail: String {
        calendar.isEmpty ? timeText : "\(timeText) · \(calendar)"
    }

    /// A representative day for the widget library, which has no store behind
    /// it. Anchored to the date being drawn so the ids hold still between
    /// ticks rather than churning the list once a second.
    static func samples(on day: Date) -> [TileEvent] {
        let calendar = Calendar.current
        func at(_ hour: Int, _ minute: Int) -> Date {
            calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
        }
        return [
            TileEvent(id: "sample-review", title: "Design Review",
                      start: at(9, 30), end: at(10, 15),
                      calendar: "Work", color: calendarAccent),
            TileEvent(id: "sample-one", title: "1:1 with Sam",
                      start: at(11, 0), end: at(11, 30),
                      calendar: "Work", color: Color(hex: PaletteColor.blue.hex)),
            TileEvent(id: "sample-lunch", title: "Team Lunch",
                      start: at(13, 0), end: at(14, 0),
                      calendar: "Personal", color: Color(hex: PaletteColor.green.hex))
        ]
    }
}
