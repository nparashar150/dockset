import AppKit
import EventKit
import SwiftUI

/// Everything already due, which is the one thing a reminders card can never
/// hold: the tile has room for a count or the next item, and the backlog
/// behind that count is the reason anyone opens it.
///
/// Like `CalendarDetail`, this talks to EventKit itself - the reminders kind
/// still draws as `UnavailableTile` and no service reads reminders - and keeps
/// what it finds in value types of its own. Access is asked for only when the
/// user clicks for it, and without it the panel says so in a line rather than
/// showing a list it made up.
///
/// Only what EventKit hands back for an incomplete reminder due by tonight: a
/// title, a due date, its list and that list's colour, and whether it is
/// flagged high priority. Nothing is completed, created or edited here - the
/// panel reads.
struct RemindersDetail: View {
    var instance: WidgetInstance
    var context: WidgetContext

    @State private var access = EKEventStore.authorizationStatus(for: .reminder)
    @State private var rows: [DueReminder] = []
    /// List colours, resolved on the main actor when the fetch is started:
    /// an `EKCalendar` cannot be carried out of the fetch's completion, and a
    /// dot in a list's own colour is the only thing that tells two identical
    /// titles apart.
    @State private var tints: [String: Color] = [:]
    /// Fetches are async and the panel can be pointed at another widget while
    /// one is in flight; only the newest is allowed to land.
    @State private var generation = 0

    private var store: EKEventStore { ReminderStore.shared }

    private var granted: Bool { access == .fullAccess }

    /// The list the widget was configured for, by title. Empty - the catalog
    /// default - means every list.
    private var listFilter: String {
        instance.config.string("list").trimmingCharacters(in: .whitespaces)
    }

    /// How many rows the panel will draw before it starts counting instead.
    ///
    /// A day's events are bounded; a backlog of overdue reminders is not, and
    /// the chrome sizes itself to its content, so an unbounded list would grow
    /// a panel taller than the screen.
    /// Four, so the list fits the card every panel shares; the rest are
    /// counted in a line under it rather than growing the panel.
    private static let visibleRows = 4

    var body: some View {
        // Minute by minute, not from `context.now`: the chrome assigns this
        // view once, so the frozen tick would keep a reminder sitting under
        // "Today" long after its time had passed.
        TimelineView(.periodic(from: .now, by: 60)) { timeline in
            content(now: timeline.date)
                // The fetch asks for everything due by tonight, so at midnight
                // the window itself has moved on.
                .onChange(of: Calendar.current.startOfDay(for: timeline.date)) { _, _ in load() }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { load() }
        // The chrome swaps its root view rather than rebuilding it, so this
        // view survives being reopened on another widget.
        .onChange(of: instance.id) { _, _ in load() }
        // A reminder ticked off in Reminders.app while the panel is open.
        .onReceive(NotificationCenter.default.publisher(for: .EKEventStoreChanged)) { _ in load() }
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        let overdue = rows.filter { $0.isOverdue(now) }
        let today = rows.filter { !$0.isOverdue(now) }

        // Red once anything is late, the widget's own colour otherwise: the
        // card says whether you are behind before a title is read.
        DetailCard {
            MeshBackdrop(color: overdue.isEmpty ? Self.fallbackTint : Color(hex: PaletteColor.red.hex))
        } content: {
            VStack(alignment: .leading, spacing: 14) {
                if granted {
                    summary(overdue: overdue.count, today: today.count)
                    if !rows.isEmpty {
                        list(overdue: overdue, today: today)
                    }
                } else {
                    permission
                }
            }
        }
    }

    // MARK: Summary

    /// The two counts, which is what the sections below cannot say once the
    /// list is cut off at `visibleRows`.
    private func summary(overdue: Int, today: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(rows.count)")
                    .font(.system(size: 56, weight: .semibold, design: .rounded))
                    .foregroundStyle(WidgetStyle.primary)
                    .monospacedDigit()
                    .rollingValue(rows.count)
                VStack(alignment: .leading, spacing: 0) {
                    Text(rows.isEmpty ? "Nothing due today" : "due by tonight")
                        .font(WidgetStyle.label(14))
                        .foregroundStyle(.white.opacity(0.85))
                    // Which list this is a view of, when it is not all of them
                    // - otherwise the count reads as the whole account and is
                    // not.
                    if !listFilter.isEmpty {
                        Text(listFilter)
                            .font(WidgetStyle.caption(11))
                            .foregroundStyle(.white.opacity(0.65))
                    }
                }
            }
            .lineLimit(1)
            if !rows.isEmpty {
                HStack(spacing: 8) {
                    StatChip(label: "Overdue", value: "\(overdue)")
                    StatChip(label: "Today", value: "\(today)")
                }
            }
        }
    }

    // MARK: List

    /// Overdue first, then the rest of today, each in due order.
    ///
    /// Two labelled sections rather than one stream: "yesterday 09:00" and
    /// "18:00" sitting in the same list look like the same kind of thing, and
    /// the whole point of the panel is that they are not.
    @ViewBuilder
    private func list(overdue: [DueReminder], today: [DueReminder]) -> some View {
        // The cut falls on the overdue block first: what is already late
        // outranks what is merely coming.
        let shownOverdue = Array(overdue.prefix(Self.visibleRows))
        let shownToday = Array(today.prefix(max(0, Self.visibleRows - shownOverdue.count)))
        let hidden = rows.count - shownOverdue.count - shownToday.count

        VStack(alignment: .leading, spacing: 12) {
            section("Overdue", shownOverdue, tint: .white)
            section("Today", shownToday, tint: .white.opacity(0.7))
            if hidden > 0 {
                Text("\(hidden) more in Reminders")
                    .font(WidgetStyle.caption(11))
                    .foregroundStyle(WidgetStyle.secondary)
            }
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ items: [DueReminder], tint: Color) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(title.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(tint)
                ForEach(items) { item in
                    row(item)
                }
            }
        }
    }

    private func row(_ item: DueReminder) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Circle()
                .fill(tints[item.listID] ?? Self.fallbackTint)
                .frame(width: 7, height: 7)
                // Aligned to the cap of the title, not the middle of the row.
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(item.title)
                        .font(WidgetStyle.label(13))
                        .foregroundStyle(WidgetStyle.primary)
                    // Reminders.app's own flag, and the only ranking EventKit
                    // gives that a due-date sort throws away.
                    if item.isHighPriority {
                        Text("!")
                            .font(WidgetStyle.label(13))
                            .foregroundStyle(Color(hex: PaletteColor.orange.hex))
                    }
                }
                Text(detail(item))
                    .font(WidgetStyle.caption(11))
                    .foregroundStyle(WidgetStyle.secondary)
            }
            Spacer(minLength: 0)
        }
        // Truncated rather than wrapped: the panel is sized once when it
        // opens, so a second line would be clipped by the window.
        .lineLimit(1)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .glassPane(cornerRadius: 10)
        .accessibilityElement(children: .combine)
    }

    /// When it was due, then which list it is on - two reminders at 09:00 are
    /// told apart by the list, never the other way round.
    private func detail(_ item: DueReminder) -> String {
        let when = item.hasTime
            ? item.due.formatted(date: .omitted, time: .shortened)
            : "All day"
        // The day only earns its place once the reminder is older than today;
        // everything here is due by tonight, so anything else is today's.
        let day = Calendar.current.isDateInToday(item.due)
            ? ""
            : item.due.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)) + " "
        return item.list.isEmpty ? day + when : "\(day)\(when), \(item.list)"
    }

    // MARK: No access

    private var permission: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(access == .notDetermined
                 ? "Docket has not been given access to your reminders."
                 : "Reminders access is off for Docket.")
                .font(WidgetStyle.caption(12))
                .foregroundStyle(WidgetStyle.secondary)
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

    /// Everything incomplete and dated up to the end of today, which is
    /// overdue and today's in one predicate. Reminders with no due date are
    /// not returned by a dated predicate, and the panel does not pretend
    /// otherwise: it is a list of what is *due*.
    private func load() {
        guard !context.isPreview else { return }
        access = EKEventStore.authorizationStatus(for: .reminder)
        guard granted else {
            rows = []
            tints = [:]
            return
        }

        let lists = store.calendars(for: .reminder)
        // Two lists can share a title across accounts, so first wins rather
        // than trapping on the duplicate key.
        tints = Dictionary(lists.map { ($0.calendarIdentifier, Color(nsColor: $0.color ?? .controlAccentColor)) },
                           uniquingKeysWith: { first, _ in first })
        // A filter naming a list that has since been deleted falls back to the
        // whole account: a predicate over no lists matches nothing, and an
        // empty panel would read as "nothing due".
        let scope = listFilter.isEmpty ? lists : lists.filter { $0.title == listFilter }
        let wanted = scope.isEmpty ? lists : scope
        guard !wanted.isEmpty,
              let end = Calendar.current.date(byAdding: .day, value: 1,
                                              to: Calendar.current.startOfDay(for: Date())) else {
            rows = []
            return
        }

        generation += 1
        let token = generation
        let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil,
                                                              ending: end,
                                                              calendars: wanted)
        Task { @MainActor in
            // Flattened inside the completion: an `EKReminder` is a live
            // object the store may mutate or invalidate, and it is not safe to
            // carry back across the hop.
            let fetched: [DueReminder] = await withCheckedContinuation { continuation in
                store.fetchReminders(matching: predicate) { reminders in
                    continuation.resume(returning: (reminders ?? []).compactMap(DueReminder.init))
                }
            }
            guard token == generation else { return }
            rows = fetched.sorted {
                $0.due == $1.due ? $0.title < $1.title : $0.due < $1.due
            }
        }
    }

    /// The consent prompt, and the only thing that raises it, running solely
    /// because the user clicked for it. `NSRemindersFullAccessUsageDescription`
    /// is in Info.plist, which is what keeps this from terminating the app.
    private func request() {
        Task { @MainActor in
            // A store made here rather than the shared one: the request is an
            // async call out of the main actor, and the shared store is
            // isolated to it.
            _ = try? await EKEventStore().requestFullAccessToReminders()
            // The store built before the grant keeps answering as if it had
            // none until it is told to look again.
            store.reset()
            load()
        }
    }

    private func openPrivacySettings() {
        guard let url = WidgetTarget.settings("com.apple.preference.security?Privacy_Reminders").settingsURL
        else { return }
        NSWorkspace.shared.open(url)
    }

    /// A list with no colour of its own falls back to the widget's accent
    /// rather than to a colour no list actually uses.
    private static let fallbackTint = Color(hex: WidgetCatalog.accentHex(.reminders) ?? PaletteColor.orange.hex)
}

/// One store, made the first time a reminders panel opens.
///
/// Held here rather than in `@State`: the panel is rebuilt on every tick, and
/// a store in state would mean a fresh connection to the reminders daemon each
/// time, all but one of them thrown away.
@MainActor
private enum ReminderStore {
    static let shared = EKEventStore()
}

/// One row, flattened off its `EKReminder` as the fetch returns.
private struct DueReminder: Identifiable, Hashable, Sendable {
    var id: String
    var title: String
    var due: Date
    /// False for a reminder set for a day with no time of day, which is due
    /// all day and not at midnight.
    var hasTime: Bool
    var list: String
    var listID: String
    var isHighPriority: Bool

    init?(_ reminder: EKReminder) {
        guard let components = reminder.dueDateComponents,
              // `date` is nil unless the components carry a calendar, which
              // EventKit does not promise.
              let due = components.date ?? Calendar.current.date(from: components)
        else { return nil }
        self.id = reminder.calendarItemIdentifier
        let title = (reminder.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        // An untitled reminder is still a real reminder; Reminders.app shows
        // the row empty, which here would be a dot with nothing beside it.
        self.title = title.isEmpty ? "New Reminder" : title
        self.due = due
        self.hasTime = components.hour != nil
        self.list = reminder.calendar?.title ?? ""
        self.listID = reminder.calendar?.calendarIdentifier ?? ""
        // EventKit's priority runs 1–9 with 0 for none; Reminders.app's own
        // "High" flag is 1–4.
        self.isHighPriority = (1...4).contains(reminder.priority)
    }

    /// A dated reminder is late the moment its time passes. One set for a day
    /// with no time is late only once that day is over.
    func isOverdue(_ now: Date) -> Bool {
        hasTime ? due < now : due < Calendar.current.startOfDay(for: now)
    }
}
