import Foundation
import SwiftUI

/// The hydration reminder in wall-clock terms, the day's drinks, and a button
/// big enough to press without aiming at it.
///
/// What it can say that the tile cannot: the clock time the next drink is due
/// at rather than a countdown to it, when the last one went in, how long a
/// drink has been overdue (the tile's countdown floors at 0:00), and the
/// `HydrationLog`: today against the goal, the week behind it, and today's
/// drinks one by one, each removable with an undo for the slip.
struct HydrationDetail: View {
    var instance: WidgetInstance
    var context: WidgetContext

    /// The last drink taken off the log, so a misclick can be put back.
    @State private var removed: HydrationLog.Drink?

    var body: some View {
        // Seconds, to agree with the tile's own clock. It has to be a schedule
        // rather than `context.now`: the panel's root view is assigned once
        // when it opens, so that clock is frozen and the countdown would sit
        // perfectly still for as long as the panel stayed up.
        TimelineView(.periodic(from: .now, by: 1)) { tick in
            content(now: tick.date)
        }
    }

    private func content(now: Date) -> some View {
        let left = remaining(now: now)
        // The glass behind the card is full the moment a drink goes in and
        // drains as the next one comes due: the level is the interval, which
        // is the one thing the model actually measures. Not a day's tally,
        // which it has no record of.
        return DetailCard {
            ZStack(alignment: .bottom) {
                MeshBackdrop(color: accent)
                Water(level: left / duration,
                      phase: now.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 4) / 4,
                      colour: accent)
            }
        } content: {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(left > 0 ? "NEXT DRINK AT" : "DUE NOW")
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(0.8)
                        .foregroundStyle(Color.panelInk.opacity(0.7))
                    // A time of day, which is the thing the tile's countdown is
                    // not: "2:49 PM" is a moment you can plan around, "17:22" is
                    // one you have to do arithmetic on.
                    Text(left > 0 ? clock(now.addingTimeInterval(left)) : "Drink up")
                        .font(.system(size: 52, weight: .semibold, design: .rounded))
                        .foregroundStyle(WidgetStyle.primary)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Text(headlineCaption(left, now: now))
                        .font(WidgetStyle.label(13))
                        .foregroundStyle(Color.panelInk.opacity(0.8))
                        .monospacedDigit()
                }

                HStack(spacing: 8) {
                    StatChip(label: "Last drink", value: lastDrinkLine(now: now))
                    StatChip(label: "Every", value: interval)
                        .frame(width: 96)
                }

                today(now: now)

                drinkButton
            }
        }
    }

    // MARK: Today

    private var log: HydrationLog {
        if context.isPreview {
            let now = Date.now.timeIntervalSince1970
            return HydrationLog(drinks: [.init(at: now - 7200, millilitres: 250),
                                         .init(at: now - 3600, millilitres: 250)])
        }
        return HydrationLog(instance.config)
    }

    private var tracking: Bool { Hydration.trackingAmounts(instance.config) }

    @ViewBuilder
    private func today(now: Date) -> some View {
        let drinks = log.drinks(on: now)
        VStack(alignment: .leading, spacing: 8) {
            if tracking {
                let total = drinks.reduce(0) { $0 + $1.millilitres }
                let goal = Hydration.goal(instance.config)
                HStack(alignment: .firstTextBaseline) {
                    Text("TODAY")
                        .font(.system(size: 9, weight: .semibold))
                        .tracking(0.6)
                        .foregroundStyle(Color.panelInk.opacity(0.6))
                    Spacer()
                    Text("\(Int(total)) of \(Int(goal)) mL")
                        .font(WidgetStyle.label(12))
                        .foregroundStyle(WidgetStyle.primary)
                        .monospacedDigit()
                }
                TickMeter(fraction: min(1, total / goal))
                week(now: now, goal: goal)
            } else {
                Text(drinks.count == 1 ? "1 drink today" : "\(drinks.count) drinks today")
                    .font(WidgetStyle.label(12))
                    .foregroundStyle(WidgetStyle.primary)
            }
            // The latest few, newest first: the one most likely to be a
            // misclick is the one just logged.
            ForEach(Array(drinks.suffix(4).reversed()), id: \.self) { drink in
                HStack {
                    Text(clock(Date(timeIntervalSince1970: drink.at)))
                        .monospacedDigit()
                    if drink.millilitres > 0 {
                        Text("\(Int(drink.millilitres)) mL")
                            .foregroundStyle(Color.panelInk.opacity(0.7))
                    }
                    Spacer()
                    Button {
                        remove(drink)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Color.panelInk.opacity(0.5))
                    }
                    .buttonStyle(.plain)
                    .help("Remove this drink")
                    .accessibilityLabel("Remove drink at \(clock(Date(timeIntervalSince1970: drink.at)))")
                }
                .font(WidgetStyle.caption(12))
                .foregroundStyle(WidgetStyle.primary)
            }
            if let removed {
                Button("Undo removal") { restore(removed) }
                    .buttonStyle(.plain)
                    .font(WidgetStyle.label(11))
                    .foregroundStyle(Color.panelInk)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.panelInk.opacity(0.14)))
            }
        }
        .padding(10)
        .glassPane(cornerRadius: 10)
    }

    /// Seven days, a bar each, today last, with the goal as the top.
    private func week(now: Date, goal: Double) -> some View {
        let totals = log.totals(endingOn: now)
        return HStack(alignment: .bottom, spacing: 4) {
            ForEach(totals.indices, id: \.self) { index in
                let fraction = min(1, totals[index] / goal)
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(index == totals.count - 1 ? accent : accent.opacity(0.55))
                        .frame(height: max(2, 28 * fraction))
                }
                .frame(maxWidth: .infinity, maxHeight: 28)
                .background(RoundedRectangle(cornerRadius: 2).fill(Color.panelInk.opacity(0.06)))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Last seven days")
        .accessibilityValue(totals.map { "\(Int($0)) mL" }.joined(separator: ", "))
    }

    private func remove(_ drink: HydrationLog.Drink) {
        guard !context.isPreview else { return }
        WidgetWriter.write(instance) { config in
            var log = HydrationLog(config)
            log.remove(drink)
            config.set(HydrationLog.key, log.value)
        }
        removed = drink
        relayout()
    }

    /// Back into the log only: the countdown is not rewound, because a later
    /// drink may have moved it since.
    private func restore(_ drink: HydrationLog.Drink) {
        guard !context.isPreview else { return }
        WidgetWriter.write(instance) { config in
            var log = HydrationLog(config)
            log.add(drink)
            config.set(HydrationLog.key, log.value)
        }
        removed = nil
        relayout()
    }

    /// The list changes the panel's height, and the panel is otherwise sized
    /// once as it opens.
    private func relayout() {
        Task { @MainActor in WidgetDetailWindow.shared.relayout() }
    }

    // MARK: Action

    /// The tile's "+" is 13pt across because a card's own click belongs to the
    /// shelf and nothing on it may spread. The panel has no such contest, so
    /// the one action this widget has gets the full width.
    private var drinkButton: some View {
        Button {
            // The tile animates its water rising on a drink; the same write
            // redraws this panel, so it is animated from here too.
            withAnimation(.snappy(duration: 0.35)) { drink() }
        } label: {
            Label("Log a drink", systemImage: "drop.fill")
                .font(WidgetStyle.label(13))
                .foregroundStyle(Color.panelInk)
                .frame(maxWidth: .infinity)
                .frame(height: 38)
                .background(Capsule().fill(Color.panelInk.opacity(0.24)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Log a drink")
    }

    // MARK: Lines

    /// Under the headline: the countdown the tile shows when there is one, and
    /// how far past due it is when there is not. The tile clamps at 0:00 and
    /// stays there, which says a drink is due but never that it has been due
    /// for half an hour.
    private func headlineCaption(_ left: TimeInterval, now: Date) -> String {
        guard left <= 0 else { return "\(docketClockString(left)) to go" }
        let last = instance.config.double("lastDrink")
        guard !context.isPreview, last > 0 else { return "Due now" }
        let over = now.timeIntervalSince1970 - last - duration
        return over >= 60 ? "Overdue by \(spelled(over))" : "Due now"
    }

    /// The one fact only the stored timestamp holds. A widget that has never
    /// been tapped has no last drink - its cycle is anchored to the reference
    /// date instead - so it says so rather than dressing the anchor up as one.
    private func lastDrinkLine(now: Date) -> String {
        let last = instance.config.double("lastDrink")
        guard !context.isPreview, last > 0 else { return "Not logged yet" }
        let date = Date(timeIntervalSince1970: last)
        let since = max(0, now.timeIntervalSince(date))
        return since < 60 ? "\(clock(date)), just now"
                          : "\(clock(date)), \(spelled(since)) ago"
    }

    // MARK: Data
    //
    // The tile's accessors, key for key, so the card and the panel cannot
    // disagree about when the next drink is due.

    /// Guard against a zero or negative stored interval: it would divide by
    /// zero below and NaN the whole path.
    private var duration: TimeInterval {
        max(60, instance.config.double("duration", default: 2700))
    }

    private var interval: String { spelled(duration) }

    /// Seconds until the next drink, counted from the last one once there has
    /// been one and from the reference date until then - the tile's rule,
    /// re-read against the schedule's clock rather than the frozen one.
    private func remaining(now: Date) -> TimeInterval {
        // The tile's sample value, so a library preview of the two agrees.
        if context.isPreview { return 1800 }
        let period = duration
        let last = instance.config.double("lastDrink")
        if last > 0 {
            return max(0, period - max(0, now.timeIntervalSince1970 - last))
        }
        let into = now.timeIntervalSinceReferenceDate
            .truncatingRemainder(dividingBy: period)
        return period - into
    }

    private func drink() {
        guard !context.isPreview else { return }
        Hydration.drink(instance)
        removed = nil
        relayout()
    }

    private var accent: Color {
        WidgetCatalog.accentHex(.hydration).map { Color(hex: $0) } ?? WidgetStyle.primary
    }

    private func clock(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    /// Hours and minutes in words - "45 min", "1 hr 30 min". The m:ss clock is
    /// right for a countdown that is ticking and wrong for a span that is
    /// merely long.
    private func spelled(_ seconds: TimeInterval) -> String {
        Duration.seconds(seconds)
            .formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
    }
}

/// Water filling the card to `level`, its surface a slow double wave.
private struct Water: View {
    var level: Double
    /// 0…1 through one swell, so the surface moves with the panel's tick.
    var phase: Double
    var colour: Color

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let top = size.height * (1 - min(1, max(0.04, level)))
            ZStack {
                surface(size, top: top, shift: phase + 0.5, amplitude: 5)
                    .fill(MeshBackdrop.muted(colour, on: scheme).opacity(0.5))
                surface(size, top: top + 3, shift: phase, amplitude: 4)
                    .fill(LinearGradient(colors: [MeshBackdrop.muted(colour, by: 0.62, on: scheme),
                                                  MeshBackdrop.muted(colour, by: 0.85, on: scheme)],
                                         startPoint: .top, endPoint: .bottom))
            }
            .animation(.smooth(duration: 0.8), value: level)
        }
        .accessibilityHidden(true)
    }

    private func surface(_ size: CGSize, top: CGFloat, shift: Double, amplitude: CGFloat) -> Path {
        Path { p in
            p.move(to: CGPoint(x: 0, y: size.height))
            for x in stride(from: 0, through: size.width, by: 4) {
                let angle = (Double(x / max(size.width, 1)) + shift) * 2 * .pi * 1.5
                p.addLine(to: CGPoint(x: x, y: top + amplitude * CGFloat(sin(angle))))
            }
            p.addLine(to: CGPoint(x: size.width, y: size.height))
            p.closeSubpath()
        }
    }
}
