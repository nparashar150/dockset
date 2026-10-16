import SwiftUI

/// The next time an alarm named in the config will fire.
///
/// A click on the card opens Clock.app, so the card belongs to the shelf.
/// Arming and silencing stays on the tile as the alarm's own glyph, sized to
/// itself: silencing an alarm by a stray click on a card is how you sleep
/// through something. `enabled` lives in the widget's own config, so a
/// silenced alarm stays silenced across a relaunch. The time itself is never
/// hidden while off - you set a switch by knowing what it is set to.
struct AlarmTile: View {
    var instance: WidgetInstance
    var context: WidgetContext

    var body: some View {
        let next = nextOccurrence
        let name = instance.config.string("name")
        let enabled = instance.config.bool("enabled", default: true)

        WidgetSurface {
            Group {
                if context.position.isVertical {
                    // 76x76 column: switch, time, name. The "in Xh Ym" caption
                    // is the row that does not fit, so it goes. The glyph is
                    // 14pt rather than 18 so its disc lands on the 28pt the
                    // bare symbol already reserved and the column keeps its
                    // two lines.
                    // The same switch badge as the wide card, smaller, in
                    // place of the orange disc this column used to carry.
                    VStack(spacing: 3) {
                        switchBadge(enabled: enabled, size: 30)
                        VStack(spacing: 1) {
                            Text(next.formatted(.dateTime.hour().minute()))
                                .font(.system(size: 16, weight: .semibold))
                                .monospacedDigit()
                                .foregroundStyle(WidgetStyle.primary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                            Text(name.isEmpty ? "Alarm" : name)
                                .font(.system(size: 11))
                                .foregroundStyle(WidgetStyle.secondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                        }
                        .opacity(enabled ? 1 : 0.45)
                    }
                } else {
                    // The badge is the switch. A bell in the badge and a
                    // second bell as the control said the same thing twice in
                    // 148pt, so the one mark both shows the state and is what
                    // you press to change it.
                    HStack(spacing: 10) {
                        switchBadge(enabled: enabled)
                        // A countdown to something that will not ring is a lie.
                        TileReading(value: next.formatted(.dateTime.hour().minute()),
                                    // When, not what: the name and the time
                                    // left together only fitted by shrinking
                                    // to a size no other tile uses. The name
                                    // is in the panel.
                                    caption: enabled ? countdownCaption(to: next) : "Off")
                            .opacity(enabled ? 1 : 0.45)
                        Spacer(minLength: 0)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// The bell in the tile's badge, pressable where the shelf is live.
    ///
    /// Neutral when silenced and a muted orange when armed: the state reads
    /// before the glyph does, without an orange disc shouting from the card.
    @ViewBuilder
    private func switchBadge(enabled: Bool, size: CGFloat = 40) -> some View {
        let badge = TileBadge(size: size) {
            Image(systemName: enabled ? "alarm.fill" : "alarm.slash.fill")
                .font(.system(size: size * 0.4, weight: .regular))
                .foregroundStyle(enabled
                                 ? Color(hex: PaletteColor.orange.hex).mix(with: WidgetStyle.primary, by: 0.55)
                                 : WidgetStyle.secondary)
        }
        if context.isPreview {
            badge
        } else {
            Button(action: toggle) { badge }
                .buttonStyle(.plain)
                // The badge's own square and no more, so the rest of the card
                // still belongs to the shelf.
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .accessibilityLabel(
                    "\(enabled ? "Turn off" : "Turn on") alarm at \(nextOccurrence.formatted(.dateTime.hour().minute()))"
                )
        }
    }

    private func toggle() {
        guard !context.isPreview else { return }
        let enabled = instance.config.bool("enabled", default: true)
        withAnimation(.snappy(duration: 0.3)) {
            WidgetWriter.write(instance) { config in
                config.set("enabled", .bool(!enabled))
            }
        }
    }

    /// Next time today's clock reaches the configured `HH:mm`; tomorrow once
    /// it has already passed.
    private var nextOccurrence: Date {
        let parts = instance.config.string("time", default: "14:30").split(separator: ":")
        let hour = parts.count == 2 ? Int(parts[0]) ?? 14 : 14
        let minute = parts.count == 2 ? Int(parts[1]) ?? 30 : 30
        let cal = Calendar.current
        guard let today = cal.date(bySettingHour: min(hour, 23), minute: min(minute, 59),
                                   second: 0, of: context.now) else { return context.now }
        guard today <= context.now else { return today }
        return cal.date(byAdding: .day, value: 1, to: today) ?? today
    }

    private func countdownCaption(to date: Date) -> String {
        let minutes = max(1, Int((date.timeIntervalSince(context.now) / 60).rounded(.up)))
        let (h, m) = (minutes / 60, minutes % 60)
        return h > 0 ? "in \(h)h \(m)m" : "in \(m)m"
    }
}
