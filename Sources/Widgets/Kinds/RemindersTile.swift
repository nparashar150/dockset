import EventKit
import SwiftUI

/// What is due today, on a card 58pt tall.
///
/// The tile is the glance and `RemindersDetail` is the backlog behind it, so
/// the two read the same thing the same way: everything incomplete and dated
/// up to the end of today, overdue told apart from merely due, and a list
/// filter by title that only narrows what is counted.
///
/// EventKit is read here rather than through a service because none exists for
/// reminders; the panel does the same. Nothing is completed or edited from the
/// tile, and crucially nothing is *requested* from it: a shelf being drawn must
/// never raise a consent prompt, so the tile reports the state it finds and the
/// panel - opened by a click, which is a user asking - owns the button that
/// changes it.
struct RemindersTile: View {
    var instance: WidgetInstance
    var context: WidgetContext

    @State private var access = EKEventStore.authorizationStatus(for: .reminder)
    @State private var rows: [TileReminder] = []
    /// A fetch is async and the shelf can rebuild or reconfigure the tile while
    /// one is in flight; only the newest is allowed to land.
    @State private var generation = 0

    private var store: EKEventStore { ReminderTileStore.shared }

    private var layout: String { instance.config.string("layout", default: "list") }

    /// The list the widget was configured for, by title. Empty - the catalog
    /// default - means every list.
    private var listFilter: String {
        instance.config.string("list").trimmingCharacters(in: .whitespaces)
    }

    /// The library has no store behind it, so it shows the reference sample.
    private var granted: Bool { context.isPreview || access == .fullAccess }

    private var items: [TileReminder] {
        context.isPreview ? Self.sample(now: context.now) : rows
    }

    /// Overdue first, then the rest of today, each in due order.
    ///
    /// Concatenated rather than left to the due sort: an all-day reminder for
    /// today carries midnight, so a plain ascending sort files it above a timed
    /// one that is already late.
    private var ordered: [TileReminder] {
        let now = context.now
        return items.filter { $0.isOverdue(now) } + items.filter { !$0.isOverdue(now) }
    }

    private var overdueCount: Int { items.filter { $0.isOverdue(context.now) }.count }
    private var todayCount: Int { items.count - overdueCount }

    /// Layouts with about 56pt of usable width: the side shelf's column, and
    /// the 88pt Count card. Both drop captions to a stacked, centred form.
    private var narrow: Bool { context.position.isVertical || layout == "count" }

    var body: some View {
        WidgetSurface {
            if !granted {
                notice("lock", accessText, tint: WidgetStyle.secondary)
            } else if items.isEmpty {
                notice("checkmark.circle", emptyText, tint: Self.accent)
            } else if context.position.isVertical {
                column
            } else {
                switch layout {
                case "next": wideNext
                case "count": count
                default: wideList
                }
            }
        }
        .onAppear { load() }
        .onChange(of: listFilter) { load() }
        // `now` ticks every second; re-reading the store that often would be
        // absurd, and the overdue split above is recomputed from `now` anyway.
        // Five minutes also carries the fetch window past midnight on its own.
        .onChange(of: Int(context.now.timeIntervalSince1970) / 300) { load() }
        // A reminder ticked off in Reminders.app, or access granted in the
        // panel, both land here.
        .onReceive(NotificationCenter.default.publisher(for: .EKEventStoreChanged)) { _ in load() }
    }

    // MARK: Wide layouts

    /// Up to three rows, each a dot, a title and when it was or is due. A
    /// fourth would not fit, so the last line counts what is left instead -
    /// the tile must never look like the whole of a backlog it has cut off.
    private var wideList: some View {
        let hidden = ordered.count > 3 ? ordered.count - 2 : 0
        return VStack(alignment: .leading, spacing: 2) {
            ForEach(ordered.prefix(hidden > 0 ? 2 : 3)) { item in
                listRow(item)
            }
            if hidden > 0 {
                Text("\(hidden) more")
                    .font(WidgetStyle.caption(10))
                    .foregroundStyle(WidgetStyle.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func listRow(_ item: TileReminder) -> some View {
        let late = item.isOverdue(context.now)
        return HStack(spacing: 6) {
            dot(late: late)
            Text(item.title)
                .font(WidgetStyle.label(11))
                .foregroundStyle(WidgetStyle.primary)
            Spacer(minLength: 6)
            Text(stamp(item))
                .font(WidgetStyle.caption(10))
                .foregroundStyle(WidgetStyle.secondary)
                .monospacedDigit()
        }
        .lineLimit(1)
        .accessibilityElement(children: .combine)
    }

    /// The single next thing: symbol left, title and its due line stacked on
    /// the right, in the idiom the weather tile uses.
    private var wideNext: some View {
        let item = ordered[0]
        let late = item.isOverdue(context.now)
        // The shelf's badge and reading. Overdue is said by the glyph in
        // the badge, small and red, rather than by colouring the words: red
        // text was the loudest thing on the shelf.
        return HStack(spacing: 10) {
            TileBadge {
                Image(systemName: late ? "exclamationmark.circle.fill" : "checklist")
                    .font(.system(size: 17))
                    .foregroundStyle(late ? Self.overdue : WidgetStyle.primary)
            }
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(item.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(WidgetStyle.primary)
                    // Reminders.app's own flag, and the only ranking EventKit
                    // gives that a due-date sort throws away.
                    if item.isHighPriority {
                        Text("!")
                            .font(WidgetStyle.label(14))
                            .foregroundStyle(WidgetStyle.secondary)
                    }
                }
                Text(detail(item))
                    .font(.system(size: 12))
                    .foregroundStyle(WidgetStyle.secondary)
            }
            Spacer(minLength: 0)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.75)
    }

    // MARK: Count
    //
    // The layout with the least room and the most to say. Overdue and due
    // today are not the same fact, so when both exist the card shows both,
    // small and stacked; when only one does, that one gets the whole card as a
    // single figure worth reading from across the desk.

    @ViewBuilder
    private var count: some View {
        if overdueCount > 0 && todayCount > 0 {
            VStack(alignment: .leading, spacing: 1) {
                countRow(overdueCount, "overdue", tint: WidgetStyle.primary)
                countRow(todayCount, "today", tint: WidgetStyle.primary)
            }
            .frame(maxWidth: .infinity)
        } else if overdueCount > 0 {
            bigCount(overdueCount, "overdue", tint: WidgetStyle.primary)
        } else {
            bigCount(todayCount, "due today", tint: WidgetStyle.primary)
        }
    }

    private func countRow(_ value: Int, _ label: String, tint: Color) -> some View {
        HStack(spacing: 4) {
            Text("\(value)")
                .font(WidgetStyle.value(17))
                .foregroundStyle(tint)
                .monospacedDigit()
                .rollingValue(value)
            Text(label)
                .font(WidgetStyle.caption(10))
                .foregroundStyle(WidgetStyle.secondary)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }

    private func bigCount(_ value: Int, _ label: String, tint: Color) -> some View {
        VStack(spacing: 0) {
            Text("\(value)")
                .font(WidgetStyle.value(26))
                .foregroundStyle(tint)
                .monospacedDigit()
                .rollingValue(value)
            Text(label)
                .font(WidgetStyle.caption(11))
                .foregroundStyle(WidgetStyle.secondary)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.6)
        .frame(maxWidth: .infinity)
    }

    // MARK: Column
    //
    // 56pt of usable width. Times and list names do not survive it, so the
    // column keeps what identifies a reminder - its title - and lets the dot
    // carry whether it is late.

    @ViewBuilder
    private var column: some View {
        switch layout {
        case "next": columnNext
        case "count": count
        default: columnList
        }
    }

    /// The count, not the list. Titles in a 76pt column were cut to
    /// "Renew d...", which named nothing; how many are due, and whether any
    /// are late, is what fits and what the column is for. The list is a
    /// click away in the panel.
    private var columnList: some View {
        VStack(spacing: 3) {
            TileBadge(size: 30) {
                Image(systemName: "checklist")
                    .font(.system(size: 13))
                    .foregroundStyle(WidgetStyle.primary)
            }
            .overlay(alignment: .topTrailing) {
                // Late is a dot, not red text.
                if overdueCount > 0 {
                    Circle().fill(Self.overdue).frame(width: 6, height: 6).offset(x: 1, y: -1)
                }
            }
            Text("\(items.count)")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(WidgetStyle.primary)
                .monospacedDigit()
            Text(overdueCount > 0 ? "\(overdueCount) overdue" : "due today")
                .font(.system(size: 11))
                .foregroundStyle(WidgetStyle.secondary)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .accessibilityElement(children: .combine)
    }

    private var columnNext: some View {
        let item = ordered[0]
        let late = item.isOverdue(context.now)
        return VStack(spacing: 2) {
            Image(systemName: late ? "exclamationmark.circle.fill" : "checklist")
                .font(.system(size: 18))
                .foregroundStyle(late ? Self.overdue : Self.accent)
                .frame(height: 18)
            Text(item.title)
                .font(WidgetStyle.label(11))
                .foregroundStyle(WidgetStyle.primary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
            Text(stamp(item))
                .font(WidgetStyle.caption(10))
                .foregroundStyle(WidgetStyle.secondary)
                .lineLimit(1)
                .monospacedDigit()
        }
        .minimumScaleFactor(0.65)
    }

    // MARK: States with nothing to show

    /// Never a plausible zero. Without access the count is unknown, not none,
    /// and the two have to look different or the tile lies by omission.
    private var accessText: String {
        if narrow { return "No access" }
        return access == .notDetermined ? "Reminders access not granted" : "Reminders access is off"
    }

    private var emptyText: String { narrow ? "Nothing due" : "Nothing due today." }

    @ViewBuilder
    private func notice(_ symbol: String, _ text: String, tint: Color) -> some View {
        if narrow {
            VStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 17))
                    .foregroundStyle(tint)
                Text(text)
                    .font(WidgetStyle.caption(10))
                    .foregroundStyle(WidgetStyle.secondary)
                    .multilineTextAlignment(.center)
            }
            .lineLimit(2)
            .minimumScaleFactor(0.7)
            .frame(maxWidth: .infinity)
        } else {
            HStack(spacing: 9) {
                Image(systemName: symbol)
                    .font(.system(size: 20))
                    .foregroundStyle(tint)
                    .frame(height: 20)
                Text(text)
                    .font(WidgetStyle.caption(12))
                    .foregroundStyle(WidgetStyle.secondary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.75)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: Pieces

    private func dot(late: Bool) -> some View {
        Circle()
            .fill(late ? Self.overdue : Self.accent)
            .frame(width: 5, height: 5)
    }

    /// The tight form, for a row that already carries a title beside it: the
    /// time if it is today's, otherwise the day it slipped from.
    private func stamp(_ item: TileReminder) -> String {
        guard Calendar.current.isDateInToday(item.due) else {
            return item.due.formatted(.dateTime.day().month(.abbreviated))
        }
        return item.hasTime ? item.due.formatted(date: .omitted, time: .shortened) : "All day"
    }

    /// The Next layout's fuller line, matching the panel's: when it was due,
    /// then which list it is on - two reminders at 09:00 are told apart by the
    /// list, never the other way round.
    private func detail(_ item: TileReminder) -> String {
        let when = item.hasTime
            ? item.due.formatted(date: .omitted, time: .shortened)
            : "All day"
        let day = Calendar.current.isDateInToday(item.due)
            ? ""
            : item.due.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)) + " "
        return item.list.isEmpty ? day + when : "\(day)\(when) · \(item.list)"
    }

    private static let overdue = Color(hex: PaletteColor.red.hex)
    private static let accent = Color(hex: WidgetCatalog.accentHex(.reminders) ?? PaletteColor.orange.hex)

    // MARK: Store

    /// Everything incomplete and dated up to the end of today, which is overdue
    /// and today's in one predicate. Reminders with no due date are not
    /// returned by a dated predicate, and the tile does not pretend otherwise:
    /// it counts what is *due*, exactly as the panel does.
    private func load() {
        guard !context.isPreview else { return }

        let status = EKEventStore.authorizationStatus(for: .reminder)
        if status != access {
            // A grant given in the detail panel leaves this store, built
            // before it, answering as if it had none until it is told to look
            // again.
            if status == .fullAccess { store.reset() }
            access = status
        }
        guard status == .fullAccess else {
            rows = []
            return
        }

        let lists = store.calendars(for: .reminder)
        // A filter naming a list that has since been deleted falls back to the
        // whole account: a predicate over no lists matches nothing, and an
        // empty tile would read as "nothing due".
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
            // Flattened inside the completion: an `EKReminder` is a live object
            // the store may mutate or invalidate, and it is not safe to carry
            // back across the hop.
            let fetched: [TileReminder] = await withCheckedContinuation { continuation in
                store.fetchReminders(matching: predicate) { reminders in
                    continuation.resume(returning: (reminders ?? []).compactMap(TileReminder.init))
                }
            }
            guard token == generation else { return }
            rows = fetched.sorted {
                $0.due == $1.due ? $0.title < $1.title : $0.due < $1.due
            }
        }
    }

    /// Two overdue and three due later today, so every layout has both halves
    /// of the count to draw. Anchored to `now` so the split is real wherever
    /// the library is opened.
    private static func sample(now: Date) -> [TileReminder] {
        [(-86_400.0, "Renew domain", "Work", true),
         (-5_400.0, "Reply to Jonas", "Work", false),
         (3_600.0, "Book flights", "Travel", false),
         (9_000.0, "Water the plants", "Home", false),
         (16_200.0, "Pick up parcel", "Home", false)]
            .enumerated()
            .map { index, item in
                TileReminder(id: "sample-\(index)",
                             title: item.1,
                             due: now.addingTimeInterval(item.0),
                             hasTime: true,
                             list: item.2,
                             isHighPriority: item.3)
            }
    }
}

/// One store, made the first time a reminders tile is drawn.
///
/// Held here rather than in `@State`: the tile is rebuilt on every tick, and a
/// store in state would mean a fresh connection to the reminders daemon each
/// time, all but one of them thrown away. Constructing one does not prompt -
/// only `requestFullAccessToReminders` does, and the tile never calls it.
@MainActor
private enum ReminderTileStore {
    static let shared = EKEventStore()
}

/// One row, flattened off its `EKReminder` as the fetch returns.
private struct TileReminder: Identifiable, Hashable, Sendable {
    var id: String
    var title: String
    var due: Date
    /// False for a reminder set for a day with no time of day, which is due all
    /// day and not at midnight.
    var hasTime: Bool
    var list: String
    var isHighPriority: Bool

    init(id: String, title: String, due: Date, hasTime: Bool, list: String, isHighPriority: Bool) {
        self.id = id
        self.title = title
        self.due = due
        self.hasTime = hasTime
        self.list = list
        self.isHighPriority = isHighPriority
    }

    init?(_ reminder: EKReminder) {
        guard let components = reminder.dueDateComponents,
              // `date` is nil unless the components carry a calendar, which
              // EventKit does not promise.
              let due = components.date ?? Calendar.current.date(from: components)
        else { return nil }
        let title = (reminder.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        self.init(id: reminder.calendarItemIdentifier,
                  // An untitled reminder is still a real reminder; Reminders.app
                  // shows the row empty, which here would be a dot with nothing
                  // beside it.
                  title: title.isEmpty ? "New Reminder" : title,
                  due: due,
                  hasTime: components.hour != nil,
                  list: reminder.calendar?.title ?? "",
                  // EventKit's priority runs 1-9 with 0 for none; Reminders.app's
                  // own "High" flag is 1-4.
                  isHighPriority: (1...4).contains(reminder.priority))
    }

    /// A dated reminder is late the moment its time passes. One set for a day
    /// with no time is late only once that day is over.
    func isOverdue(_ now: Date) -> Bool {
        hasTime ? due < now : due < Calendar.current.startOfDay(for: now)
    }
}
