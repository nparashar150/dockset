import SwiftUI

/// Routes a widget to its own detail content.
///
/// One switch rather than a protocol with two dozen conformances: the bodies
/// have nothing in common beyond being a view, and the chrome around them is
/// already shared by `WidgetDetailChrome`.
struct WidgetDetailBody: View {
    var instance: WidgetInstance
    var context: WidgetContext

    var body: some View {
        switch instance.kind {
        case .music:
            MusicDetail(instance: instance, context: context)
        case .timer:
            FocusTimerDetail(instance: instance, context: context)
        case .calendar:
            CalendarDetail(instance: instance, context: context)
        case .battery:
            BatteryDetail(instance: instance, context: context)
        case .system:
            SystemActivityDetail(instance: instance, context: context)
        case .notes:
            StickyNoteDetail(instance: instance, context: context)
        case .stripe, .paddle, .shopify:
            RevenueDetail(instance: instance, context: context)
        case .stock, .watchlist:
            StocksDetail(instance: instance, context: context)
        case .weather:
            WeatherDetail(instance: instance, context: context)
        case .clock:
            ClockDetail(instance: instance, context: context)
        case .world:
            WorldClockDetail(instance: instance, context: context)
        case .stopwatch:
            StopwatchDetail(instance: instance, context: context)
        case .countdown:
            CountdownDetail(instance: instance, context: context)
        case .alarm:
            AlarmDetail(instance: instance, context: context)
        case .progress:
            TimeProgressDetail(instance: instance, context: context)
        case .hydration:
            HydrationDetail(instance: instance, context: context)
        case .network:
            NetworkDetail(instance: instance, context: context)
        case .airdrop:
            AirDropDetail(instance: instance, context: context)
        case .reminders:
            RemindersDetail(instance: instance, context: context)
        case .shortcut:
            ShortcutDetail(instance: instance, context: context)
        case .ask:
            AskDetail(instance: instance, context: context)
        default:
            // Only `.aiUsage` reaches this now, and it is a stub: no tile,
            // no service, nothing to read. Better an honest line than a
            // panel that explains its own absence.
            Text("No further detail for this widget.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The colour this panel should stand on, if its widget has one.
    ///
    /// Here rather than in the chrome so the chrome gains no knowledge of
    /// kinds, and here rather than a PreferenceKey because the panel reads
    /// its own fitting size exactly once and a preference travelling up
    /// through that measurement is a risk taken for nothing.
    @MainActor
    static func ground(_ instance: WidgetInstance, _ context: WidgetContext) -> ArtworkTint? {
        switch instance.kind {
        case .music: MusicDetail.ground(instance: instance, context: context)
        default: nil
        }
    }
}
