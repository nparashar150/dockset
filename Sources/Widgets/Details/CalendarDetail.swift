import AppKit
import EventKit
import SwiftUI

/// The whole of today, where the tile has room for the next thing only.
///
/// Nothing else in Docket reads EventKit yet - the calendar kind still draws
/// as `UnavailableTile` and there is no calendar service - so the panel talks
/// to the store itself and keeps what it reads in value types of its own. It
/// asks for access only when the user clicks for it, and when it has none it
/// says so in one line: a calendar showing a plausible day it made up is worse
/// than a calendar showing nothing.
struct CalendarDetail: View {
    /// See the list below: what fits the card every panel shares.
    private static let visibleRows = 3

    var instance: WidgetInstance
    var context: WidgetContext

    @State private var access = EKEventStore.authorizationStatus(for: .event)
    @State private var events: [DayEvent] = []
    @State private var calendars: [CalendarSource] = []
    /// The filter as the panel currently has it.
    ///
    /// The chrome hands the panel the instance it was opened with and never
    /// updates it, so a config write does not come back here - without a local
    /// copy, ticking a calendar off would change nothing until the panel was
    /// reopened. `nil` means "not touched yet, read the config".
    @State private var picked: Set<String>?

    private var store: EKEventStore { CalendarStore.shared }

    private var config: WidgetConfig { instance.config }

    /// Identifiers the widget was told to show. Empty means all of them, which
    /// is what the catalog default stores.
    private var chosen: Set<String> { picked ?? Set(config.strings("calendars")) }

    private var showsAllDay: Bool { config.bool("allDay", default: true) }

    private var granted: Bool { access == .fullAccess }

    /// Midnight of the day being shown. Derived from the tick, so the panel
    /// rolls over with the date rather than holding yesterday open.
    private var day: Date { Calendar.current.startOfDay(for: context.now) }

    var body: some View {
        // Calendar red, the colour of the date on a desk calendar's tear-off
        // page, with the date itself as the headline.
        DetailCard {
            MeshBackdrop(color: Color(red: 0.78, green: 0.2, blue: 0.22))
        } content: {
            VStack(alignment: .leading, spacing: 14) {
                heading
                if granted { agenda } else { permission }
            }
        }
        .onAppear { load() }
        // The chrome swaps its root view rather than rebuilding it, so this
        // view survives being reopened on another widget: the day has to be
        // re-read when the widget under it, or the date, changes.
        .onChange(of: instance.id) { _, _ in
            picked = nil
            load()
        }
        .onChange(of: day) { _, _ in load() }
        // An event added or moved elsewhere while the panel is open.
        .onReceive(NotificationCenter.default.publisher(for: .EKEventStoreChanged)) { _ in load() }
    }

    // MARK: Heading

    /// The day's number large, the weekday and month beside it: the page of
    /// a desk calendar rather than a heading that says "Today".
    private var heading: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(day.formatted(.dateTime.day()))
                .font(.system(size: 52, weight: .light))
                .monospacedDigit()
                .foregroundStyle(WidgetStyle.primary)
            VStack(alignment: .leading, spacing: 1) {
                Text(day.formatted(.dateTime.weekday(.wide)).uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(.white.opacity(0.8))
                Text(day.formatted(.dateTime.month(.wide).year()))
                    .font(WidgetStyle.label(14))
                    .foregroundStyle(WidgetStyle.primary)
            }
            .lineLimit(1)
            Spacer(minLength: 12)
            // Nothing to choose between with one calendar, and no filter to
            // offer without access - a button that opens an empty menu reads
            // as broken.
            if granted, calendars.count > 1 { picker }
        }
    }

    /// The only place the widget's `calendars` filter can be set: it has no
    /// editor in Settings, and an account carrying a dozen subscribed
    /// calendars fills the panel with events it did not ask about.
    private var picker: some View {
        Menu {
            Button("All Calendars") { apply([]) }
            Divider()
            ForEach(calendars) { calendar in
                Toggle(calendar.title, isOn: Binding(
                    get: { shows(calendar) },
                    set: { _ in toggle(calendar) }))
            }
        } label: {
            Text("Calendars…")
                .font(WidgetStyle.label(11))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.white.opacity(0.14), in: .capsule)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    // MARK: Agenda

    @ViewBuilder
    private var agenda: some View {
        let timed = events.filter { !$0.isAllDay }
        let allDay = showsAllDay ? events.filter(\.isAllDay) : []

        if timed.isEmpty, allDay.isEmpty {
            Text("Nothing scheduled today.")
                .font(WidgetStyle.label(13))
                .foregroundStyle(.white.opacity(0.8))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .glassPane()
        } else {
            // Three rows at most, so a busy day fits the card every panel
            // shares; the rest are counted under them, and Calendar has them.
            let shownTimed = Array(timed.prefix(Self.visibleRows))
            let shownAllDay = Array(allDay.prefix(max(0, Self.visibleRows - shownTimed.count)))
            let hidden = timed.count + allDay.count - shownTimed.count - shownAllDay.count
            VStack(alignment: .leading, spacing: 6) {
                // Time first, calendar second: two events at 10:30 are told
                // apart by the calendar, never the other way round.
                ForEach(shownTimed) { event in
                    row(event, detail: "\(clock(event.start)) · \(event.calendar)")
                }
            }
            if !shownAllDay.isEmpty {
                // Below the timed events, not mixed into them: an all-day
                // entry has no place in a list ordered by time.
                VStack(alignment: .leading, spacing: 6) {
                    Text("ALL DAY")
                        .font(.system(size: 9, weight: .semibold))
                        .tracking(0.6)
                        .foregroundStyle(.white.opacity(0.6))
                    ForEach(shownAllDay) { event in
                        row(event, detail: event.calendar)
                    }
                }
                .padding(.top, 2)
            }
            if hidden > 0 {
                Text("\(hidden) more today")
                    .font(WidgetStyle.caption(11))
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
    }

    private func row(_ event: DayEvent, detail: String) -> some View {
        HStack(alignment: .center, spacing: 10) {
            // The calendar's own colour as a bar down the row's edge, the
            // way the system's calendar marks an event.
            Capsule()
                .fill(event.color)
                .frame(width: 3.5, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(event.title)
                    .font(WidgetStyle.label(13))
                    .foregroundStyle(WidgetStyle.primary)
                Text(detail)
                    .font(WidgetStyle.caption(11))
                    .foregroundStyle(.white.opacity(0.7))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .glassPane(cornerRadius: 10)
        // Truncated rather than wrapped: the panel is sized once when it
        // opens, so a second line would be clipped by the window.
        .lineLimit(1)
        // A finished event is still part of the day, but it is not what the
        // panel was opened to find out.
        .opacity(event.isPast(context.now) ? 0.5 : 1)
        .accessibilityElement(children: .combine)
    }

    // MARK: No access

    private var permission: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(access == .notDetermined
                 ? "Docket has not been given access to your calendar."
                 : "Calendar access is off for Docket.")
                .font(WidgetStyle.caption(12))
                .foregroundStyle(.white.opacity(0.8))
                .fixedSize(horizontal: false, vertical: true)
            // Once the answer is no, asking again returns it unchanged with no
            // prompt on screen, so the only button worth drawing is the one
            // that goes where the answer can be changed.
            if access == .notDetermined {
                action("Allow Access") { request() }
            } else {
                action("Open Settings") { openPrivacySettings() }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func action(_ title: String, run: @escaping () -> Void) -> some View {
        Button {
            guard !context.isPreview else { return }
            run()
        } label: {
            Text(title)
                .font(WidgetStyle.label(13))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(Capsule().fill(.white.opacity(0.14)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: Store

    /// Reads the day straight through on the main actor.
    ///
    /// EventKit answers a single day out of its local cache, and the panel is
    /// laid out once when it opens; enumerating on a background queue would
    /// mean carrying `EKEvent`s - which are neither `Sendable` nor safe to
    /// keep - back across an isolation boundary for no gain.
    private func load() {
        guard !context.isPreview else { return }
        access = EKEventStore.authorizationStatus(for: .event)
        guard granted else {
            events = []
            calendars = []
            return
        }

        let all = store.calendars(for: .event)
        calendars = all
            .map(CalendarSource.init)
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }

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
            .compactMap(DayEvent.init)
            .sorted { $0.start == $1.start ? $0.title < $1.title : $0.start < $1.start }
    }

    /// The consent prompt, and the only thing that raises it, running solely
    /// because the user clicked for it.
    private func request() {
        Task { @MainActor in
            // A store made here rather than the shared one: the request is an
            // async call out of the main actor, and the shared store is
            // isolated to it, so it cannot be sent across.
            _ = try? await EKEventStore().requestFullAccessToEvents()
            // The store built before the grant keeps answering as if it had
            // none until it is told to look again.
            store.reset()
            load()
        }
    }

    private func openPrivacySettings() {
        guard let url = WidgetTarget.settings("com.apple.preference.security?Privacy_Calendars").settingsURL
        else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: Filter

    private func shows(_ calendar: CalendarSource) -> Bool {
        chosen.isEmpty || chosen.contains(calendar.id)
    }

    private func toggle(_ calendar: CalendarSource) {
        // An empty filter means every calendar, so the first thing unticked
        // has to start from the full set rather than from nothing.
        var wanted = chosen.isEmpty ? Set(calendars.map(\.id)) : chosen
        if wanted.contains(calendar.id) { wanted.remove(calendar.id) } else { wanted.insert(calendar.id) }
        // Everything ticked is the same as no filter, and storing it as the
        // empty list keeps a calendar subscribed to later visible.
        apply(wanted.count == calendars.count ? [] : calendars.map(\.id).filter(wanted.contains))
    }

    private func apply(_ identifiers: [String]) {
        guard !context.isPreview else { return }
        picked = Set(identifiers)
        WidgetWriter.write(instance) { config in
            config.set("calendars", .list(identifiers.map(WidgetConfig.Value.string)))
        }
        load()
    }

    private func clock(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }
}

/// One store, made the first time a calendar panel opens.
///
/// Held here rather than in `@State`: the panel is rebuilt on every tick of
/// the clock, and a store in state would mean a fresh connection to the
/// calendar daemon each second, all but one of them thrown away.
@MainActor
private enum CalendarStore {
    static let shared = EKEventStore()
}

/// One row, flattened off its `EKEvent` when the day is read.
///
/// The view keeps these instead of the events themselves: an `EKEvent` is a
/// live object the store may mutate or invalidate underneath the panel, and
/// Apple's own advice is to re-fetch rather than hold one.
private struct DayEvent: Identifiable, Hashable {
    var id: String
    var title: String
    var start: Date
    var end: Date
    var isAllDay: Bool
    var calendar: String
    var color: Color

    init?(_ event: EKEvent) {
        guard let start = event.startDate else { return nil }
        let title = (event.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        // Recurring instances share one identifier, so the start has to be
        // part of it or two occurrences on one day collide in the list.
        self.id = "\(event.eventIdentifier ?? event.calendarItemIdentifier)-\(start.timeIntervalSinceReferenceDate)"
        // An untitled event is a real event; the calendar apps call it this.
        self.title = title.isEmpty ? "New Event" : title
        self.start = start
        self.end = event.endDate ?? start
        self.isAllDay = event.isAllDay
        self.calendar = event.calendar?.title ?? ""
        self.color = CalendarSource.tint(event.calendar)
    }

    /// All-day entries never go grey: they are true for the whole day.
    func isPast(_ now: Date) -> Bool { !isAllDay && end <= now }
}

/// A calendar the account offers, for the filter menu and the row dots.
private struct CalendarSource: Identifiable, Hashable {
    var id: String
    var title: String
    var color: Color

    init(_ calendar: EKCalendar) {
        self.id = calendar.calendarIdentifier
        self.title = calendar.title
        self.color = CalendarSource.tint(calendar)
    }

    /// The calendar's own colour, which is the only thing that makes a list of
    /// dots mean anything. Falls back to the widget's accent rather than to a
    /// colour no calendar actually uses.
    static func tint(_ calendar: EKCalendar?) -> Color {
        guard let color = calendar?.color else {
            return Color(hex: WidgetCatalog.accentHex(.calendar) ?? PaletteColor.orange.hex)
        }
        return Color(nsColor: color)
    }
}
