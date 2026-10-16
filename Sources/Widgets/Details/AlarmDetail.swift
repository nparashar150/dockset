import SwiftUI

/// One alarm, said properly.
///
/// The widget holds exactly one - `time`, `name` and `enabled` in its own
/// config - so this is a single-alarm panel rather than a list pretending to
/// be one. Several alarms means several widgets, each with its own tile and
/// its own panel.
///
/// What the card cannot fit: which day the next ring lands on, the count to it
/// to the second rather than rounded up to the minute, and a switch you have
/// to mean - silencing an alarm is how you sleep through something, which is
/// why the tile keeps it to a glyph the size of itself and the panel gives it
/// a button.
struct AlarmDetail: View {
    var instance: WidgetInstance
    var context: WidgetContext

    var body: some View {
        // The panel's context is frozen at the moment it opened, so the
        // schedule is what carries the count down - and what rolls the next
        // occurrence over to tomorrow the second this one passes.
        TimelineView(.periodic(from: .now, by: 1)) { tick in
            content(now: tick.date)
        }
    }

    private func content(now: Date) -> some View {
        let next = nextOccurrence(after: now)
        let enabled = instance.config.bool("enabled", default: true)
        let name = instance.config.string("name")

        // Night, because that is when an alarm is set for, lit orange only
        // while it will actually ring.
        return DetailCard {
            ZStack(alignment: .topTrailing) {
                MeshBackdrop(color: Color(red: 0.16, green: 0.14, blue: 0.42))
                Circle()
                    .fill(RadialGradient(colors: [Self.orange.opacity(enabled ? 0.45 : 0), .clear],
                                         center: .center, startRadius: 0, endRadius: 110))
                    .frame(width: 220, height: 220)
                    .offset(x: 70, y: -80)
            }
        } content: {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(name.isEmpty ? "Alarm" : name)
                        .font(WidgetStyle.label(14))
                        .foregroundStyle(Color.panelInk.opacity(0.8))
                        .lineLimit(1)
                    Text(next.formatted(.dateTime.hour().minute()))
                        .font(.system(size: 60, weight: .light, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(WidgetStyle.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
                // The time itself is never hidden while off: you set a switch
                // by knowing what it is set to.
                .opacity(enabled ? 1 : 0.55)

                HStack(spacing: 8) {
                    StatChip(label: "Rings", value: dayLine(next, now: now))
                    // A countdown to something that will not ring is a lie,
                    // so a silenced alarm says so instead.
                    StatChip(label: "Countdown", value: enabled ? countdown(to: next, from: now) : "Silenced")
                }

                armSwitch(enabled)
            }
        }
    }

    private static let orange = Color(hex: PaletteColor.orange.hex)

    /// The whole row is the switch. Arming is the action that makes the alarm
    /// do its job, so the lit state is the loud one; silencing is how you
    /// sleep through something, so it is a switch you have to mean rather
    /// than a glyph you can brush.
    private func armSwitch(_ enabled: Bool) -> some View {
        Button(action: toggle) {
            HStack(spacing: 10) {
                Image(systemName: enabled ? "bell.fill" : "bell.slash.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(enabled ? Self.orange : Color.panelInk.opacity(0.6))
                    .frame(width: 20)
                Text(enabled ? "On" : "Silenced")
                    .font(WidgetStyle.label(13))
                    .foregroundStyle(Color.panelInk)
                Spacer(minLength: 8)
                Capsule()
                    .fill(enabled ? Self.orange : Color.panelInk.opacity(0.18))
                    .frame(width: 42, height: 24)
                    .overlay(alignment: enabled ? .trailing : .leading) {
                        Circle().fill(Color.panelInk).padding(2.5).shadow(radius: 1)
                    }
            }
            .padding(.horizontal, 12)
            .frame(height: 44)
            .glassPane()
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(enabled ? "Silence alarm" : "Turn alarm on")
    }

    // MARK: Data
    //
    // The tile's accessors, key for key: the panel must not disagree with the
    // card that opened it about when this alarm next rings.

    /// Next time today's clock reaches the configured `HH:mm`; tomorrow once
    /// it has already passed.
    private func nextOccurrence(after now: Date) -> Date {
        let parts = instance.config.string("time", default: "14:30").split(separator: ":")
        let hour = parts.count == 2 ? Int(parts[0]) ?? 14 : 14
        let minute = parts.count == 2 ? Int(parts[1]) ?? 30 : 30
        let cal = Calendar.current
        guard let today = cal.date(bySettingHour: min(hour, 23), minute: min(minute, 59),
                                   second: 0, of: now) else { return now }
        guard today <= now else { return today }
        return cal.date(byAdding: .day, value: 1, to: today) ?? today
    }

    /// An alarm repeats daily, so the next one is today's or tomorrow's and
    /// nothing else - but which of the two, and what date that is, is exactly
    /// what a 24-hour time on a card leaves you to work out.
    private func dayLine(_ date: Date, now: Date) -> String {
        let day = Calendar.current.isDate(date, inSameDayAs: now) ? "Today" : "Tomorrow"
        return "\(day), \(date.formatted(.dateTime.day().month(.abbreviated)))"
    }

    private func countdown(to date: Date, from now: Date) -> String {
        let total = max(0, Int(date.timeIntervalSince(now)))
        let (h, m, s) = (total / 3600, (total % 3600) / 60, total % 60)
        return h > 0 ? String(format: "in %dh %02dm %02ds", h, m, s)
                     : String(format: "in %dm %02ds", m, s)
    }

    // MARK: Actions

    private func toggle() {
        guard !context.isPreview else { return }
        let enabled = instance.config.bool("enabled", default: true)
        withAnimation(.snappy(duration: 0.3)) {
            WidgetWriter.write(instance) { config in
                config.set("enabled", .bool(!enabled))
            }
        }
    }
}
