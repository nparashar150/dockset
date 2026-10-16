import Foundation
import SwiftUI
import UserNotifications

/// A drop that fills up between drinks.
///
/// It was a whole card of light blue water, the one tile on the shelf with a
/// colour of its own, and it read as a sticker among graphite cards. The
/// water is now the mark in the tile's badge: the same rising level, on the
/// same neutral card as every other tile.
///
/// A click on the card belongs to the shelf, so logging a drink is a "+" beside
/// the readout rather than the whole glass: the card is what opens the widget,
/// and a tile-wide tap would take that click before the shelf ever saw it.
struct HydrationTile: View {
    var instance: WidgetInstance
    var context: WidgetContext

    /// Guard against a zero or negative stored interval: it would divide by
    /// zero below and NaN the whole path.
    private var duration: TimeInterval {
        max(60, instance.config.double("duration", default: 2700))
    }

    /// Seconds until the next drink.
    ///
    /// Counted from the last drink once there has been one.
    ///
    /// Until then the cycle is anchored to the reference date, so a widget
    /// that has never been tapped still agrees with every other shelf about
    /// where in the interval it is.
    private var remaining: TimeInterval {
        // Sample value chosen to match the library reference render.
        if context.isPreview { return 1800 }
        let period = duration
        let last = instance.config.double("lastDrink")
        if last > 0 {
            let since = max(0, context.now.timeIntervalSince1970 - last)
            return max(0, period - since)
        }
        let into = context.now.timeIntervalSinceReferenceDate
            .truncatingRemainder(dividingBy: period)
        return period - into
    }

    private func drink() {
        guard !context.isPreview else { return }
        Hydration.drink(instance)
    }

    /// Height of the water, 0…1, as elapsed progress toward the next drink.
    private var level: Double {
        // The reference preview shows a near-full glass; keep the library card
        // looking like the widget rather than like an empty one.
        if context.isPreview { return 0.75 }
        return min(1, max(0, 1 - remaining / duration))
    }

    private var clock: String {
        let seconds = max(0, Int(remaining.rounded(.up)))
        return "\(seconds / 60):\(String(format: "%02d", seconds % 60))"
    }

    var body: some View {
        surface
            // Turning reminders off in Settings has to take back the one
            // already scheduled, and turning them on should not wait for the
            // next drink. The tile is the part that is always on screen.
            .onChange(of: instance.config.bool("reminders")) { _, _ in
                guard !context.isPreview else { return }
                Hydration.scheduleReminder(instance)
            }
    }

    private var surface: some View {
        WidgetSurface {
            if context.position.isVertical {
                // 76x88: drop, clock, and the control under them.
                VStack(spacing: 4) {
                    TileBadge(size: 34) { drop(size: 17) }
                    Text(clock)
                        .font(.system(size: 16, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(WidgetStyle.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    drinkButton(size: 10)
                }
            } else {
                HStack(spacing: 10) {
                    TileBadge { drop(size: 20) }
                    TileReading(value: clock, caption: "Next drink")
                    Spacer(minLength: 0)
                    drinkButton(size: 12)
                }
            }
        }
    }

    /// The drop's outline, with the water filled in up to the level: a muted
    /// steel blue, the accent and nothing louder.
    private func drop(size: CGFloat) -> some View {
        ZStack {
            Image(systemName: "drop")
                .foregroundStyle(WidgetStyle.secondary)
            Image(systemName: "drop.fill")
                .foregroundStyle(Color(hex: PaletteColor.blue.hex).mix(with: WidgetStyle.primary, by: 0.6))
                .mask {
                    GeometryReader { geo in
                        VStack(spacing: 0) {
                            Spacer(minLength: 0)
                            Rectangle().frame(height: geo.size.height * level)
                        }
                    }
                }
                .animation(.snappy(duration: 0.35), value: level)
        }
        .font(.system(size: size, weight: .regular))
    }

    /// Only ever as big as itself: the card's own click has to reach the shelf,
    /// so nothing here may spread to fill it. `TileGlyph` is the shelf-wide
    /// treatment for exactly that - see StopwatchTile. The plain "+" replaces
    /// `plus.circle.fill`, which would have drawn a disc inside a disc.
    ///
    /// The fill rising is the only confirmation a drink registered, which is
    /// why the write is animated rather than the press.
    private func drinkButton(size: CGFloat) -> some View {
        TileGlyph(symbol: "plus", size: size, action: context.isPreview ? nil : {
            withAnimation(.snappy(duration: 0.35)) { drink() }
        })
        .accessibilityLabel("Log a drink")
    }
}

/// What logging a drink does, for the tile and the panel alike.
@MainActor
enum Hydration {
    static func trackingAmounts(_ config: WidgetConfig) -> Bool {
        config.bool("trackAmounts", default: true)
    }

    static func drinkSize(_ config: WidgetConfig) -> Double {
        max(0, config.double("drinkSize", default: 250))
    }

    static func goal(_ config: WidgetConfig) -> Double {
        max(1, config.double("goal", default: 2000))
    }

    /// Restarts the countdown, adds the drink to the log and moves the
    /// reminder to the new due time.
    static func drink(_ instance: WidgetInstance) {
        let now = Date.now.timeIntervalSince1970
        var updated = instance
        WidgetWriter.write(instance) { config in
            config.set("lastDrink", .number(now))
            var log = HydrationLog(config)
            log.add(.init(at: now, millilitres: trackingAmounts(config) ? drinkSize(config) : 0))
            config.set(HydrationLog.key, log.value)
            updated.config = config
        }
        scheduleReminder(updated)
    }

    /// One pending notification per widget, at the next due time.
    ///
    /// Permission is asked the first time one is actually scheduled, which is
    /// after the user turned reminders on and logged a drink: the moment it
    /// is obviously wanted.
    static func scheduleReminder(_ instance: WidgetInstance) {
        let center = UNUserNotificationCenter.current()
        let id = "hydration.\(instance.id.uuidString)"
        center.removePendingNotificationRequests(withIdentifiers: [id])
        guard instance.config.bool("reminders", default: false) else { return }

        let duration = max(60, instance.config.double("duration", default: 2700))
        let last = instance.config.double("lastDrink")
        let due = last > 0 ? last + duration : Date.now.timeIntervalSince1970 + duration
        let wait = due - Date.now.timeIntervalSince1970
        // Already overdue: the tile is showing it, and a notification for
        // something past would land the instant reminders are switched on.
        guard wait > 1 else { return }

        let content = UNMutableNotificationContent()
        content.title = "Time for a drink"
        content.body = "It has been \(Duration.seconds(duration).formatted(.units(allowed: [.hours, .minutes], width: .wide))) since the last one."
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: id, content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: wait, repeats: false))
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            center.add(request)
        }
    }
}
