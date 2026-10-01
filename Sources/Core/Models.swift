import Foundation

// MARK: - Shelf placement & look

/// A stored choice that survives a value it does not recognise.
///
/// Synthesized `Codable` throws on an unknown raw value, and one throw
/// anywhere rejects the whole state file, which `Store.load()` answers by
/// setting the file aside and starting from a first-run default. So a single
/// misspelled word, or a downgrade to a build that predates one option, cost
/// the user every profile, widget and pinned app.
///
/// Only for choices where falling back is honestly better than failing: an
/// edge, a material, a colour. Deliberately NOT adopted by `WidgetKind`, where
/// the nearest equivalent would silently turn somebody's widget into a clock.
/// An unknown widget is dropped instead, which `DockItem` handles.
public protocol LenientChoice: RawRepresentable, Codable where RawValue == String {
    /// What an unrecognised value reads as.
    static var fallback: Self { get }
}

public extension LenientChoice {
    init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: raw) ?? Self.fallback
    }
}

public enum DockSetup: String, Codable, Sendable, CaseIterable {
    /// Apple's Dock only. No shelf, so no widgets.
    case macOSDockOnly = "native"
    /// Both surfaces visible. The sane default.
    case both
    /// Shelf replaces Apple's Dock, which gets auto-hidden.
    case customReplacement = "custom"
}

/// What Apple's Dock looked like before Docket borrowed its reserved strip.
///
/// Persisted rather than held in memory. Docket promises to put these back,
/// and a crash between changing them and quitting must not turn that into a
/// lie: whatever is recorded here is what gets restored, whenever the app next
/// gets the chance.
public struct DockPrefs: Codable, Hashable, Sendable {
    public var autoHide: Bool
    public var tileSize: Double
    public var orientation: String

    public init(autoHide: Bool, tileSize: Double, orientation: String) {
        self.autoHide = autoHide
        self.tileSize = tileSize
        self.orientation = orientation
    }
}

public enum DockPosition: String, Codable, Sendable, CaseIterable {
    case left, bottom, right   // deliberately no .top - the menu bar owns that edge
    public var isVertical: Bool { self != .bottom }
}

public enum ProfileKind: String, Codable, Sendable, CaseIterable {
    case macOSDock, customDock
}

public enum AppAppearance: String, Codable, Sendable, CaseIterable {
    case system, light, dark
}

public enum DockMaterial: String, Codable, Sendable, CaseIterable {
    case liquidGlass, frosted
}

public enum GlassStyle: String, Codable, Sendable, CaseIterable {
    case regular, clear
}

public enum MenuBarLabelMode: String, Codable, Sendable, CaseIterable {
    case none, native, custom, both
}

public enum SpacerSize: String, Codable, Sendable, CaseIterable {
    case small, regular
    /// Apple's Dock stores spacers as these tile types.
    public var dockTileType: String { self == .small ? "small-spacer-tile" : "spacer-tile" }
}

// MARK: - Palettes

public enum PaletteColor: String, Codable, Sendable, CaseIterable {
    case orange, yellow, pink, purple, blue, green, graphite, indigo, red, teal

    public var hex: String {
        switch self {
        case .orange: "#FF8D28"
        case .yellow: "#FFCC00"
        case .pink: "#FF2D55"
        case .purple: "#CB30E0"
        case .blue: "#0088FF"
        case .green: "#34C759"
        case .graphite: "#8E8E93"
        case .indigo: "#6155F5"
        case .red: "#FF383C"
        case .teal: "#00C3D0"
        }
    }

    /// The 8 swatches actually offered in pickers - `yellow` and `graphite`
    /// exist for stored values but are not user-selectable.
    public static let picker: [PaletteColor] = [.orange, .red, .pink, .purple, .indigo, .blue, .teal, .green]
}

public enum PaperColor: String, Codable, Sendable, CaseIterable {
    case yellow, orange, pink, purple, blue, green, graphite

    public var hex: String {
        switch self {
        case .yellow: "#F5D15C"
        case .orange: "#FFB36E"
        case .pink: "#F5A3BA"
        case .purple: "#C7ADEE"
        case .blue: "#96C7F5"
        case .green: "#ADD985"
        case .graphite: "#CFCCC2"
        }
    }

    public static let picker: [PaperColor] = [.yellow, .orange, .pink, .purple, .blue, .green]
}

public enum MetricColor {
    public static let cpu = "#CE32E3"
    public static let memory = "#078AFF"
    public static let storage = "#FF9F0A"
    public static let batteryPresent = "#34C759"
    public static let netDownload = "#078AFF"
    public static let netUpload = "#AF52DE"
}

// MARK: - Widget identity

public enum WidgetKind: String, Codable, Sendable, CaseIterable {
    // Registry order drives library order.
    case clock, world, stopwatch, timer, progress, countdown, alarm
    case hydration, calendar, reminders, notes, music, battery, system
    case network, aiUsage = "ai-usage", shortcut, airdrop, weather
    case stripe, paddle, stock, watchlist, shopify
    // Appended, so no stored raw value moves; the library's order comes from
    // the catalog, not from here.
    case ask
}

/// What a widget opens when its card is clicked.
public enum WidgetTarget: Equatable, Sendable {
    case app(bundleID: String)
    /// A System Settings pane, by extension identifier.
    case settings(String)

    /// The URL scheme System Settings registers for deep links.
    public var settingsURL: URL? {
        guard case .settings(let pane) = self else { return nil }
        return URL(string: "x-apple.systempreferences:\(pane)")
    }
}

public enum WidgetCategory: String, Codable, Sendable, CaseIterable {
    case clocks = "Clocks"
    case reminders = "Reminders"
    case calendar = "Calendar"
    case notes = "Sticky Notes"
    case media = "Media"
    case system = "System"
    case weather = "Weather"
    case business = "Business"
    case stocks = "Stocks"
    case assistant = "Assistant"

    /// Library sidebar order.
    public static let ordered: [WidgetCategory] = [
        .assistant, .clocks, .reminders, .calendar, .notes, .media, .system, .weather, .business,
        .stocks,
    ]
}

// MARK: - Widget configuration

/// Loosely-typed widget config, mirroring the catalog's "deep-copy the default
/// dictionary" model. A typed struct per kind would be 24 more Codable types
/// and a migration burden every time one gains an option; each widget instead
/// reads what it needs through typed accessors and tolerates missing keys.
public struct WidgetConfig: Codable, Hashable, Sendable {
    public enum Value: Codable, Hashable, Sendable {
        case bool(Bool)
        case number(Double)
        case string(String)
        case list([Value])

        public init(from decoder: any Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let b = try? c.decode(Bool.self) { self = .bool(b) }
            else if let d = try? c.decode(Double.self) { self = .number(d) }
            else if let s = try? c.decode(String.self) { self = .string(s) }
            else if let l = try? c.decode([Value].self) { self = .list(l) }
            else {
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unsupported config value")
            }
        }

        public func encode(to encoder: any Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self {
            case .bool(let b): try c.encode(b)
            case .number(let d): try c.encode(d)
            case .string(let s): try c.encode(s)
            case .list(let l): try c.encode(l)
            }
        }
    }

    public var values: [String: Value]

    public init(_ values: [String: Value] = [:]) { self.values = values }

    public subscript(key: String) -> Value? {
        get { values[key] }
        set { values[key] = newValue }
    }

    public func bool(_ key: String, default fallback: Bool = false) -> Bool {
        if case .bool(let b) = values[key] { return b }
        return fallback
    }

    public func double(_ key: String, default fallback: Double = 0) -> Double {
        if case .number(let d) = values[key] { return d }
        return fallback
    }

    public func int(_ key: String, default fallback: Int = 0) -> Int {
        if case .number(let d) = values[key] { return Int(d) }
        return fallback
    }

    public func string(_ key: String, default fallback: String = "") -> String {
        if case .string(let s) = values[key] { return s }
        return fallback
    }

    public func strings(_ key: String, default fallback: [String] = []) -> [String] {
        guard case .list(let l) = values[key] else { return fallback }
        return l.compactMap { if case .string(let s) = $0 { return s } else { return nil } }
    }

    public mutating func set(_ key: String, _ value: Value?) { values[key] = value }

    /// Config carried by an instance, with any keys the catalog has since
    /// added filled in from the default. Keeps old saved widgets working when
    /// a widget gains an option.
    public func merging(defaults: WidgetConfig) -> WidgetConfig {
        WidgetConfig(defaults.values.merging(values) { _, mine in mine })
    }
}

public struct WidgetInstance: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var kind: WidgetKind
    /// New widgets always start expanded; only kinds with a compact variant
    /// can ever be false.
    public var expanded: Bool
    public var config: WidgetConfig

    public init(id: UUID = UUID(), kind: WidgetKind, expanded: Bool = true, config: WidgetConfig) {
        self.id = id
        self.kind = kind
        self.expanded = expanded
        self.config = config
    }
}

// MARK: - Shelf items

public struct FolderIcon: Codable, Hashable, Sendable {
    /// nil means "System color" - draw Finder's own icon.
    public var color: PaletteColor?
    /// Exactly one letter or digit, or nil.
    public var letter: String?

    public init(color: PaletteColor? = nil, letter: String? = nil) {
        self.color = color
        self.letter = letter
    }

    public var isEmpty: Bool { color == nil && letter == nil }
}

/// A file-system reference that survives the target being moved or renamed.
///
/// Docket is not sandboxed, so the bookmark is not about access rights - it is
/// purely so a pinned app still resolves after an update relocates it.
public struct FileRef: Codable, Hashable, Sendable {
    public var url: URL
    public var bookmark: Data?

    public init(url: URL, bookmark: Data? = nil) {
        self.url = url
        self.bookmark = bookmark
    }

    public static func capture(_ url: URL) -> FileRef {
        FileRef(url: url, bookmark: try? url.bookmarkData(options: [.minimalBookmark]))
    }

    /// Resolved location, preferring the bookmark. Returns nil when the target
    /// is genuinely gone - callers render that as a repairable dead item
    /// rather than silently dropping the user's entry.
    public func resolve() -> URL? {
        if let bookmark {
            var stale = false
            if let resolved = try? URL(resolvingBookmarkData: bookmark, options: [], bookmarkDataIsStale: &stale),
               FileManager.default.fileExists(atPath: resolved.path(percentEncoded: false)) {
                return resolved
            }
        }
        return FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) ? url : nil
    }
}

/// A tint a group's plate can carry, as on iOS.
///
/// A name rather than a colour so it survives Codable and so the light and
/// dark renderings can differ; the view layer owns the actual swatches.
public enum GroupTint: String, Codable, Hashable, Sendable, CaseIterable {
    case none, red, orange, yellow, green, teal, blue, purple, pink, graphite
}

/// A folder of dock items, shown as one tile with a grid of its contents.
public struct DockGroup: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var tint: GroupTint
    public var items: [DockItem]

    public init(id: UUID = UUID(), name: String, tint: GroupTint = .none,
                items: [DockItem] = []) {
        self.id = id
        self.name = name
        self.tint = tint
        self.items = items
    }

    /// How many icons the closed tile shows: a 2×2 grid, as Dockset does.
    ///
    /// Not a preference - the tile is one dock slot wide, and a third column
    /// would put the icons below the size at which their artwork is legible.
    public static let previewCount = 4

    /// The icons drawn on the closed tile.
    public var preview: [DockItem] { Array(items.prefix(Self.previewCount)) }

    /// How many are not shown, for the overflow marker.
    public var hiddenCount: Int { max(0, items.count - Self.previewCount) }
}

public enum DockItem: Codable, Hashable, Identifiable, Sendable {
    case app(id: UUID, bundleID: String, ref: FileRef)
    case folder(id: UUID, ref: FileRef, icon: FolderIcon)
    case file(id: UUID, ref: FileRef)
    case link(id: UUID, url: URL, title: String)
    case spacer(id: UUID, size: SpacerSize)
    case widget(WidgetInstance)
    case group(DockGroup)

    public var id: UUID {
        switch self {
        case .app(let id, _, _), .folder(let id, _, _), .file(let id, _),
             .link(let id, _, _), .spacer(let id, _):
            return id
        case .widget(let w):
            return w.id
        case .group(let g):
            return g.id
        }
    }

    public var group: DockGroup? {
        if case .group(let g) = self { return g }
        return nil
    }

    public var widget: WidgetInstance? {
        if case .widget(let w) = self { return w }
        return nil
    }

    public var isWidget: Bool { widget != nil }

    /// Apple's Dock can only represent apps and spacers.
    public var isRepresentableInMacOSDock: Bool {
        switch self {
        case .app, .spacer: true
        case .folder, .file, .link, .widget, .group: false
        }
    }

    public var fileRef: FileRef? {
        switch self {
        case .app(_, _, let r), .folder(_, let r, _), .file(_, let r): r
        case .link, .spacer, .widget, .group: nil
        }
    }
}

// MARK: - Profiles

public struct KeyCombo: Codable, Hashable, Sendable {
    public var keyCode: UInt32
    /// Carbon modifier mask. Enforced to carry at least two modifiers.
    public var modifiers: UInt32

    public init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }
}

/// Swallows one element of any shape.
///
/// An unkeyed container only advances when something is decoded from it, so
/// skipping a bad element still needs a successful decode. This accepts
/// anything, which is the point.
private struct DiscardedItem: Decodable {
    init(from decoder: any Decoder) throws {
        _ = try? decoder.singleValueContainer()
    }
}

public struct DockProfile: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var kind: ProfileKind
    public var name: String
    public var color: PaletteColor
    public var items: [DockItem]
    /// Travels with a customDock profile; ignored for macOSDock profiles.
    public var scale: Double
    /// Reserved, and read by nothing yet.
    ///
    /// Both are groundwork for switching profiles without the menu bar: a
    /// global hotkey, and a Focus filter that changes the shelf when a Focus
    /// turns on. They are carried through save, restore and duplicate so a
    /// setup made today survives into the build that honours them, and
    /// `duplicateProfile` deliberately drops the hotkey, since two profiles
    /// must never claim one key combination.
    ///
    /// Kept rather than removed because the plan for them is written down and
    /// the modelling is the cheap half. Anything else stored and unread has
    /// been deleted rather than left to look like an oversight.
    public var shortcut: KeyCombo?
    public var focusFilterID: String?

    /// Decodes item by item, dropping any it cannot read.
    ///
    /// An unknown widget kind, or a shape written by a newer build, used to
    /// throw out of the array, out of the profile, and out of the whole state
    /// file: one item nobody recognised and every profile was gone. Losing one
    /// tile is a far better failure than losing the shelf, and the rest of the
    /// profile is still exactly right.
    ///
    /// Deliberately not a lenient `WidgetKind`: falling back there would turn
    /// somebody's widget into a clock, silently, and leave it looking like
    /// their configuration rather than like a loss.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        kind = try c.decode(ProfileKind.self, forKey: .kind)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Untitled"
        color = try c.decodeIfPresent(PaletteColor.self, forKey: .color) ?? .blue
        scale = try c.decodeIfPresent(Double.self, forKey: .scale) ?? Geometry.defaultScale
        shortcut = try c.decodeIfPresent(KeyCombo.self, forKey: .shortcut)
        focusFilterID = try c.decodeIfPresent(String.self, forKey: .focusFilterID)

        var unread = try c.nestedUnkeyedContainer(forKey: .items)
        var kept: [DockItem] = []
        while !unread.isAtEnd {
            // The decode has to advance the container even when it fails, or
            // one bad item is an infinite loop. Decoding into a throwaway
            // wrapper consumes the element either way.
            if let item = try? unread.decode(DockItem.self) {
                kept.append(item)
            } else {
                _ = try? unread.decode(DiscardedItem.self)
            }
        }
        items = kept
    }

    public init(id: UUID = UUID(), kind: ProfileKind, name: String,
                color: PaletteColor = .blue, items: [DockItem] = [],
                scale: Double = Geometry.defaultScale,
                shortcut: KeyCombo? = nil, focusFilterID: String? = nil) {
        self.id = id
        self.kind = kind
        self.name = name
        self.color = color
        self.items = items
        self.scale = scale
        self.shortcut = shortcut
        self.focusFilterID = focusFilterID
    }

    /// Items this profile can actually apply, given its kind.
    public var applicableItems: [DockItem] {
        kind == .macOSDock ? items.filter(\.isRepresentableInMacOSDock) : items
    }
}

// MARK: - Settings

/// What the shelf actually shows.
///
/// Pure, and here rather than inline in `AppState`, because the filter is a
/// trap: while mirroring, every app the profile holds is dropped and the real
/// Dock's are substituted. An app appended to the profile was therefore
/// filtered straight back out, and one removed from it came back on the next
/// render - both read as "the button does nothing". Editing must clear
/// `mirroring` first.
/// Whether a media reading describes something actually playing.
///
/// A page can report a title with no duration and no position, which rendered
/// as a track stuck at 0:00 under a name from nowhere - the numbers on screen
/// were a paused flag and an elapsed count that had landed in the title and
/// artist slots of a tile with nothing real behind it.
public enum MediaReading {
    public static func isMeaningful(title: String,
                                    duration: TimeInterval,
                                    elapsed: TimeInterval) -> Bool {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return duration > 0 || elapsed > 0
    }
}

/// Which of the shelf's settings the real Dock still governs.
public enum DockFollowing {
    /// The shelf's size.
    ///
    /// An explicit size overrides the Dock's, and nothing else: dragging the
    /// grip used to switch following off wholesale, which silently took the
    /// edge, magnification and auto-hide with it, so the shelf stopped hiding
    /// after a resize with nothing to connect the two.
    public static func scale(overridden: Bool, custom: Double,
                             system: Double, following: Bool) -> Double {
        if overridden { return custom }
        return following ? system : custom
    }
}

public enum ShelfItems {

    /// Drops one item onto another: into it if it is already a group, into a
    /// new group of the two otherwise.
    ///
    /// The target keeps its slot so the shelf does not reshuffle around the
    /// gesture - the two tiles become one where the target already was.
    public static func combining(_ itemID: UUID, into targetID: UUID,
                                 named name: String, in items: [DockItem]) -> [DockItem] {
        guard itemID != targetID,
              let slot = items.firstIndex(where: { $0.id == itemID }),
              let targetSlot = items.firstIndex(where: { $0.id == targetID })
        else { return items }

        var result = items
        let item = result[slot]
        if var group = result[targetSlot].group {
            group.items.append(item)
            result[targetSlot] = .group(group)
        } else {
            result[targetSlot] = .group(DockGroup(name: name,
                                                  items: [result[targetSlot], item]))
        }
        // Removed last so neither index shifts under the other.
        result.removeAll { $0.id == itemID }
        return result
    }

    /// Takes an item out of a group and puts it back on the shelf beside it,
    /// dissolving the group if that leaves it with fewer than two.
    /// - Parameter at: where the user dropped it, as a slot index. Beside the
    ///   group when unknown - a drop with no destination still has to land
    ///   somewhere predictable.
    public static func removingFromGroup(_ itemID: UUID, group groupID: UUID,
                                         in items: [DockItem],
                                         at destination: Int? = nil) -> [DockItem] {
        guard let slot = items.firstIndex(where: { $0.id == groupID }),
              var group = items[slot].group,
              let inner = group.items.firstIndex(where: { $0.id == itemID })
        else { return items }

        var result = items
        let item = group.items.remove(at: inner)
        result[slot] = .group(group)
        let landing = min(max(0, destination ?? (slot + 1)), result.count)
        result.insert(item, at: landing)
        return dissolvingSmallGroups(in: result)
    }

    /// A group needs two things in it to be a group.
    ///
    /// Left holding one it is a worse version of the icon it contains - the
    /// same tile with the artwork shrunk into a quarter of it - so it gives
    /// way to that icon rather than waiting to be tidied up.
    public static func dissolvingSmallGroups(in items: [DockItem]) -> [DockItem] {
        items.flatMap { item -> [DockItem] in
            guard let group = item.group, group.items.count < 2 else { return [item] }
            return group.items
        }
    }

    public static func displayed(profile: [DockItem],
                                 mirrored: [DockItem],
                                 mirroring: Bool) -> [DockItem] {
        // Enforced here rather than only where items leave a group, so the
        // rule holds however the data got that way - a group of one written
        // by an older build, or restored from a backup, still gives way to
        // the icon it holds instead of rendering three empty cells.
        let profile = dissolvingSmallGroups(in: profile)
        guard mirroring else { return profile }
        // Widgets first: a mirrored Dock can be long enough to push them past
        // the screen edge, where only scrolling would reach them.
        let extras = profile.filter { if case .app = $0 { false } else { true } }
        return extras + mirrored
    }
}

public struct CustomDockSettings: Codable, Hashable, Sendable {
    /// nil renders nothing - an explicit "no shelf", not an error state.
    public var profileID: UUID?
    /// Mirror the real Dock's size, edge, magnification and hiding.
    ///
    /// On by default: the user has already told macOS how they like their
    /// Dock, and the shelf's whole job is to sit beside it convincingly.
    public var followSystemDock: Bool = true
    /// Mirror the real Dock's *app list* as well as its settings.
    ///
    /// Separate from `followSystemDock` because editing the shelf must not
    /// cost the user their mirrored size, edge and hiding: adding or removing
    /// an app takes ownership of the list alone, and everything else keeps
    /// following. Optional so state saved before this flag existed still
    /// decodes - absent means "yes", which is what those profiles were doing.
    public var mirrorSystemApps: Bool?
    /// Set once the user has sized the shelf themselves.
    ///
    /// Optional so state written before it existed still decodes. Separate
    /// from `followSystemDock` because dragging the grip is an override of
    /// the *size* - it used to switch following off wholesale, which silently
    /// took the Dock's edge, magnification and auto-hide with it, so the shelf
    /// simply stopped hiding after a resize.
    public var scaleOverridden: Bool?
    public var position: DockPosition = .bottom
    public var displayID: UInt32?
    /// Live value, mirroring the active profile's scale.
    public var scale: Double = Geometry.defaultScale
    /// Liquid Glass by default: Docket requires macOS 26 anyway, and the
    /// real material is what makes the shelf sit beside the Dock convincingly.
    public var material: DockMaterial = .liquidGlass
    public var glass: GlassStyle = .regular
    public var autoHide: Bool = false
    public var showHandleWhenHidden: Bool = true
    public var useAsDesktopWidget: Bool = false
    public var hideWhenMacOSDockAppears: Bool = false
    public var showRunningApps: Bool = true
    public var showTrash: Bool = false
    /// Widgets and nothing else on the shelf.
    ///
    /// For the setup this app is usually run in: Apple's Dock keeps the apps
    /// on one edge and the shelf carries the widgets on another. Without this
    /// the shelf mirrors the Dock's apps as well, so the same icons are on
    /// screen twice and the widgets are pushed to the end of a row they are
    /// supposed to be the point of.
    ///
    /// A display filter, not an edit. Apps, folders and links stay in the
    /// profile untouched and come straight back when this is turned off, so
    /// it costs nothing to try.
    public var widgetsOnly: Bool = false
    /// On by default: a dock that does not magnify does not feel like
    /// the Dock, which is the entire reference point for this surface.
    public var magnification: Bool = true

    /// Decodes field by field, so an unknown or missing key is a default and
    /// not a thrown error.
    ///
    /// Synthesized `Codable` treats every non-optional property as required.
    /// That made adding one setting to this struct reject the user's whole
    /// state file, which `Store.load()` answers by putting the file aside and
    /// starting from a first-run default: one new key, and every profile,
    /// widget and pinned app silently gone. Decoding leniently is what makes
    /// adding a setting a safe thing to do.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        profileID = try c.decodeIfPresent(UUID.self, forKey: .profileID)
        followSystemDock = try c.decodeIfPresent(Bool.self, forKey: .followSystemDock) ?? true
        mirrorSystemApps = try c.decodeIfPresent(Bool.self, forKey: .mirrorSystemApps)
        scaleOverridden = try c.decodeIfPresent(Bool.self, forKey: .scaleOverridden)
        position = try c.decodeIfPresent(DockPosition.self, forKey: .position) ?? .bottom
        displayID = try c.decodeIfPresent(UInt32.self, forKey: .displayID)
        scale = try c.decodeIfPresent(Double.self, forKey: .scale) ?? Geometry.defaultScale
        material = try c.decodeIfPresent(DockMaterial.self, forKey: .material) ?? .liquidGlass
        glass = try c.decodeIfPresent(GlassStyle.self, forKey: .glass) ?? .regular
        autoHide = try c.decodeIfPresent(Bool.self, forKey: .autoHide) ?? false
        showHandleWhenHidden = try c.decodeIfPresent(Bool.self, forKey: .showHandleWhenHidden) ?? true
        useAsDesktopWidget = try c.decodeIfPresent(Bool.self, forKey: .useAsDesktopWidget) ?? false
        hideWhenMacOSDockAppears = try c.decodeIfPresent(Bool.self, forKey: .hideWhenMacOSDockAppears) ?? false
        showRunningApps = try c.decodeIfPresent(Bool.self, forKey: .showRunningApps) ?? true
        showTrash = try c.decodeIfPresent(Bool.self, forKey: .showTrash) ?? false
        widgetsOnly = try c.decodeIfPresent(Bool.self, forKey: .widgetsOnly) ?? false
        magnification = try c.decodeIfPresent(Bool.self, forKey: .magnification) ?? true
    }

    public init() {}
}

public struct MacOSDockSettings: Codable, Hashable, Sendable {
    /// nil means "No profile" - leave the live Dock completely alone.
    public var profileID: UUID?

    /// Decodes field by field, so an unknown or missing key is a default and
    /// not a thrown error.
    ///
    /// Synthesized `Codable` treats every non-optional property as required.
    /// That made adding one setting to this struct reject the user's whole
    /// state file, which `Store.load()` answers by putting the file aside and
    /// starting from a first-run default: one new key, and every profile,
    /// widget and pinned app silently gone. Decoding leniently is what makes
    /// adding a setting a safe thing to do.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        profileID = try c.decodeIfPresent(UUID.self, forKey: .profileID)
    }

    public init() {}
}

public struct MenuBarSettings: Codable, Hashable, Sendable {
    public var showIcon: Bool = true
    public var label: MenuBarLabelMode = .custom

    /// Decodes field by field, so an unknown or missing key is a default and
    /// not a thrown error.
    ///
    /// Synthesized `Codable` treats every non-optional property as required.
    /// That made adding one setting to this struct reject the user's whole
    /// state file, which `Store.load()` answers by putting the file aside and
    /// starting from a first-run default: one new key, and every profile,
    /// widget and pinned app silently gone. Decoding leniently is what makes
    /// adding a setting a safe thing to do.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        showIcon = try c.decodeIfPresent(Bool.self, forKey: .showIcon) ?? true
        label = try c.decodeIfPresent(MenuBarLabelMode.self, forKey: .label) ?? .custom
    }

    public init() {}
}

// MARK: - Persisted root

public struct PersistedState: Codable, Sendable {
    public static let currentVersion = 1

    public var version: Int = PersistedState.currentVersion
    public var setup: DockSetup = .both
    public var appearance: AppAppearance = .system
    public var profiles: [DockProfile] = []
    public var customDock = CustomDockSettings()
    public var macOSDock = MacOSDockSettings()
    public var menuBar = MenuBarSettings()
    /// Shared across every Focus Timer widget - the product treats it as one timer.
    public var timer = TimerState()
    /// Snapshot of the user's live Dock taken before Docket ever wrote to it.
    public var originalMacOSDock: [MacOSDockTile]?
    /// Apple's Dock preferences from before the shelf borrowed its strip.
    /// Non-nil means they are currently changed and owe a restore.
    public var borrowedDockPrefs: DockPrefs?
    /// Whether to look for new releases.
    ///
    /// Three states on purpose. Nil means the question has not been asked, and
    /// it is asked once rather than assumed: this is the only thing the app
    /// does unprompted that talks to a server, and it necessarily tells GitHub
    /// that someone ran it. Everything else that leaves the machine, weather
    /// and stock quotes, is there because the user added that widget.
    public var checkForUpdates: Bool?

    /// Decodes field by field, so an unknown or missing key is a default and
    /// not a thrown error.
    ///
    /// Synthesized `Codable` treats every non-optional property as required.
    /// That made adding one setting to this struct reject the user's whole
    /// state file, which `Store.load()` answers by putting the file aside and
    /// starting from a first-run default: one new key, and every profile,
    /// widget and pinned app silently gone. Decoding leniently is what makes
    /// adding a setting a safe thing to do.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? PersistedState.currentVersion
        setup = try c.decodeIfPresent(DockSetup.self, forKey: .setup) ?? .both
        appearance = try c.decodeIfPresent(AppAppearance.self, forKey: .appearance) ?? .system
        profiles = try c.decodeIfPresent([DockProfile].self, forKey: .profiles) ?? []
        customDock = try c.decodeIfPresent(CustomDockSettings.self, forKey: .customDock) ?? CustomDockSettings()
        macOSDock = try c.decodeIfPresent(MacOSDockSettings.self, forKey: .macOSDock) ?? MacOSDockSettings()
        menuBar = try c.decodeIfPresent(MenuBarSettings.self, forKey: .menuBar) ?? MenuBarSettings()
        timer = try c.decodeIfPresent(TimerState.self, forKey: .timer) ?? TimerState()
        originalMacOSDock = try c.decodeIfPresent([MacOSDockTile].self, forKey: .originalMacOSDock)
        borrowedDockPrefs = try c.decodeIfPresent(DockPrefs.self, forKey: .borrowedDockPrefs)
        checkForUpdates = try c.decodeIfPresent(Bool.self, forKey: .checkForUpdates)
    }

    public init() {}

    public func profile(_ id: UUID?) -> DockProfile? {
        guard let id else { return nil }
        return profiles.first { $0.id == id }
    }

    public func profiles(of kind: ProfileKind) -> [DockProfile] {
        profiles.filter { $0.kind == kind }
    }

    public var activeCustomProfile: DockProfile? { profile(customDock.profileID) }
    public var activeMacOSProfile: DockProfile? { profile(macOSDock.profileID) }
}

// MARK: - Shared timer state

public enum TimerPhase: String, Codable, Sendable, CaseIterable {
    case focus, rest, long

    public var label: String {
        switch self {
        case .focus: "Focus"
        case .rest: "Break"
        case .long: "Long break"
        }
    }
}

public struct TimerState: Codable, Hashable, Sendable {
    public var work: Int = 25          // 1...180
    public var rest: Int = 5           // 1...60
    public var longBreak: Int = 15     // 1...180
    public var sessions: Int = 4       // 1...12
    public var phase: TimerPhase = .focus
    public var completed: Int = 0
    public var color: PaletteColor = .indigo
    public var alerts: Bool = true
    public var deadline: Date?
    public var paused: TimeInterval?
    public var duration: TimeInterval?

    /// Decodes field by field, so an unknown or missing key is a default and
    /// not a thrown error.
    ///
    /// Synthesized `Codable` treats every non-optional property as required.
    /// That made adding one setting to this struct reject the user's whole
    /// state file, which `Store.load()` answers by putting the file aside and
    /// starting from a first-run default: one new key, and every profile,
    /// widget and pinned app silently gone. Decoding leniently is what makes
    /// adding a setting a safe thing to do.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        work = try c.decodeIfPresent(Int.self, forKey: .work) ?? 25
        rest = try c.decodeIfPresent(Int.self, forKey: .rest) ?? 5
        longBreak = try c.decodeIfPresent(Int.self, forKey: .longBreak) ?? 15
        sessions = try c.decodeIfPresent(Int.self, forKey: .sessions) ?? 4
        phase = try c.decodeIfPresent(TimerPhase.self, forKey: .phase) ?? .focus
        completed = try c.decodeIfPresent(Int.self, forKey: .completed) ?? 0
        color = try c.decodeIfPresent(PaletteColor.self, forKey: .color) ?? .indigo
        alerts = try c.decodeIfPresent(Bool.self, forKey: .alerts) ?? true
        deadline = try c.decodeIfPresent(Date.self, forKey: .deadline)
        paused = try c.decodeIfPresent(TimeInterval.self, forKey: .paused)
        duration = try c.decodeIfPresent(TimeInterval.self, forKey: .duration)
    }

    public init() {}

    public var minutes: Int {
        switch phase {
        case .focus: work
        case .rest: rest
        case .long: longBreak
        }
    }
}

public extension UUID {
    /// A UUID derived deterministically from a string.
    ///
    /// Transient shelf items (running-but-unpinned apps) need an identity that
    /// is stable across renders but is not persisted anywhere. Hashing the
    /// bundle identifier gives exactly that; generating a fresh UUID instead
    /// makes SwiftUI rebuild the view on every frame.
    static func stable(from string: String) -> UUID {
        var hash = SHA256Lite()
        hash.combine(string)
        return hash.uuid
    }
}

/// Small, dependency-free digest. Not cryptographic - it only needs to spread
/// bundle identifiers across the UUID space without colliding.
private struct SHA256Lite {
    private var a: UInt64 = 0x243F6A8885A308D3
    private var b: UInt64 = 0x13198A2E03707344

    mutating func combine(_ string: String) {
        for byte in string.utf8 {
            a = (a ^ UInt64(byte)) &* 0x100000001B3
            b = (b &+ UInt64(byte)) &* 0x9E3779B97F4A7C15
            b ^= b >> 29
        }
    }

    var uuid: UUID {
        var bytes = [UInt8]()
        withUnsafeBytes(of: a.bigEndian) { bytes.append(contentsOf: $0) }
        withUnsafeBytes(of: b.bigEndian) { bytes.append(contentsOf: $0) }
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5],
                           bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11],
                           bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}

/// Applies a displayed ordering back onto a stored list.
public enum Reorder {

    /// Reorders `items` to match `displayed`, by identity.
    ///
    /// Index-based reordering is wrong here: while the shelf mirrors the
    /// macOS Dock it shows the profile's own items *plus* the Dock's apps, so
    /// a position on screen has no relationship to a position in the stored
    /// array. Ids that the shelf was not showing keep their place rather than
    /// being dropped - losing a user's pinned item to a drag would be far
    /// worse than an imperfect order.
    public static func apply(order displayed: [UUID], to items: [DockItem]) -> [DockItem] {
        var remaining = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var result: [DockItem] = []
        result.reserveCapacity(items.count)
        for id in displayed {
            if let item = remaining.removeValue(forKey: id) { result.append(item) }
        }
        result.append(contentsOf: items.filter { remaining[$0.id] != nil })
        return result
    }
}

// MARK: - Choices that tolerate a value they do not know

// Each fallback is the same value the property defaults to, so an unreadable
// setting behaves exactly as one that was never written.
extension DockSetup: LenientChoice { public static var fallback: Self { .both } }
extension DockPosition: LenientChoice { public static var fallback: Self { .bottom } }
extension AppAppearance: LenientChoice { public static var fallback: Self { .system } }
extension DockMaterial: LenientChoice { public static var fallback: Self { .liquidGlass } }
extension GlassStyle: LenientChoice { public static var fallback: Self { .regular } }
extension MenuBarLabelMode: LenientChoice { public static var fallback: Self { .custom } }
extension SpacerSize: LenientChoice { public static var fallback: Self { .regular } }
extension PaletteColor: LenientChoice { public static var fallback: Self { .blue } }
extension PaperColor: LenientChoice { public static var fallback: Self { .yellow } }
extension TimerPhase: LenientChoice { public static var fallback: Self { .focus } }

// ProfileKind is deliberately absent. A profile that decoded as the wrong kind
// would be applied to the wrong surface, writing a shelf layout into Apple's
// Dock. Losing the profile is the better failure, and it is one profile rather
// than the file.
