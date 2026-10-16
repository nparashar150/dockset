import SwiftUI

/// Renders one widget at its natural size.
///
/// The shelf is responsible for scaling this; see `ScaledWidgetTile`. Keeping
/// the scale out of here means every widget can be authored, previewed and
/// reasoned about at 1×.
public struct WidgetTile: View {
    public var instance: WidgetInstance
    public var context: WidgetContext

    public init(instance: WidgetInstance, context: WidgetContext) {
        self.instance = instance
        self.context = context
    }

    /// The instance with any options it predates filled in from the catalog.
    ///
    /// Config is deep-copied from the catalog when a widget is created, so a
    /// widget saved before an option existed simply has no key for it - and
    /// the typed accessors then fall back to Swift's zero value, not the
    /// catalog's. That silently disabled newly added features on every
    /// existing widget. Resolving here means it is impossible to forget.
    private var resolved: WidgetInstance {
        guard let defaults = WidgetCatalog.entry(instance.kind)?.defaults else { return instance }
        var copy = instance
        copy.config = instance.config.merging(defaults: defaults)
        return copy
    }

    public var body: some View {
        let item = resolved
        let size = WidgetCatalog.contentSize(item, position: context.position)
        content(item)
            .frame(width: size.width, height: size.height)
    }

    @ViewBuilder
    private func content(_ instance: WidgetInstance) -> some View {
        switch instance.kind {
        case .clock: ClockTile(instance: instance, context: context)
        case .world: WorldClockTile(instance: instance, context: context)
        case .stopwatch: StopwatchTile(instance: instance, context: context)
        case .timer: FocusTimerTile(instance: instance, context: context)
        case .progress: TimeProgressTile(instance: instance, context: context)
        case .countdown: CountdownTile(instance: instance, context: context)
        case .alarm: AlarmTile(instance: instance, context: context)
        case .hydration: HydrationTile(instance: instance, context: context)
        case .notes: StickyNoteTile(instance: instance, context: context)
        case .battery: BatteryTile(instance: instance, context: context)
        case .system: SystemActivityTile(instance: instance, context: context)
        case .network: NetworkActivityTile(instance: instance, context: context)
        case .airdrop: AirDropTile(instance: instance, context: context)
        case .stock: StockTile(instance: instance, context: context)
        case .watchlist: WatchlistTile(instance: instance, context: context)
        case .weather: WeatherTile(instance: instance, context: context)
        case .music: MusicTile(instance: instance, context: context)
        case .calendar: CalendarTile(instance: instance, context: context)
        case .reminders: RemindersTile(instance: instance, context: context)
        case .shortcut: ShortcutTile(instance: instance, context: context)
        case .ask: AskTile(instance: instance, context: context)
        // Still to come; a labelled placeholder beats rendering nothing. None
        // of these four can be placed today, so nothing reaches this arm:
        // they have no WidgetCatalog entry at all, so make returns nil. It
        // stays as the honest fallback for when they can be.
        case .aiUsage, .stripe, .paddle, .shopify:
            UnavailableTile(kind: instance.kind)
        }
    }
}

/// A widget the catalog knows about but this build cannot render yet.
struct UnavailableTile: View {
    var kind: WidgetKind

    var body: some View {
        WidgetSurface {
            VStack(spacing: 2) {
                Image(systemName: "clock.badge.questionmark")
                    .font(.system(size: 16))
                    .foregroundStyle(WidgetStyle.secondary)
                Text(WidgetCatalog.entry(kind)?.name ?? kind.rawValue)
                    .font(WidgetStyle.caption(11))
                    .foregroundStyle(WidgetStyle.secondary)
                    .lineLimit(1)
            }
        }
    }
}

/// A widget tile at shelf scale.
public struct ScaledWidgetTile: View {
    public var instance: WidgetInstance
    public var context: WidgetContext
    public var scale: Double

    public init(instance: WidgetInstance, context: WidgetContext, scale: Double) {
        self.instance = instance
        self.context = context
        self.scale = scale
    }

    public var body: some View {
        let tile = WidgetCatalog.tileSize(instance, position: context.position, scale: scale)
        let factor = Geometry.contentScale(scale)
        WidgetTile(instance: instance, context: context)
            .scaleEffect(factor, anchor: .center)
            .frame(width: tile.width, height: tile.height)
            // A scaleEffect does not clip; without this, any sizing mistake
            // paints a widget straight over the desktop.
            .clipped()
    }
}
