import Foundation

/// The widget registry. Order drives the order of the library.
///
/// Sizes are natural, unscaled native points, matching the shipped app's
/// catalog. The shelf applies `Geometry.contentScale` on top; the cross-axis
/// extent is always fixed by the shelf (62pt tall on a bottom shelf, 76pt wide
/// on a side one), so in practice only the long axis here varies.
public enum WidgetCatalog {

    public struct Entry: Sendable {
        public var kind: WidgetKind
        public var name: String
        public var category: WidgetCategory
        public var defaults: WidgetConfig
        /// Library cards beyond the default one: (title, config overrides).
        public var variants: [(title: String, overrides: [String: WidgetConfig.Value])]
        /// Whether this kind can collapse to a narrow tile.
        public var supportsCompact: Bool
        /// Whether the library offers this kind.
        ///
        /// It was described as "no permissions, no network", and has never
        /// meant that: Weather needs the network and a location, Stocks needs
        /// the network, Now Playing needs Automation consent, and all three
        /// are listed. What it actually gates is whether a kind has a tile
        /// that renders something honest, so the only kinds excluded are the
        /// ones that would draw the "still to come" placeholder.
        public var selfContained: Bool
    }

    private static func c(_ pairs: [String: WidgetConfig.Value]) -> WidgetConfig { WidgetConfig(pairs) }

    public static let entries: [Entry] = [
        // No config: the API key lives in the Keychain, never in the state
        // file, and there is nothing else to choose.
        Entry(kind: .ask, name: "Ask", category: .assistant, defaults: c([:]),
              variants: [], supportsCompact: false, selfContained: true),

        Entry(kind: .clock, name: "Clock", category: .clocks, defaults: c([:]),
              variants: [], supportsCompact: true, selfContained: true),

        Entry(kind: .world, name: "World Clock", category: .clocks,
              defaults: c(["city": .string("London"), "zone": .string("Europe/London")]),
              variants: [], supportsCompact: true, selfContained: true),

        Entry(kind: .stopwatch, name: "Stopwatch", category: .clocks, defaults: c([:]),
              variants: [], supportsCompact: true, selfContained: true),

        Entry(kind: .timer, name: "Focus Timer", category: .clocks, defaults: c([:]),
              variants: [], supportsCompact: true, selfContained: true),

        Entry(kind: .progress, name: "Time Progress", category: .clocks,
              defaults: c(["layout": .string("bars"), "period": .string("year")]),
              variants: [("Bars", ["layout": .string("bars")]),
                         ("Ring", ["layout": .string("ring")]),
                         ("Percentage", ["layout": .string("percentage")])],
              supportsCompact: true, selfContained: true),

        Entry(kind: .countdown, name: "Countdown", category: .clocks,
              defaults: c(["duration": .number(300), "name": .string(""), "presets": .list([])]),
              variants: [], supportsCompact: false, selfContained: true),

        Entry(kind: .alarm, name: "Alarm", category: .clocks,
              defaults: c(["time": .string("14:30"), "name": .string("Call Alex")]),
              variants: [], supportsCompact: false, selfContained: true),

        Entry(kind: .hydration, name: "Hydration", category: .reminders,
              defaults: c(["duration": .number(2700)]),
              variants: [], supportsCompact: false, selfContained: true),

        // No `showCallButton`: read by nothing. A join-call affordance needs
        // the event's conference URL and a row to put it in, neither of which
        // exists, so the switch promised something that was never built.
        Entry(kind: .calendar, name: "Calendar", category: .calendar,
              defaults: c(["layout": .string("nextEvent"), "allDay": .bool(true),
                           "calendars": .list([])]),
              variants: [("Next event", ["layout": .string("nextEvent")]),
                         ("Date + next event", ["layout": .string("dateAndEvent")]),
                         ("Date + agenda", ["layout": .string("agenda")]),
                         ("Date", ["layout": .string("date")])],
              supportsCompact: true, selfContained: true),

        Entry(kind: .reminders, name: "Reminders", category: .reminders,
              defaults: c(["layout": .string("list"), "list": .string("")]),
              variants: [("List", ["layout": .string("list")]),
                         ("Next reminder", ["layout": .string("next")]),
                         ("Count", ["layout": .string("count")])],
              supportsCompact: true, selfContained: true),

        Entry(kind: .notes, name: "Sticky Note", category: .notes,
              defaults: c(["text": .string(""), "color": .string("yellow")]),
              variants: [], supportsCompact: false, selfContained: true),

        Entry(kind: .music, name: "Now Playing", category: .media,
              defaults: c(["mini": .bool(false), "previous": .bool(true), "next": .bool(true),
                           "backward": .bool(false), "forward": .bool(false), "skip": .number(15),
                           "spotify": .bool(true), "apple": .bool(true),
                           // Falls back to video playing in a scriptable
                           // browser tab when no native player has anything.
                           "browsers": .bool(true)]),
              variants: [("Full", ["mini": .bool(false)]), ("Mini", ["mini": .bool(true)])],
              supportsCompact: false, selfContained: true),

        Entry(kind: .battery, name: "Battery", category: .system,
              defaults: c(["layout": .string("status"),
                           "devices": .list([.string("mac")])]),
              variants: [("Status", ["layout": .string("status")]),
                         ("Percentage ring", ["layout": .string("gauge")]),
                         ("Icon only", ["layout": .string("icon")])],
              supportsCompact: false, selfContained: true),

        Entry(kind: .system, name: "System Activity", category: .system,
              // No chart by default: the shipped design is clean numbers with
              // a coloured dot, and a sparkline behind them crowds a 62pt
              // strip. Offered as its own variant instead.
              defaults: c(["layout": .string("numbers"), "chart": .bool(false),
                           "metrics": .list([.string("cpu"), .string("memory")])]),
              variants: [("Numbers", ["layout": .string("numbers"), "chart": .bool(false)]),
                         ("Numbers + graph", ["layout": .string("numbers"), "chart": .bool(true)]),
                         ("Rings", ["layout": .string("rings")]),
                         ("Bars", ["layout": .string("bars")])],
              supportsCompact: true, selfContained: true),

        // No `popupChart`: it was read by nothing, and the detail panel it
        // presumably meant now exists and always draws its history.
        Entry(kind: .network, name: "Network Activity", category: .system,
              defaults: c(["display": .string("both"), "chart": .bool(false)]),
              variants: [("Numbers only", ["chart": .bool(false)]),
                         ("With chart", ["chart": .bool(true)])],
              supportsCompact: true, selfContained: true),

        Entry(kind: .shortcut, name: "Shortcut", category: .system,
              defaults: c(["name": .string("")]),
              variants: [], supportsCompact: false, selfContained: true),

        Entry(kind: .airdrop, name: "AirDrop", category: .system, defaults: c([:]),
              variants: [], supportsCompact: false, selfContained: true),

        // `period`, `metric`, `reference` and `style` were offered here and
        // read by nothing: the service fetches a fixed intraday range,
        // DitherChart has no reference line and no styles, and no reader ever
        // asked for a metric. Every one of them persisted and changed nothing.
        // They come back with the code that honours them, not before.
        Entry(kind: .stock, name: "Stock", category: .stocks,
              defaults: c(["symbol": .string("AAPL"),
                           "symbols": .list([.string("AAPL")]),
                           "chart": .bool(true)]),
              variants: [], supportsCompact: true, selfContained: true),

        // No `chart` here, unlike Stock: this tile is a list of rows and has
        // never drawn one, so the switch had nothing to switch.
        Entry(kind: .watchlist, name: "Watchlist", category: .stocks,
              defaults: c(["symbols": .list([.string("AAPL"), .string("MSFT"), .string("NVDA")])]),
              variants: [], supportsCompact: false, selfContained: true),

        Entry(kind: .weather, name: "Weather", category: .weather,
              // Empty city: use wherever the user actually is. "Oslo" is the
              // city in the reference screenshots, not a sane default.
              defaults: c(["layout": .string("current"), "fahrenheit": .bool(false),
                           "city": .string("")]),
              variants: [("Current", ["layout": .string("current")]),
                         ("Conditions", ["layout": .string("conditions")]),
                         ("Hourly forecast", ["layout": .string("hourly")])],
              supportsCompact: true, selfContained: true),
    ]

    private static let byKind: [WidgetKind: Entry] = Dictionary(
        uniqueKeysWithValues: entries.map { ($0.kind, $0) }
    )

    public static func entry(_ kind: WidgetKind) -> Entry? { byKind[kind] }

    /// The colour a widget's detail panel is tinted with.
    ///
    /// The reference shelf tints an open panel toward whatever the widget is
    /// *about* - Stripe teal, a sticky note its own paper, activity the
    /// magenta of its CPU ring - while readouts with no colour of their own
    /// stay neutral. A tint on everything would be noise; a tint on nothing
    /// makes eight identical panels.
    public static func accentHex(_ kind: WidgetKind) -> String? {
        switch kind {
        case .stripe: PaletteColor.teal.hex
        case .paddle, .shopify: PaletteColor.yellow.hex
        case .notes: PaletteColor.yellow.hex
        case .calendar, .reminders: PaletteColor.orange.hex
        case .system: MetricColor.cpu
        case .network: MetricColor.netUpload
        case .stock, .watchlist: PaletteColor.green.hex
        case .aiUsage, .ask: PaletteColor.indigo.hex
        case .hydration: PaletteColor.blue.hex
        // Neutral: a clock, a battery or a player is not "about" a colour.
        case .clock, .world, .stopwatch, .timer, .progress, .countdown,
             .alarm, .music, .battery, .shortcut, .airdrop, .weather:
            nil
        }
    }

    /// The keys a widget's settings UI should offer.
    ///
    /// `layout` is excluded: the style picker owns it, and listing it as a
    /// plain text field alongside that picker let the two disagree.
    public static func configurableKeys(_ kind: WidgetKind) -> [String] {
        guard let entry = entry(kind) else { return [] }
        return entry.defaults.values.keys.filter { $0 != "layout" }.sorted()
    }

    /// Whether an option means anything given the rest of the configuration.
    ///
    /// Some options only apply to one layout. System Activity's chart is
    /// drawn behind its numbers and there is nowhere for it to go behind
    /// rings or bars, so the switch sat there accepting changes and doing
    /// nothing in two of the four layouts, and switching to one of them did
    /// not clear it either: a widget could be left storing chart true while
    /// showing bars, and going back to numbers brought a graph nobody asked
    /// for.
    ///
    /// The catalog already knew this. Its variants offer "Numbers" and
    /// "Numbers + graph" and no charted ring or bar, so this states what the
    /// variant list has always implied.
    public static func applies(_ key: String, to config: WidgetConfig,
                               kind: WidgetKind) -> Bool {
        switch (kind, key) {
        case (.system, "chart"):
            config.string("layout", default: "numbers") == "numbers"
        // Mini is a 64pt chip: artwork and one glyph, which is play and
        // pause. Skipping, seeking and the seek distance are drawn by the
        // wide layout only, so in mini these were five controls that
        // accepted a change and produced none. Offering an option that does
        // nothing is the same defect as offering one nothing reads.
        case (.music, "previous"), (.music, "next"), (.music, "backward"),
             (.music, "forward"), (.music, "skip"):
            !config.bool("mini")
        default:
            true
        }
    }

    /// "showRunningApps" -> "Show Running Apps".
    public static func optionLabel(_ key: String) -> String {
        var words = ""
        for character in key {
            if character.isUppercase, !words.isEmpty { words.append(" ") }
            words.append(character)
        }
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    /// Which variant a config currently matches, by title.
    ///
    /// Every override must match, not just `layout`: "Numbers" and
    /// "Numbers + graph" share a layout and differ only by `chart`, so
    /// matching on layout alone made them indistinguishable - the style
    /// picker could neither tell them apart nor show the right one.
    public static func variantTitle(matching config: WidgetConfig,
                                    kind: WidgetKind) -> String? {
        guard let entry = entry(kind) else { return nil }
        return entry.variants.first { variant in
            variant.overrides.allSatisfy { config.values[$0.key] == $0.value }
        }?.title
    }

    /// Where a widget sends you when its card is clicked.
    ///
    /// Every tile in the Dock opens something; a widget that reports a number
    /// and does nothing when you click it reads as broken. A tile's own
    /// controls may only take the click where they actually sit - a gesture
    /// spread over the whole card beats this one everywhere and leaves the
    /// card dead, which is exactly how every widget panel came to be
    /// unreachable.
    public static func openTarget(_ kind: WidgetKind) -> WidgetTarget? {
        switch kind {
        case .clock, .world, .alarm, .timer, .stopwatch, .countdown:
            .app(bundleID: "com.apple.clock")
        case .calendar:
            .app(bundleID: "com.apple.iCal")
        case .reminders:
            .app(bundleID: "com.apple.reminders")
        case .notes:
            .app(bundleID: "com.apple.Notes")
        case .weather:
            .app(bundleID: "com.apple.weather")
        case .stock, .watchlist:
            .app(bundleID: "com.apple.stocks")
        // CPU, memory and network all report what Activity Monitor owns.
        case .system, .network:
            .app(bundleID: "com.apple.ActivityMonitor")
        case .battery:
            .settings("com.apple.Battery-Settings.extension")
        case .airdrop:
            .app(bundleID: "com.apple.finder")
        case .shortcut:
            .app(bundleID: "com.apple.shortcuts")
        // No honest destination: `music` would have to guess between Music and
        // Spotify while its own transport already owns the card, `progress`
        // and `hydration` are self-contained, and the business tiles are for
        // dashboards we cannot address.
        // Ask opens its own panel, which is where the question is typed.
        case .music, .progress, .hydration, .aiUsage, .stripe, .paddle, .shopify, .ask:
            nil
        }
    }

    public static var shippable: [Entry] { entries.filter(\.selfContained) }

    /// Fresh instance with a deep copy of the catalog defaults, so array
    /// defaults are never shared between two widgets of the same kind.
    public static func make(_ kind: WidgetKind, overrides: [String: WidgetConfig.Value] = [:]) -> WidgetInstance? {
        guard let entry = byKind[kind] else { return nil }
        var config = entry.defaults
        for (k, v) in overrides { config.set(k, v) }
        return WidgetInstance(kind: kind, expanded: true, config: config)
    }

    // MARK: Sizing

    /// Natural size before the shelf's scale is applied.
    ///
    /// `expanded == false` collapses to the compact width, which only kinds
    /// with `supportsCompact` can request.
    public static func naturalSize(_ instance: WidgetInstance) -> CGSize {
        let cfg = instance.config
        let entry = byKind[instance.kind]
        let expanded = instance.expanded || !(entry?.supportsCompact ?? false)
        guard expanded else { return CGSize(width: compactWidth(instance.kind), height: 62) }

        switch instance.kind {
        case .clock, .world: return CGSize(width: 168, height: 132)
        case .stopwatch: return CGSize(width: 168, height: 80)
        case .timer: return CGSize(width: 168, height: 124)
        case .progress:
            switch cfg.string("layout", default: "bars") {
            case "ring": return CGSize(width: 148, height: 76)
            case "percentage": return CGSize(width: 112, height: 62)
            default: return CGSize(width: 176, height: 78)
            }
        case .countdown: return CGSize(width: 140, height: 72)
        case .alarm, .hydration: return CGSize(width: 168, height: 124)
        case .calendar:
            switch cfg.string("layout", default: "nextEvent") {
            case "date": return CGSize(width: 88, height: 76)
            case "dateAndEvent": return CGSize(width: 244, height: 132)
            case "agenda": return CGSize(width: 300, height: 132)
            default: return CGSize(width: 168, height: 132)
            }
        case .reminders:
            switch cfg.string("layout", default: "list") {
            case "next": return CGSize(width: 180, height: 132)
            case "count": return CGSize(width: 88, height: 76)
            default: return CGSize(width: 220, height: 132)
            }
        case .notes: return CGSize(width: 160, height: 100)
        case .music:
            return cfg.bool("mini") ? CGSize(width: 64, height: 62) : CGSize(width: 264, height: 132)
        case .battery:
            let devices = max(1, cfg.strings("devices", default: ["mac"]).count)
            if devices == 1, cfg.string("layout", default: "status") == "status" {
                return CGSize(width: 168, height: 132)
            }
            return CGSize(width: Double(devices * 44 + (devices - 1) * 8 + 20),
                          height: devices > 2 ? 116 : 62)
        case .system:
            // With the catalog's default, like every other reader of this key.
            // Without it a widget carrying no stored `metrics` measured as one
            // column and drew two, so the tile was sized too narrow for its
            // own contents.
            let metrics = max(1, cfg.strings("metrics", default: ["cpu", "memory"]).count)
            let layout = cfg.string("layout", default: "numbers")
            if layout == "bars" { return CGSize(width: 168, height: 62) }
            let rings = layout == "rings"
            // The per-metric widths are content widths; the tile also has to
            // pay for WidgetSurface's horizontal inset, or a two-metric tile
            // truncates "Memory" to "Memo…". 168pt for two metrics matches the
            // shipped render exactly.
            // 20pt for WidgetSurface's horizontal inset plus 8pt of breathing
            // room. Hardcoded rather than read from WidgetStyle so the catalog
            // stays free of SwiftUI and keeps compiling into the test target.
            let inset = 28.0
            return CGSize(width: Double(metrics * (rings ? 66 : 70)) + inset,
                          height: Double(metrics * (rings ? 60 : 46) + 16))
        case .network:
            return cfg.bool("chart") ? CGSize(width: 160, height: 84) : CGSize(width: 100, height: 62)
        case .aiUsage: return CGSize(width: 192, height: 132)
        case .shortcut: return CGSize(width: 140, height: 76)
        case .airdrop: return CGSize(width: 100, height: 76)
        case .ask: return CGSize(width: 168, height: 76)
        case .weather:
            return cfg.string("layout", default: "current") == "hourly"
                ? CGSize(width: 216, height: 132) : CGSize(width: 148, height: 132)
        case .stripe, .paddle:
            return cfg.bool("chart", default: true)
                ? CGSize(width: 200, height: 144) : CGSize(width: 148, height: 108)
        case .shopify: return CGSize(width: 200, height: 132)
        case .stock: return CGSize(width: 192, height: 132)
        case .watchlist: return CGSize(width: 276, height: 176)
        }
    }

    private static func compactWidth(_ kind: WidgetKind) -> Double {
        switch kind {
        case .stopwatch: 120
        case .network: 110
        default: 88
        }
    }

    /// Width of a side shelf's column. Matches the icon column, so a left or
    /// right shelf stays a narrow strip rather than a 168pt slab.
    public static let columnWidth: Double = 76

    /// The size a widget's content is authored at, before the shelf scales it.
    ///
    /// Orientation changes the shape of a widget, not just its scale. A bottom
    /// shelf gives a widget a wide 62pt strip; a side shelf gives it a narrow
    /// 76pt column, and each widget draws a genuinely different, stacked
    /// layout for it. Reusing the wide layout in a column either crops it into
    /// nonsense or forces the whole shelf absurdly wide.
    public static func contentSize(_ instance: WidgetInstance, position: DockPosition) -> CGSize {
        if position.isVertical {
            return CGSize(width: columnWidth, height: verticalHeight(instance))
        }
        let canCompact = byKind[instance.kind]?.supportsCompact ?? false
        let width = (canCompact && !instance.expanded)
            ? compactWidth(instance.kind)
            : naturalSize(instance).width
        // Shorter than the 62pt icon tile on purpose: the cards read as
        // oversized when they match the row exactly. The plate is pinned by
        // the icons (Geometry.iconGeometry), so this only shrinks the cards.
        return CGSize(width: width, height: 58)
    }

    /// Long-axis extent of a widget's stacked, column layout.
    public static func verticalHeight(_ instance: WidgetInstance) -> Double {
        let cfg = instance.config
        switch instance.kind {
        case .clock, .world: return 76
        case .stopwatch, .countdown: return 62
        case .timer: return 92
        case .alarm: return 76
        case .hydration: return 88
        case .notes: return 96
        case .airdrop: return 76
        case .progress:
            return cfg.string("layout", default: "bars") == "percentage" ? 58 : 80
        case .battery:
            let devices = max(1, cfg.strings("devices", default: ["mac"]).count)
            return Double(devices * 62)
        case .system:
            let metrics = max(1, cfg.strings("metrics", default: ["cpu", "memory"]).count)
            // Each metric gets a row: sparkline, value, label.
            return Double(metrics * 54 + 8)
        case .network:
            return cfg.string("display", default: "both") == "both" ? 76 : 46
        default:
            return 76
        }
    }

    /// Size the shelf actually lays out.
    public static func tileSize(_ instance: WidgetInstance, position: DockPosition, scale: Double) -> CGSize {
        let f = Geometry.contentScale(scale)
        let content = contentSize(instance, position: position)
        return CGSize(width: content.width * f, height: content.height * f)
    }

}
