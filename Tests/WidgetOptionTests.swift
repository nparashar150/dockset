import Foundation
import XCTest

/// The controls the Widgets tab builds for a widget's options.
///
/// Every defect these cover had the same shape: the control rendered, it
/// accepted input, and the value went nowhere useful. A setting that looks
/// like it worked is worse than one that is missing.
final class WidgetOptionTests: XCTestCase {

    // MARK: Reading with the catalog's default

    /// A widget saved before a key existed carries no value for it, and the
    /// control used to read it with Swift's zero rather than the catalog's
    /// default. So the toggle showed off while the tile ran on, until it was
    /// touched once and the disagreement wrote itself into the file.
    func testAMissingKeyReadsAsTheCatalogDefault() {
        for kind in WidgetKind.allCases {
            guard let entry = WidgetCatalog.entry(kind) else { continue }
            let empty = WidgetConfig()
            for key in WidgetCatalog.configurableKeys(kind) {
                switch entry.defaults.values[key] {
                case .bool(let fallback):
                    XCTAssertEqual(empty.bool(key, default: fallback), fallback,
                                   "\(kind.rawValue).\(key)")
                case .string(let fallback):
                    XCTAssertEqual(empty.string(key, default: fallback), fallback,
                                   "\(kind.rawValue).\(key)")
                default:
                    continue
                }
            }
        }
    }

    /// And a stored value still wins, or the control could not change anything.
    func testAStoredValueBeatsTheDefault() {
        var config = WidgetConfig()
        config.set("chart", .bool(true))
        XCTAssertTrue(config.bool("chart", default: false))
    }

    // MARK: Every option has some control

    /// The Widgets tab builds a control per configurable key. A key whose
    /// shape has no branch renders nothing, so the option exists, is stored,
    /// and cannot be reached: `symbols` was exactly that.
    func testEveryConfigurableKeyHasAShapeThatCanBeRendered() {
        for kind in WidgetKind.allCases {
            guard let entry = WidgetCatalog.entry(kind) else { continue }
            for key in WidgetCatalog.configurableKeys(kind) {
                let value = entry.defaults.values[key]
                XCTAssertNotNil(value, "\(kind.rawValue).\(key) is listed but has no default")
                switch value {
                case .bool, .number, .string, .list: break
                case .none: XCTFail("\(kind.rawValue).\(key) has no value to render")
                }
            }
        }
    }

    // MARK: Nothing offered that nothing reads

    /// Every configurable key becomes a control in the Widgets tab, so a key
    /// the widget never reads is a switch that persists and changes nothing.
    /// Eleven of them shipped that way across four widgets.
    ///
    /// Pinned as a list rather than inferred, because the reader lives in a
    /// view the test target cannot see. The list is the promise: adding a key
    /// here means committing to read it, and the failure message says so.
    func testNoWidgetOffersAnOptionItDoesNotRead() {
        let expected: [WidgetKind: Set<String>] = [
            .world: ["city", "zone"],
            .progress: ["period"],
            .countdown: ["duration", "name", "presets"],
            .alarm: ["time", "name"],
            .hydration: ["duration", "trackAmounts", "drinkSize", "goal", "reminders"],
            .calendar: ["allDay", "calendars"],
            .reminders: ["list"],
            .notes: ["text", "color"],
            .music: ["mini", "previous", "next", "backward", "forward",
                     "skip", "spotify", "apple", "browsers", "hideWhenClosed"],
            .battery: ["devices"],
            .system: ["chart", "metrics"],
            .network: ["display", "chart"],
            .shortcut: ["name"],
            .stock: ["symbol", "symbols", "chart", "refresh", "names"],
            .watchlist: ["symbols", "refresh", "names"],
            .weather: ["city", "fahrenheit"],
        ]

        for kind in WidgetKind.allCases {
            guard WidgetCatalog.entry(kind) != nil else { continue }
            let offered = Set(WidgetCatalog.configurableKeys(kind))
            let promised = expected[kind] ?? []
            XCTAssertEqual(offered, promised, """
                \(kind.rawValue) offers \(offered.sorted()) but this test \
                expects \(promised.sorted()). If you added an option, read it \
                somewhere and add it here. If you removed one, drop it here \
                too. An option nothing reads is a control that persists and \
                does nothing.
                """)
        }
    }

    // MARK: Readers agreeing on a default

    /// A widget saved before an option existed carries no value for it, so
    /// every reader has to fall back to the same thing. `naturalSize` read
    /// System Activity's metrics with no default while the tile and the panel
    /// both defaulted to two, so the tile measured as one column and drew two.
    func testAnUnconfiguredWidgetIsMeasuredForWhatItDraws() {
        let bare = WidgetInstance(kind: .system, config: WidgetConfig())
        var explicit = bare
        explicit.config.set("metrics", .list([.string("cpu"), .string("memory")]))

        XCTAssertEqual(WidgetCatalog.naturalSize(bare),
                       WidgetCatalog.naturalSize(explicit),
                       "no stored metrics has to measure the same as the default it draws")
    }

    /// And the sizes really do differ by count, or the test above would pass
    /// for the wrong reason.
    func testTheSizeDependsOnHowManyMetricsThereAre() {
        var one = WidgetInstance(kind: .system, config: WidgetConfig())
        one.config.set("metrics", .list([.string("cpu")]))
        var three = one
        three.config.set("metrics", .list([.string("cpu"), .string("memory"), .string("disk")]))

        XCTAssertNotEqual(WidgetCatalog.naturalSize(one).width,
                          WidgetCatalog.naturalSize(three).width)
    }

    // MARK: Free-form lists

    /// The watchlist editor is a comma separated field, so the parse is the
    /// whole feature. Whitespace, trailing separators and empty entries all
    /// arrive while someone is still typing.
    func testCommaSeparatedEntriesAreParsedForgivingly() {
        XCTAssertEqual(parse("AAPL, MSFT,NVDA"), ["AAPL", "MSFT", "NVDA"])
        XCTAssertEqual(parse("  AAPL  ,   MSFT  "), ["AAPL", "MSFT"])
        XCTAssertEqual(parse("AAPL,,MSFT"), ["AAPL", "MSFT"], "a double comma is a typo, not a gap")
        XCTAssertEqual(parse("AAPL,"), ["AAPL"], "mid-edit, having just typed the separator")
    }

    /// An empty field is a half-finished edit rather than a request for a
    /// widget with nothing in it, so it must not be written.
    func testAnEmptyListIsNotWritten() {
        XCTAssertTrue(parse("").isEmpty)
        XCTAssertTrue(parse("   ,  , ").isEmpty)
    }

    private func parse(_ text: String) -> [String] {
        text.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    // MARK: Round trip

    /// What the field shows has to be what a save would produce, or an edit
    /// that changes nothing still rewrites the value.
    func testTheListSurvivesADisplayAndReparse() {
        let original = ["AAPL", "MSFT", "NVDA"]
        XCTAssertEqual(parse(original.joined(separator: ", ")), original)
    }
}

/// Whether an option means anything given the rest of the configuration.
///
/// An option that applies to one layout and not another is the same defect as
/// one nothing reads: the control accepts a change and produces none.
final class OptionApplicabilityTests: XCTestCase {

    private func system(layout: String) -> WidgetConfig {
        var config = WidgetConfig()
        config.set("layout", .string(layout))
        return config
    }

    func testTheChartAppliesToNumbersOnly() {
        XCTAssertTrue(WidgetCatalog.applies("chart", to: system(layout: "numbers"), kind: .system))
        XCTAssertFalse(WidgetCatalog.applies("chart", to: system(layout: "rings"), kind: .system))
        XCTAssertFalse(WidgetCatalog.applies("chart", to: system(layout: "bars"), kind: .system))
    }

    /// The default layout is numbers, so an unconfigured widget offers it.
    func testAnUnconfiguredWidgetStillOffersTheChart() {
        XCTAssertTrue(WidgetCatalog.applies("chart", to: WidgetConfig(), kind: .system))
    }

    /// Only System Activity's chart is conditional. Network has charted and
    /// uncharted variants with no layout key, so its own switch always means
    /// something.
    func testNetworksChartIsNotConditional() {
        XCTAssertTrue(WidgetCatalog.applies("chart", to: WidgetConfig(), kind: .network))
    }

    private func music(mini: Bool) -> WidgetConfig {
        var config = WidgetConfig()
        config.set("mini", .bool(mini))
        return config
    }

    /// Mini Now Playing is a 64pt chip: artwork and one glyph, which is play
    /// and pause. The wide layout is the only one that draws skipping and
    /// seeking, so in mini those five controls accepted a change and drew
    /// nothing.
    func testTheTransportOptionsApplyToTheWideLayoutOnly() {
        for key in ["previous", "next", "backward", "forward", "skip"] {
            XCTAssertTrue(WidgetCatalog.applies(key, to: music(mini: false), kind: .music),
                          "\(key) is drawn by the wide layout")
            XCTAssertFalse(WidgetCatalog.applies(key, to: music(mini: true), kind: .music),
                           "\(key) draws nothing in mini, so it must not be offered")
        }
    }

    /// Which players to watch still means something in mini: the chip shows
    /// whichever source is playing, so narrowing the sources narrows what it
    /// can show.
    func testTheSourceOptionsApplyInMiniToo() {
        for key in ["spotify", "apple", "browsers"] {
            XCTAssertTrue(WidgetCatalog.applies(key, to: music(mini: true), kind: .music), key)
        }
    }

    /// Every option that is conditional at all, so adding a rule means
    /// coming here and saying so.
    ///
    /// The loop below uses a default config, which is the honest limit of
    /// this test: a rule that only hides a control once some non-default
    /// value is set would pass it. Both rules that exist today flip on a
    /// value away from its default, which is why each is also pinned by a
    /// test of its own above.
    private static let conditional: Set<String> = [
        "system.chart",
        "music.previous", "music.next", "music.backward", "music.forward", "music.skip",
    ]

    /// Everything else is unconditional, and a rule added carelessly would
    /// silently hide a working control.
    func testNothingElseIsHiddenByAccident() {
        for kind in WidgetKind.allCases {
            for key in WidgetCatalog.configurableKeys(kind)
            where !Self.conditional.contains("\(kind.rawValue).\(key)") {
                XCTAssertTrue(WidgetCatalog.applies(key, to: WidgetConfig(), kind: kind),
                              "\(kind.rawValue).\(key) should not be conditional")
            }
        }
    }

    /// The catalog's own variant list has always implied this: it offers
    /// Numbers and Numbers + graph, and no charted ring or bar.
    func testTheVariantsNeverChartARingOrABar() {
        guard let entry = WidgetCatalog.entry(.system) else { return XCTFail("no entry") }
        for variant in entry.variants {
            let layout = variant.overrides["layout"]
            let charted = variant.overrides["chart"] == .bool(true)
            if charted {
                XCTAssertEqual(layout, .string("numbers"),
                               "\(variant.title) charts a layout that cannot draw one")
            }
        }
    }
}
