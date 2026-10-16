import SwiftUI

/// The Focus Timer panel: the tile's countdown at reading size, with the two
/// things the tile can only offer as a click and a double-click named as
/// buttons, and the session lengths it has no room for at all.
///
/// The timer is one timer for the whole app, so every action here writes
/// `TimerStateProvider.shared.state` on the tile's terms - pausing banks what
/// is left rather than the deadline, so resuming carries on from the figure on
/// screen instead of from a moment that has since gone by.
struct FocusTimerDetail: View {
    var instance: WidgetInstance
    var context: WidgetContext

    /// The four lengths a focus session is usually cut to; anything else is
    /// the stepper in settings.
    private static let presets = [15, 25, 45, 60]

    var body: some View {
        // The panel's context is captured once, when the panel opens, so it
        // carries the shelf's tick no further than the first second. The
        // schedule stands in for it rather than a timer of this view's own.
        TimelineView(.periodic(from: .now, by: 1)) { tick in
            content(now: tick.date)
        }
    }

    private func content(now: Date) -> some View {
        let state = TimerStateProvider.shared.state
        let total = max(1, state.duration ?? Double(state.minutes * 60))
        let left = remaining(in: state, total: total, now: now)
        let tint = WidgetStyle.tint(state.color)
        // A timer that has never run has nothing to put back.
        let untouched = state.deadline == nil && state.paused == nil && state.duration == nil

        // The timer's own colour as the ground, and the session draining out
        // of a bar along the card's foot: the whole card is the countdown.
        return DetailCard {
            MeshBackdrop(color: tint)
        } content: {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(sessionLine(state).uppercased())
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(0.8)
                        .foregroundStyle(Color.panelInk.opacity(0.7))
                        .lineLimit(1)
                    Text(docketClockString(left))
                        .font(.system(size: 64, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(WidgetStyle.primary)
                        .rollingValue(Int(left.rounded(.up)))
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                }

                HStack(spacing: 10) {
                    // White on the timer's colour, lettered in it: the one
                    // solid shape on the card is the one to press.
                    button(primaryTitle(state, left: left), fill: Color.panelInk.opacity(0.24), label: Color.panelInk,
                           action: { togglePrimary() })
                    button("Reset", fill: nil, label: Color.panelInk,
                           action: { reset() })
                        .disabled(untouched)
                        .opacity(untouched ? 0.4 : 1)
                }

                HStack(spacing: 6) {
                    ForEach(Self.presets, id: \.self) { minutes in
                        preset(minutes, active: Int((total / 60).rounded()) == minutes, tint: tint)
                    }
                }

                drain(left / total)
            }
        }
    }

    /// What is left of the session, to the card's edges and foot.
    private func drain(_ fraction: Double) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle().fill(Color.panelInk.opacity(0.14))
                Rectangle()
                    .fill(Color.panelInk.opacity(0.9))
                    .frame(width: geo.size.width * min(1, max(0, fraction)))
            }
        }
        .frame(height: 4)
        .padding(.horizontal, -16)
        .padding(.bottom, -16)
        .accessibilityHidden(true)
    }

    // MARK: - Pieces

    /// Solid for the action the panel is about, frosted for the other:
    /// resetting is the rarer choice and should not compete with starting.
    private func button(_ title: String, fill: Color?, label: Color,
                        action: @escaping () -> Void) -> some View {
        ClockPanelButton(title: title, fill: fill, ink: label, action: action)
    }

    private func preset(_ minutes: Int, active: Bool, tint: Color) -> some View {
        Button { pick(minutes) } label: {
            Text("\(minutes) min")
                .font(WidgetStyle.label(11))
                .foregroundStyle(Color.panelInk.opacity(active ? 1 : 0.75))
                .frame(maxWidth: .infinity)
                .frame(height: 26)
                .background(Capsule().fill(Color.panelInk.opacity(active ? 0.28 : 0.1)))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(minutes) minute session")
        .accessibilityAddTraits(active ? [.isSelected] : [])
    }

    /// Nothing in the app closes a session yet, so the count comes from the
    /// stored figure rather than from one invented here.
    private func sessionLine(_ state: TimerState) -> String {
        let session = min(state.completed + 1, max(1, state.sessions))
        return "\(state.phase.label) · Session \(session) of \(state.sessions)"
    }

    /// A countdown at zero has nothing to resume, so it offers a fresh start -
    /// which is what pressing it then does.
    private func primaryTitle(_ state: TimerState, left: TimeInterval) -> String {
        guard left > 0 else { return "Start" }
        if state.paused != nil { return "Resume" }
        return state.deadline == nil ? "Start" : "Pause"
    }

    // MARK: - Actions

    private func togglePrimary() {
        guard !context.isPreview else { return }
        var state = TimerStateProvider.shared.state
        let now = Date()
        let total = max(1, state.duration ?? Double(state.minutes * 60))
        let left = remaining(in: state, total: total, now: now)
        if state.deadline != nil, left > 0 {
            state.paused = left
            state.deadline = nil
        } else {
            // Starting pins the length now, so a session length changed in
            // settings cannot rescale a countdown that is already running.
            state.duration = total
            state.deadline = now.addingTimeInterval(left > 0 ? left : total)
            state.paused = nil
        }
        commit(state)
    }

    /// Clearing the pinned duration too, so a reset picks up a session length
    /// the user has changed since this timer last ran.
    private func reset() {
        guard !context.isPreview else { return }
        var state = TimerStateProvider.shared.state
        state.deadline = nil
        state.paused = nil
        state.duration = nil
        commit(state)
    }

    /// A preset pins the new length rather than restarting the session: the
    /// figure on screen keeps counting down from where it is, trimmed only if
    /// the length picked is shorter than what is left.
    private func pick(_ minutes: Int) {
        guard !context.isPreview else { return }
        var state = TimerStateProvider.shared.state
        let now = Date()
        let total = max(1, state.duration ?? Double(state.minutes * 60))
        let left = remaining(in: state, total: total, now: now)
        let picked = Double(minutes * 60)
        // The preset sets whichever phase is on screen, since that is the
        // length the panel is counting down.
        switch state.phase {
        case .focus: state.work = minutes
        case .rest: state.rest = minutes
        case .long: state.longBreak = minutes
        }
        if state.deadline != nil {
            state.duration = picked
            state.deadline = now.addingTimeInterval(min(left, picked))
        } else if state.paused != nil {
            state.duration = picked
            state.paused = min(left, picked)
        } else {
            // Idle: leaving the duration unpinned lets the phase's own length,
            // which the preset has just set, be what the panel counts from.
            state.duration = nil
        }
        commit(state)
    }

    private func commit(_ state: TimerState) {
        withAnimation(.snappy(duration: 0.3)) { TimerStateProvider.shared.state = state }
    }

    /// Paused wins over the deadline; with neither the timer is idle and sits
    /// at its full duration rather than at zero.
    private func remaining(in state: TimerState, total: TimeInterval, now: Date) -> TimeInterval {
        if let paused = state.paused { return max(0, min(paused, total)) }
        guard let deadline = state.deadline else { return total }
        return max(0, min(deadline.timeIntervalSince(now), total))
    }
}
