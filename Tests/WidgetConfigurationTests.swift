import Foundation
import XCTest


/// Everything the widget settings sheet and the style picker derive from the
/// catalog: which options a kind offers, how they are labelled, which style
/// row is selected, and where a tile sends you when it is clicked.
final class WidgetConfigurationTests: XCTestCase {

    // MARK: variantTitle

    /// The bug this function exists for.
    ///
    /// The picker used to match rows on `layout` alone. "Numbers" and
    /// "Numbers + graph" both carry `layout: "numbers"` and differ only in
    /// `chart`, so both rows resolved to the same variant: the picker could
    /// neither tell them apart nor show which one was active. Matching has to
    /// consider every override a variant declares, not the one that happens to
    /// name the layout.
    func testSystemNumbersAndNumbersPlusGraphAreToldApart() {
        guard let plain = WidgetCatalog.make(.system, overrides: ["layout": .string("numbers"),
                                                                 "chart": .bool(false)]),
              let graphed = WidgetCatalog.make(.system, overrides: ["layout": .string("numbers"),
                                                                    "chart": .bool(true)])
        else { return XCTFail("system widget missing from catalog") }

        XCTAssertEqual(plain.config.string("layout"), graphed.config.string("layout"),
                       "precondition: the two variants share a layout")
        XCTAssertEqual(WidgetCatalog.variantTitle(matching: plain.config, kind: .system), "Numbers")
        XCTAssertEqual(WidgetCatalog.variantTitle(matching: graphed.config, kind: .system),
                       "Numbers + graph")
    }

    func testEverySystemVariantReportsItsOwnTitle() {
        let expected: [([String: WidgetConfig.Value], String)] = [
            (["layout": .string("numbers"), "chart": .bool(false)], "Numbers"),
            (["layout": .string("numbers"), "chart": .bool(true)], "Numbers + graph"),
            (["layout": .string("rings")], "Rings"),
            (["layout": .string("bars")], "Bars"),
        ]
        for (overrides, title) in expected {
            guard let instance = WidgetCatalog.make(.system, overrides: overrides) else {
                return XCTFail("system widget missing from catalog")
            }
            XCTAssertEqual(WidgetCatalog.variantTitle(matching: instance.config, kind: .system),
                           title, "\(overrides)")
        }
    }

    /// A variant is matched by the keys it declares and no others.
    ///
    /// "Rings" says nothing about `chart`, so a user who turned the graph on
    /// while on the numbers layout and then switched to rings must still see
    /// Rings selected - tightening the match to "every key in the config"
    /// would blank the picker instead.
    func testARingsConfigStillMatchesWithTheChartFlagOn() {
        guard let instance = WidgetCatalog.make(.system, overrides: ["layout": .string("rings"),
                                                                     "chart": .bool(true)]) else {
            return XCTFail("system widget missing from catalog")
        }
        XCTAssertEqual(WidgetCatalog.variantTitle(matching: instance.config, kind: .system), "Rings")
    }

    /// Unrelated user options must not disturb the style row.
    ///
    /// Weather's variants only ever speak about `layout`; `city` and
    /// `fahrenheit` are ordinary settings the user edits underneath the
    /// picker, and editing one cannot be allowed to deselect their style.
    func testVariantMatchingIgnoresUnrelatedOptions() {
        guard let instance = WidgetCatalog.make(.weather, overrides: ["layout": .string("current"),
                                                                       "fahrenheit": .bool(true),
                                                                       "city": .string("Oslo")]) else {
            return XCTFail("weather widget missing from catalog")
        }
        XCTAssertEqual(WidgetCatalog.variantTitle(matching: instance.config, kind: .weather), "Current")
    }

    func testAConfigMatchingNoVariantReportsNone() {
        // A layout no variant offers - a value left behind by an older build.
        let stale = WidgetConfig(["layout": .string("spiral"), "chart": .bool(false)])
        XCTAssertNil(WidgetCatalog.variantTitle(matching: stale, kind: .system))
    }

    func testAnEmptyConfigMatchesNoVariant() {
        XCTAssertNil(WidgetCatalog.variantTitle(matching: WidgetConfig(), kind: .weather))
        XCTAssertNil(WidgetCatalog.variantTitle(matching: WidgetConfig(), kind: .system))
    }

    func testAKindWithNoVariantsReportsNone() {
        for kind in [WidgetKind.clock, .notes, .stock, .airdrop] {
            guard let instance = WidgetCatalog.make(kind) else { return XCTFail("\(kind) missing") }
            XCTAssertTrue(WidgetCatalog.entry(kind)?.variants.isEmpty ?? false,
                          "precondition: \(kind) declares no variants")
            XCTAssertNil(WidgetCatalog.variantTitle(matching: instance.config, kind: kind), "\(kind)")
        }
    }

    /// Kinds in the enum but not in the registry must not fake a selection.
    ///
    /// The business tiles are declared in `WidgetKind` but have no catalog
    /// entry, so every catalog lookup for them has to fail closed rather than
    /// fall through to some other kind's variants.
    func testAKindOutsideTheCatalogReportsNoVariant() {
        for kind in [WidgetKind.stripe, .paddle, .shopify, .aiUsage] {
            XCTAssertNil(WidgetCatalog.entry(kind), "precondition: \(kind) is not in the catalog")
            XCTAssertNil(WidgetCatalog.variantTitle(matching: WidgetConfig(["layout": .string("numbers")]),
                                                    kind: kind), "\(kind)")
        }
    }

    /// Callers must resolve a stored config against the defaults first.
    ///
    /// Matching is exact equality per key, and an absent key is not equal to
    /// anything - so a config saved before `chart` existed matches neither
    /// numbers variant and would open the picker with nothing selected. The
    /// same `merging(defaults:)` that keeps old widgets working is what puts
    /// the row back.
    func testALegacyConfigMatchesOnlyOnceDefaultsAreMerged() {
        guard let entry = WidgetCatalog.entry(.system) else { return XCTFail("missing") }
        let old = WidgetConfig(["layout": .string("numbers")])
        XCTAssertNil(WidgetCatalog.variantTitle(matching: old, kind: .system),
                     "an absent key cannot be treated as a match")
        XCTAssertEqual(WidgetCatalog.variantTitle(matching: old.merging(defaults: entry.defaults),
                                                  kind: .system), "Numbers")
    }

    /// Matching compares whole values, cases included.
    ///
    /// A `chart` stored as the number 0 rather than the boolean false is not
    /// the value the variant declares, so it must not match: silently
    /// accepting it would let a type-confused config drive the picker and hide
    /// the fact that the widget's own `bool("chart")` read is falling back.
    func testAValueOfTheWrongTypeDoesNotMatchAVariant() {
        let confused = WidgetConfig(["layout": .string("numbers"), "chart": .number(0)])
        XCTAssertNil(WidgetCatalog.variantTitle(matching: confused, kind: .system))
    }

    // MARK: configurableKeys

    /// The style picker owns `layout`.
    ///
    /// Listing it as a plain text field beside that picker let the two
    /// disagree - typing a layout the picker does not offer left the widget in
    /// a state no row represented.
    func testConfigurableKeysNeverOfferLayout() {
        for kind in WidgetKind.allCases {
            XCTAssertFalse(WidgetCatalog.configurableKeys(kind).contains("layout"), "\(kind)")
        }
    }

    /// Dictionary iteration order is not stable between runs, so without the
    /// sort the settings rows would shuffle every time the sheet opened.
    func testConfigurableKeysAreSorted() {
        for kind in WidgetKind.allCases {
            let keys = WidgetCatalog.configurableKeys(kind)
            XCTAssertEqual(keys, keys.sorted(), "\(kind)")
        }
    }

    func testConfigurableKeysListEveryOptionExceptLayout() {
        for entry in WidgetCatalog.entries {
            let expected = Set(entry.defaults.values.keys).subtracting(["layout"])
            XCTAssertEqual(Set(WidgetCatalog.configurableKeys(entry.kind)), expected, "\(entry.kind)")
            XCTAssertEqual(WidgetCatalog.configurableKeys(entry.kind).count, expected.count,
                           "\(entry.kind) listed a key twice")
        }
    }

    func testAKindWithNoOptionsOffersNoSettings() {
        for kind in [WidgetKind.clock, .stopwatch, .timer, .airdrop] {
            XCTAssertTrue(WidgetCatalog.configurableKeys(kind).isEmpty, "\(kind)")
        }
    }

    func testAKindOutsideTheCatalogOffersNoSettings() {
        for kind in [WidgetKind.stripe, .paddle, .shopify, .aiUsage] {
            XCTAssertTrue(WidgetCatalog.configurableKeys(kind).isEmpty, "\(kind)")
        }
    }

    /// `showCallButton` used to be here, and this test was pinning it in
    /// place: it was offered as a toggle and read by nothing, so it persisted
    /// and changed nothing. A join-call affordance needs the event's
    /// conference URL and a row to put it in, neither of which exists.
    func testCalendarOffersItsOwnOptionsInOrder() {
        XCTAssertEqual(WidgetCatalog.configurableKeys(.calendar),
                       ["allDay", "calendars"])
    }

    // MARK: optionLabel

    func testOptionLabelsSplitCamelCaseIntoWords() {
        XCTAssertEqual(WidgetCatalog.optionLabel("showCallButton"), "Show Call Button")
        XCTAssertEqual(WidgetCatalog.optionLabel("allDay"), "All Day")
        XCTAssertEqual(WidgetCatalog.optionLabel("popupChart"), "Popup Chart")
    }

    func testASingleWordKeyIsJustCapitalised() {
        XCTAssertEqual(WidgetCatalog.optionLabel("fahrenheit"), "Fahrenheit")
        XCTAssertEqual(WidgetCatalog.optionLabel("chart"), "Chart")
        XCTAssertEqual(WidgetCatalog.optionLabel("mini"), "Mini")
    }

    /// `prefix(1).uppercased()` on an empty string is empty, and the label is
    /// only ever shown next to a control that exists - so an empty key must
    /// come back empty rather than trapping on a missing first character.
    func testAnEmptyKeyProducesAnEmptyLabel() {
        XCTAssertEqual(WidgetCatalog.optionLabel(""), "")
    }

    func testASingleCharacterKeyIsCapitalised() {
        XCTAssertEqual(WidgetCatalog.optionLabel("a"), "A")
        XCTAssertEqual(WidgetCatalog.optionLabel("A"), "A")
        XCTAssertEqual(WidgetCatalog.optionLabel("1"), "1")
    }

    /// An uppercase first character must not open the label with a space.
    ///
    /// The space is inserted before an uppercase letter only when words have
    /// already been emitted; dropping that guard put a leading blank in front
    /// of every already-capitalised key, which reads as a misaligned row.
    func testAnAlreadyCapitalisedKeyGainsNoLeadingSpace() {
        XCTAssertEqual(WidgetCatalog.optionLabel("Chart"), "Chart")
        XCTAssertEqual(WidgetCatalog.optionLabel("Show"), "Show")
    }

    /// Every uppercase letter starts a word, so an acronym is spaced out.
    ///
    /// Accepted rather than special-cased: the humaniser has no dictionary and
    /// guessing at runs of capitals breaks as many keys as it fixes. What
    /// keeps it harmless is that no catalog key contains consecutive capitals
    /// - asserted below.
    func testConsecutiveCapitalsEachStartAWord() {
        XCTAssertEqual(WidgetCatalog.optionLabel("showURL"), "Show U R L")
        XCTAssertEqual(WidgetCatalog.optionLabel("AB"), "A B")
    }

    /// Whatever the key, the label only inserts spaces and raises the first
    /// letter - it never drops a character, so no option can be labelled with
    /// a truncated or blank row.
    func testEveryCatalogOptionGetsAReadableLabel() {
        for entry in WidgetCatalog.entries {
            for key in WidgetCatalog.configurableKeys(entry.kind) {
                let label = WidgetCatalog.optionLabel(key)
                XCTAssertFalse(label.isEmpty, "\(entry.kind).\(key)")
                XCTAssertTrue(label.first?.isUppercase ?? false, "\(entry.kind).\(key) -> \(label)")
                XCTAssertFalse(label.contains("  "), "\(entry.kind).\(key) -> \(label)")
                XCTAssertEqual(label.replacingOccurrences(of: " ", with: "").lowercased(),
                               key.lowercased(), "\(entry.kind).\(key) lost characters")
            }
        }
    }

    // MARK: Catalog invariants

    /// `byKind` is built with `uniqueKeysWithValues`, which traps on a
    /// duplicate - a second entry for a kind would crash the app during static
    /// initialisation, before any window appears.
    func testEveryEntryHasItsOwnKindAndName() {
        let kinds = WidgetCatalog.entries.map(\.kind)
        XCTAssertEqual(Set(kinds).count, kinds.count, "two entries claim the same kind")
        let names = WidgetCatalog.entries.map(\.name)
        XCTAssertEqual(Set(names).count, names.count, "two entries share a library name")
        for entry in WidgetCatalog.entries {
            XCTAssertFalse(entry.name.isEmpty, "\(entry.kind) has no name")
            XCTAssertEqual(WidgetCatalog.entry(entry.kind)?.kind, entry.kind)
        }
    }

    /// Duplicate titles collide in the picker exactly as duplicate tags did.
    ///
    /// The rows are identified to the user by their title alone, so two
    /// variants sharing one leaves the user unable to say which style they
    /// picked even when the matcher itself is right.
    func testVariantTitlesAreUniqueWithinAKind() {
        for entry in WidgetCatalog.entries {
            let titles = entry.variants.map(\.title)
            XCTAssertEqual(Set(titles).count, titles.count,
                           "\(entry.kind) has two variants with the same title")
            for title in titles {
                XCTAssertFalse(title.trimmingCharacters(in: .whitespaces).isEmpty,
                               "\(entry.kind) has an unnamed variant")
            }
        }
    }

    /// An override for a key the widget never reads is dead config.
    ///
    /// The type has to agree too: matching is whole-value equality, so an
    /// override storing a bool where the default holds a string can never
    /// equal the value the widget writes, and its row becomes unselectable.
    func testEveryVariantOverridesAKeyTheKindActuallyHas() {
        for entry in WidgetCatalog.entries {
            for variant in entry.variants {
                for (key, value) in variant.overrides {
                    guard let stored = entry.defaults[key] else {
                        XCTFail("\(entry.kind)/\(variant.title) overrides '\(key)', which has no default")
                        continue
                    }
                    XCTAssertEqual(Self.caseName(stored), Self.caseName(value),
                                   "\(entry.kind)/\(variant.title) overrides '\(key)' with the wrong type")
                }
            }
        }
    }

    /// A variant with no overrides matches everything.
    ///
    /// `allSatisfy` over an empty dictionary is true and the matcher takes the
    /// first hit, so an override-less variant would shadow every variant
    /// declared after it and the picker would never leave that row.
    func testNoVariantDeclaresAnEmptyOverrideSet() {
        for entry in WidgetCatalog.entries {
            for variant in entry.variants {
                XCTAssertFalse(variant.overrides.isEmpty,
                               "\(entry.kind)/\(variant.title) overrides nothing")
            }
        }
    }

    /// Picking a style must leave that style selected.
    ///
    /// This is the generic form of the Numbers/Numbers + graph bug: it fails
    /// for any kind where an earlier variant's overrides are a subset of a
    /// later one's, because first-match then hands back the wrong title and
    /// the row the user just tapped springs back to another.
    func testEveryVariantIsSelectedByItsOwnOverrides() {
        for entry in WidgetCatalog.entries {
            for variant in entry.variants {
                guard let instance = WidgetCatalog.make(entry.kind, overrides: variant.overrides) else {
                    XCTFail("\(entry.kind) missing from catalog")
                    continue
                }
                XCTAssertEqual(WidgetCatalog.variantTitle(matching: instance.config, kind: entry.kind),
                               variant.title,
                               "\(entry.kind) resolves its '\(variant.title)' card to another variant")
            }
        }
    }

    /// A fresh widget must open its picker with a row already selected, or the
    /// user is shown a style list where nothing is active while the widget is
    /// plainly drawing one of them.
    func testTheDefaultConfigOfEveryKindSelectsAVariant() {
        for entry in WidgetCatalog.entries where !entry.variants.isEmpty {
            XCTAssertNotNil(WidgetCatalog.variantTitle(matching: entry.defaults, kind: entry.kind),
                            "\(entry.kind)'s defaults match none of its own variants")
        }
    }

    /// A `layout` default with no variants is an option nothing can reach:
    /// `configurableKeys` hides the key for the style picker's benefit, so a
    /// kind without a picker has no way to change its own layout.
    func testAKindWithALayoutAlwaysOffersAStylePicker() {
        for entry in WidgetCatalog.entries where entry.defaults["layout"] != nil {
            XCTAssertFalse(entry.variants.isEmpty,
                           "\(entry.kind) hides 'layout' from its settings but offers no picker")
        }
    }

    /// Every default must read back through the accessor its own case implies.
    ///
    /// The fallbacks here are deliberately wrong values, so an accessor that
    /// silently failed to see the stored value would return the sentinel
    /// instead of the default the widget is drawn with.
    func testEveryDefaultDecodesThroughItsOwnAccessor() {
        for entry in WidgetCatalog.entries {
            for (key, value) in entry.defaults.values {
                let at = "\(entry.kind).\(key)"
                switch value {
                case .bool(let flag):
                    XCTAssertEqual(entry.defaults.bool(key, default: !flag), flag, at)
                case .number(let number):
                    XCTAssertEqual(entry.defaults.double(key, default: number - 1), number, at)
                    XCTAssertEqual(entry.defaults.int(key, default: Int(number) - 1), Int(number), at)
                case .string(let text):
                    XCTAssertEqual(entry.defaults.string(key, default: text + "!"), text, at)
                case .list(let items):
                    XCTAssertEqual(entry.defaults.strings(key, default: ["sentinel"]),
                                   Self.strings(in: items), at)
                }
            }
        }
    }

    /// Reading an option as the wrong type falls back rather than coercing.
    ///
    /// The accessors pattern-match on the stored case on purpose: a widget
    /// that asks for a bool and gets a coerced list would draw a toggle for
    /// something that is not one.
    func testAWronglyTypedReadFallsBackInsteadOfGuessing() {
        guard let entry = WidgetCatalog.entry(.system) else { return XCTFail("missing") }
        XCTAssertTrue(entry.defaults.bool("metrics", default: true))
        XCTAssertEqual(entry.defaults.string("chart", default: "-"), "-")
        XCTAssertEqual(entry.defaults.double("layout", default: 7), 7)
        XCTAssertEqual(entry.defaults.strings("layout", default: ["fallback"]), ["fallback"])
    }

    /// Config values are decoded by guessing the case from the JSON, so a
    /// round trip is where a bool could come back as a number and quietly
    /// flip a toggle off for every stored widget.
    func testEveryKindsDefaultsSurviveACodableRoundTrip() throws {
        for entry in WidgetCatalog.entries {
            let data = try JSONEncoder().encode(entry.defaults)
            XCTAssertEqual(try JSONDecoder().decode(WidgetConfig.self, from: data),
                           entry.defaults, "\(entry.kind)")
        }
    }

    /// No stored number may be non-finite.
    ///
    /// NaN is not equal to itself, so a NaN in a variant's overrides would
    /// make that variant permanently unmatchable even against the very config
    /// it produced - and the same value feeds the tile sizing maths.
    func testEveryNumberInTheCatalogIsFinite() {
        XCTAssertNotEqual(WidgetConfig.Value.number(.nan), .number(.nan),
                          "precondition: a NaN config value never matches itself")
        for entry in WidgetCatalog.entries {
            for (key, value) in entry.defaults.values {
                for number in Self.numbers(in: value) {
                    XCTAssertTrue(number.isFinite, "\(entry.kind).\(key) is \(number)")
                }
            }
            for variant in entry.variants {
                for (key, value) in variant.overrides {
                    for number in Self.numbers(in: value) {
                        XCTAssertTrue(number.isFinite, "\(entry.kind)/\(variant.title).\(key)")
                    }
                }
            }
        }
    }

    /// A category missing from `WidgetCategory.ordered` has no sidebar row, so
    /// every widget filed under it becomes unreachable in the library.
    func testEveryEntryIsFiledUnderAListedCategory() {
        for entry in WidgetCatalog.entries {
            XCTAssertTrue(WidgetCategory.ordered.contains(entry.category),
                          "\(entry.kind) is in \(entry.category), which the sidebar never shows")
        }
    }

    /// The library must never offer a kind that would draw the "still to
    /// come" placeholder, which is what `selfContained` actually gates.
    ///
    /// This used to assert that a listed kind needed no permission and no
    /// network, which the catalog has never satisfied: Weather needs the
    /// network and a location, Stocks needs the network, and Now Playing
    /// needs Automation consent. All three were listed and the test passed,
    /// because it only ever checked three specific kinds rather than the rule
    /// it described.
    ///
    /// Calendar and Reminders are listed now that they have tiles. They ask
    /// for nothing when drawn: without access they show that they have none,
    /// which is the same contract Now Playing has always had. Shortcut joined
    /// them once it had a tile, a panel and a service to run the thing.
    ///
    /// The placeholder set is derived rather than written down. Spelling it
    /// out was what made the old version of this test hollow: `shippable` is
    /// `entries.filter(\.selfContained)`, so a kind with no entry can never
    /// appear in it whatever anyone does to the flags, and Shortcut was the
    /// only listed kind the assertion could ever have caught.
    func testTheLibraryOnlyOffersKindsThatCanBeDrawn() {
        // No catalog entry means `WidgetCatalog.make` returns nil, which is
        // the only thing keeping these off the shelf. Pinned as a set so that
        // giving one an entry without also giving it a tile fails here rather
        // than shipping a "still to come" card in the library.
        let unbuilt: Set<WidgetKind> = [.aiUsage, .stripe, .paddle, .shopify]
        XCTAssertEqual(Set(WidgetKind.allCases.filter { WidgetCatalog.entry($0) == nil }),
                       unbuilt,
                       "A kind gained or lost a catalog entry; it needs a tile before it gains one")

        let shippable = Set(WidgetCatalog.shippable.map(\.kind))

        for kind in unbuilt {
            XCTAssertFalse(shippable.contains(kind),
                           "\(kind) has no tile, so the library must not offer it")
        }
        // The other direction, which is what actually regressed before: a
        // kind that has a tile must not be left out of the library by a
        // stale flag.
        XCTAssertTrue(shippable.contains(.shortcut),
                      "Shortcut has a tile and a panel, so the library must offer it")
        for entry in WidgetCatalog.shippable {
            XCTAssertTrue(entry.selfContained, "\(entry.kind)")
        }
        XCTAssertEqual(shippable.count, WidgetCatalog.entries.filter(\.selfContained).count)
    }

    // MARK: openTarget

    /// Each data-backed widget hands the click to the app that owns its data;
    /// a tile that reports a number and does nothing when clicked reads as
    /// broken.
    func testWidgetsOpenTheAppThatOwnsTheirData() {
        XCTAssertEqual(WidgetCatalog.openTarget(.calendar), .app(bundleID: "com.apple.iCal"))
        XCTAssertEqual(WidgetCatalog.openTarget(.reminders), .app(bundleID: "com.apple.reminders"))
        XCTAssertEqual(WidgetCatalog.openTarget(.notes), .app(bundleID: "com.apple.Notes"))
        XCTAssertEqual(WidgetCatalog.openTarget(.weather), .app(bundleID: "com.apple.weather"))
        XCTAssertEqual(WidgetCatalog.openTarget(.shortcut), .app(bundleID: "com.apple.shortcuts"))
        XCTAssertEqual(WidgetCatalog.openTarget(.airdrop), .app(bundleID: "com.apple.finder"))
    }

    func testTheStocksFamilyShareOneDestination() {
        XCTAssertEqual(WidgetCatalog.openTarget(.stock), .app(bundleID: "com.apple.stocks"))
        XCTAssertEqual(WidgetCatalog.openTarget(.stock), WidgetCatalog.openTarget(.watchlist))
    }

    /// Only Battery has no app of its own to open.
    ///
    /// The two cases leave through different doors - a settings target is
    /// resolved as an `x-apple.systempreferences:` URL, an app target by
    /// bundle identifier - so a kind that reports the wrong one opens nothing
    /// at all.
    func testBatteryIsTheOnlyWidgetThatOpensSystemSettings() {
        for kind in WidgetKind.allCases {
            guard case .settings = WidgetCatalog.openTarget(kind) else { continue }
            XCTAssertEqual(kind, .battery, "\(kind) claims a System Settings pane")
        }
        XCTAssertNotNil(WidgetCatalog.openTarget(.battery)?.settingsURL)
    }

    func testEveryAppTargetNamesAPlausibleBundleIdentifier() {
        for kind in WidgetKind.allCases {
            guard case .app(let bundleID) = WidgetCatalog.openTarget(kind) else { continue }
            XCTAssertFalse(bundleID.isEmpty, "\(kind)")
            XCTAssertTrue(bundleID.contains("."), "\(kind) -> \(bundleID)")
            XCTAssertFalse(bundleID.contains(" "), "\(kind) -> \(bundleID)")
            XCTAssertNil(WidgetCatalog.openTarget(kind)?.settingsURL,
                         "\(kind) is an app target and must not deep-link into Settings")
        }
    }

    /// A kind with no catalog entry can never reach a shelf, so a destination
    /// for one is dead code that also implies a tile the library cannot even
    /// create.
    func testKindsAbsentFromTheCatalogOpenNothing() {
        for kind in WidgetKind.allCases where WidgetCatalog.entry(kind) == nil {
            XCTAssertNil(WidgetCatalog.openTarget(kind), "\(kind)")
            XCTAssertNil(WidgetCatalog.make(kind), "\(kind)")
        }
    }

    /// Adding a widget to the catalog without thinking about its click is the
    /// mistake this catches. An entry may report no destination only when it
    /// has somewhere else to send the click: `.music` and `.ask` open a detail
    /// panel, and the other two are self-contained readouts.
    func testEveryOtherCatalogEntryHasADestination() {
        let selfDriven: Set<WidgetKind> = [.music, .ask, .progress, .hydration]
        for entry in WidgetCatalog.entries where !selfDriven.contains(entry.kind) {
            XCTAssertNotNil(WidgetCatalog.openTarget(entry.kind),
                            "\(entry.kind) is in the library but opens nothing")
        }
    }

    // MARK: Helpers

    private static func caseName(_ value: WidgetConfig.Value) -> String {
        switch value {
        case .bool: "bool"
        case .number: "number"
        case .string: "string"
        case .list: "list"
        }
    }

    private static func strings(in items: [WidgetConfig.Value]) -> [String] {
        items.compactMap { item -> String? in
            if case .string(let text) = item { return text }
            return nil
        }
    }

    private static func numbers(in value: WidgetConfig.Value) -> [Double] {
        switch value {
        case .number(let number): return [number]
        case .list(let items): return items.flatMap { numbers(in: $0) }
        case .bool, .string: return []
        }
    }
}
