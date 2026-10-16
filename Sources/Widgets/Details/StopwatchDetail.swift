import SwiftUI

/// The stopwatch at reading size, with the two glyphs the tile shrinks to 9pt
/// named as buttons.
///
/// Everything here is the tile's own two config keys: `started`, the epoch the
/// current run began, and `elapsed`, what earlier runs banked. The panel reads
/// and writes them exactly as the tile does, so the two can never disagree
/// about whether the watch is running.
///
/// There is no lap list. Nothing in the model records a lap, and a panel is
/// not the place to invent one.
struct StopwatchDetail: View {
    var instance: WidgetInstance
    var context: WidgetContext

    var body: some View {
        // Tenths are the one thing a 21pt tile readout cannot carry, and the
        // panel's `context.now` is frozen at the moment it opened - so the
        // schedule is what moves the figure. A stopped watch has nothing to
        // redraw ten times a second; the schedule is rebuilt when the config
        // changes, which is the same moment `running` flips.
        TimelineView(.periodic(from: .now, by: running ? 0.1 : 1)) { tick in
            content(now: tick.date)
        }
    }

    private func content(now: Date) -> some View {
        let elapsed = elapsed(at: now)

        // Graphite lit with the stopwatch's orange, and a seconds dial sweeping
        // behind the figure: the one thing a stopwatch does is go round.
        return DetailCard {
            ZStack(alignment: .trailing) {
                MeshBackdrop(color: Self.orange.mix(with: Color(white: 0.2), by: 0.55))
                SweepDial(fraction: elapsed.truncatingRemainder(dividingBy: 60) / 60,
                          running: running)
                    .frame(width: 230, height: 230)
                    .offset(x: 70)
            }
        } content: {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 1) {
                        Text(StopwatchTile.format(elapsed))
                            .font(.system(size: 56, weight: .semibold, design: .rounded))
                            .foregroundStyle(WidgetStyle.primary)
                            // Only the seconds roll: a tenth that animated would
                            // still be mid-transition when the next one landed.
                            .rollingValue(Int(elapsed))
                        Text(".\(Int(elapsed * 10) % 10)")
                            .font(.system(size: 28, weight: .semibold, design: .rounded))
                            .foregroundStyle(Self.orange)
                    }
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)

                    Text(caption)
                        .font(WidgetStyle.label(12))
                        .foregroundStyle(Color.panelInk.opacity(0.7))
                        .lineLimit(1)
                }
                .padding(.top, 6)

                HStack(spacing: 10) {
                    ClockPanelButton(title: running ? "Stop" : "Start",
                                     fill: Self.orange, action: toggle)
                    ClockPanelButton(title: "Reset", fill: nil, action: reset)
                        .disabled(untouched)
                        .opacity(untouched ? 0.4 : 1)
                }
            }
        }
    }

    private static let orange = Color(hex: PaletteColor.orange.hex)

    // MARK: State
    //
    // The tile's accessors, key for key.

    private var startedAt: TimeInterval { instance.config.double("started") }
    private var banked: TimeInterval { instance.config.double("elapsed") }
    private var running: Bool { startedAt > 0 }
    /// A watch that has never run has nothing to clear.
    private var untouched: Bool { !running && banked == 0 }

    private func elapsed(at now: Date) -> TimeInterval {
        guard running else { return banked }
        return banked + max(0, now.timeIntervalSince1970 - startedAt)
    }

    /// The wall-clock moment the run on screen began - the one fact the config
    /// holds that neither the tile nor the readout can say. A run picked up
    /// after a stop says "Resumed", because `started` is then the resume
    /// rather than the beginning.
    private var caption: String {
        guard running else { return banked > 0 ? "Paused" : "Ready" }
        let since = Date(timeIntervalSince1970: startedAt)
            .formatted(date: .omitted, time: .standard)
        return (banked > 0 ? "Resumed " : "Started ") + since
    }

    // MARK: Actions

    /// Banks what has run so far when stopping, so starting again continues
    /// rather than beginning from zero - the tile's own rule.
    private func toggle() {
        guard !context.isPreview else { return }
        let started = startedAt
        let banked = banked
        withAnimation(.snappy(duration: 0.3)) {
            WidgetWriter.write(instance) { config in
                if started > 0 {
                    config.set("elapsed",
                               .number(banked + max(0, Date.now.timeIntervalSince1970 - started)))
                    config.set("started", .number(0))
                } else {
                    config.set("started", .number(Date.now.timeIntervalSince1970))
                }
            }
        }
    }

    private func reset() {
        guard !context.isPreview else { return }
        withAnimation(.snappy(duration: 0.3)) {
            WidgetWriter.write(instance) { config in
                config.set("started", .number(0))
                config.set("elapsed", .number(0))
            }
        }
    }
}

/// A ring of sixty ticks with the current second lit and a trail behind it,
/// set large and faint behind the figure.
private struct SweepDial: View {
    var fraction: Double
    var running: Bool

    var body: some View {
        ZStack {
            ForEach(0..<60, id: \.self) { tick in
                Capsule()
                    .fill(Color.panelInk.opacity(tick % 5 == 0 ? 0.22 : 0.1))
                    .frame(width: tick % 5 == 0 ? 2 : 1, height: tick % 5 == 0 ? 10 : 6)
                    .offset(y: -105)
                    .rotationEffect(.degrees(Double(tick) * 6))
            }
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(Color(hex: PaletteColor.orange.hex).opacity(running ? 0.55 : 0.3),
                        style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .padding(18)
        }
        .accessibilityHidden(true)
    }
}

/// The panel-sized action the clock tiles can only offer as a glyph the size
/// of itself.
///
/// Shared by the Stopwatch, Countdown and Alarm panels so the three read as
/// one family, and weighted like the Focus Timer's pair: solid for the action
/// the panel is about, frosted for the one that throws work away. Drawn for a
/// coloured card, so the frosted form is a pane of white rather than an
/// outline that the card's colour would swallow.
struct ClockPanelButton: View {
    var title: String
    /// nil draws the frosted form.
    var fill: Color?
    /// Ink on the solid form. White on a saturated fill, the card's own colour
    /// on a white one.
    var ink: Color = Color.panelInk
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(WidgetStyle.label(13))
                .foregroundStyle(fill == nil ? Color.panelInk : ink)
                .frame(maxWidth: .infinity)
                .frame(height: 36)
                .background {
                    Capsule()
                        .fill(fill ?? Color.panelInk.opacity(0.14))
                        .overlay {
                            Capsule().strokeBorder(Color.panelInk.opacity(fill == nil ? 0.18 : 0), lineWidth: 0.5)
                        }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
