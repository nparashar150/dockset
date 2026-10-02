import SwiftUI

/// The countdown at reading size, with the restart the tile deliberately
/// refuses to offer and the lengths it has no room for.
///
/// The model is one key: `deadline`, an epoch, written by the tile's play
/// glyph. Present and in the future means running; absent means idle, and the
/// figure then stands at the full `duration` rather than at zero - again the
/// tile's own rule, so the card and the panel cannot disagree.
///
/// There is no pause. A paused countdown would have to bank what is left
/// somewhere the tile does not read, and the card would go on showing the
/// full length while the panel showed the banked one. Cancelling is honest
/// about what it costs; pausing would not be.
struct CountdownDetail: View {
    var instance: WidgetInstance
    var context: WidgetContext

    /// For a config that has not named its own lengths in `presets`. Minutes,
    /// like the setting they write.
    private static let fallbackPresets = [1, 5, 10, 15]

    var body: some View {
        // The panel's context is captured once, when the panel opens, so it
        // carries the shelf's tick no further than the first second. The
        // schedule stands in for it rather than a timer of this view's own.
        TimelineView(.periodic(from: .now, by: 1)) { tick in
            content(now: tick.date)
        }
    }

    private func content(now: Date) -> some View {
        let total = duration
        let left = remaining(duration: total, now: now)
        let running = isRunning(now: now)

        let fraction = total > 0 ? left / total : 0

        // The time left inside a ring that empties as it runs, on the
        // countdown's own colour.
        return DetailCard {
            MeshBackdrop(color: accent)
        } content: {
            VStack(spacing: 12) {
                ZStack {
                    Circle()
                        .stroke(.white.opacity(0.12), lineWidth: 5)
                    Circle()
                        .trim(from: 0, to: min(1, max(0, fraction)))
                        .stroke(.white.opacity(0.8), style: StrokeStyle(lineWidth: 5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    VStack(spacing: 2) {
                        Text(docketClockString(left))
                            .font(.system(size: 30, weight: .light))
                            .monospacedDigit()
                            .foregroundStyle(WidgetStyle.primary)
                            .rollingValue(Int(left.rounded(.up)))
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                        Text(caption(running: running, duration: total))
                            .font(WidgetStyle.label(11))
                            .foregroundStyle(.white.opacity(0.75))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .padding(.horizontal, 16)
                }
                .frame(width: 120, height: 120)
                .frame(maxWidth: .infinity)

                HStack(spacing: 10) {
                    // Restarting in flight throws away time already run, which is
                    // why the tile keeps it off the card and the panel carries it.
                    ClockPanelButton(title: running ? "Restart" : "Start",
                                     fill: .white.opacity(0.24), ink: .white) { start(duration: total) }
                    ClockPanelButton(title: "Cancel", fill: nil, action: cancel)
                        .disabled(deadline == nil)
                        .opacity(deadline == nil ? 0.4 : 1)
                }

                HStack(spacing: 6) {
                    ForEach(presets, id: \.self) { minutes in
                        preset(minutes,
                               active: Int((total / 60).rounded()) == minutes,
                               now: now)
                    }
                }
            }
        }
    }

    /// The countdown's catalog colour, the one its tile is drawn in.
    private var accent: Color {
        Color(hex: WidgetCatalog.accentHex(.countdown) ?? PaletteColor.indigo.hex)
    }

    // MARK: Pieces

    private func preset(_ minutes: Int, active: Bool, now: Date) -> some View {
        Button { pick(minutes, now: now) } label: {
            Text("\(minutes) min")
                .font(WidgetStyle.label(11))
                .foregroundStyle(.white.opacity(active ? 1 : 0.75))
                .frame(maxWidth: .infinity)
                .frame(height: 26)
                .background(Capsule().fill(Color.white.opacity(active ? 0.28 : 0.1)))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(minutes) minute countdown")
        .accessibilityAddTraits(active ? [.isSelected] : [])
    }

    /// What the countdown is for, and then the thing the tile cannot fit: the
    /// clock time it lands on while it runs, the length it will run for while
    /// it waits.
    private func caption(running: Bool, duration: TimeInterval) -> String {
        let name = instance.config.string("name")
        let title = name.isEmpty ? "Countdown" : name
        guard running, let deadline else {
            return "\(title) · \(Self.lengthLabel(duration))"
        }
        let ends = Date(timeIntervalSince1970: deadline)
            .formatted(.dateTime.hour().minute())
        return "\(title) · ends \(ends)"
    }

    // MARK: State
    //
    // The tile's accessors, key for key.

    private var duration: TimeInterval {
        max(0, instance.config.double("duration", default: 300))
    }

    /// Absent while idle, so the panel can tell "not started" from "finished"
    /// - both of which read 0:00 on a card.
    private var deadline: TimeInterval? {
        guard !context.isPreview, instance.config["deadline"] != nil else { return nil }
        return instance.config.double("deadline")
    }

    private func isRunning(now: Date) -> Bool {
        guard let deadline else { return false }
        return deadline > now.timeIntervalSince1970
    }

    private func remaining(duration: TimeInterval, now: Date) -> TimeInterval {
        guard let deadline else { return duration }
        return max(0, min(deadline - now.timeIntervalSince1970, duration))
    }

    /// `presets` in the widget's own config, read as minutes. The settings
    /// pane has no editor for the key, so an unset list falls back to the
    /// lengths a countdown is usually cut to rather than leaving the row
    /// empty - these are controls, not a claim about the user's timers.
    private var presets: [Int] {
        let configured = instance.config.strings("presets")
            .compactMap { Int($0.prefix(while: \.isNumber)) }
            .filter { $0 > 0 }
        return configured.isEmpty ? Self.fallbackPresets : configured
    }

    /// Reads a length the way the settings stepper does, so the panel and the
    /// setting behind it never word the same number differently.
    private static func lengthLabel(_ duration: TimeInterval) -> String {
        WidgetSettingsSections.format("duration", duration)
    }

    // MARK: Actions

    /// The deadline is stored rather than a remaining time, so the countdown
    /// keeps running across a relaunch instead of resuming where it stopped.
    private func start(duration: TimeInterval) {
        guard !context.isPreview else { return }
        withAnimation(.snappy(duration: 0.3)) {
            WidgetWriter.write(instance) { config in
                config.set("deadline", .number(Date.now.timeIntervalSince1970 + duration))
            }
        }
    }

    /// Clearing the key rather than zeroing it: a countdown with no deadline
    /// is the idle state the tile draws, sitting at its full length with its
    /// start glyph back.
    private func cancel() {
        guard !context.isPreview else { return }
        withAnimation(.snappy(duration: 0.3)) {
            WidgetWriter.write(instance) { config in
                config.set("deadline", nil)
            }
        }
    }

    /// A preset sets the length the countdown runs for, and trims one already
    /// in flight rather than restarting it - restarting is the button above.
    private func pick(_ minutes: Int, now: Date) {
        guard !context.isPreview else { return }
        let picked = Double(minutes * 60)
        let left = remaining(duration: duration, now: now)
        let running = isRunning(now: now)
        withAnimation(.snappy(duration: 0.3)) {
            WidgetWriter.write(instance) { config in
                config.set("duration", .number(picked))
                if running {
                    config.set("deadline",
                               .number(Date.now.timeIntervalSince1970 + min(left, picked)))
                }
            }
        }
    }
}
