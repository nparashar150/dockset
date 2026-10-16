import SwiftUI

/// Everything a widget view needs that isn't its own config.
///
/// Widgets are authored at their **natural** size (the points in the catalog)
/// and the shelf applies `scaleEffect` to the finished tile. That is why there
/// is no scale in here: a widget that did its own font maths would drift out
/// of step with its neighbours the moment the size slider moved.
public struct WidgetContext: Equatable, Sendable {
    public var position: DockPosition
    /// Ticks once a second; widgets that show time read this rather than
    /// starting timers of their own.
    public var now: Date
    /// True while the widget is shown in the library, where live data sources
    /// should be replaced with representative sample values.
    public var isPreview: Bool

    public init(position: DockPosition = .bottom, now: Date = .now, isPreview: Bool = false) {
        self.position = position
        self.now = now
        self.isPreview = isPreview
    }
}

/// Shared look for every widget tile.
public enum WidgetStyle {
    /// About 0.3 of a card's height, which is what the reference shelf runs
    /// and what macOS 26's own grouped surfaces look like. 14 read as square
    /// beside them.
    public static let corner: CGFloat = 18
    public static let inset: CGFloat = 10

    /// Enough black over any artwork to keep white ink legible on it.
    ///
    /// Derived rather than chosen. The worst case is a white cover, where a
    /// scrim of `a` leaves a composite of `1 - a`, and white label ink at its
    /// own 0.847 alpha needs that composite at or below about 0.42 to clear
    /// 4.5:1. 0.60 lands at 4.67:1 against pure white and better against
    /// everything else, and leaves 40% of the cover showing, which is enough
    /// for it to read as the record it is.
    ///
    /// The cover is therefore always a dark surface, whatever the appearance,
    /// which is why the tile pins its ink white alongside this rather than
    /// letting it follow the system.
    public static let artworkScrim = 0.60

    /// The large figure - times, percentages, amounts.
    public static func value(_ size: CGFloat = 26) -> Font {
        .system(size: size, weight: .bold)
    }

    /// The small caption under or beside a value.
    public static func caption(_ size: CGFloat = 12) -> Font {
        .system(size: size, weight: .regular)
    }

    public static func label(_ size: CGFloat = 12) -> Font {
        .system(size: size, weight: .semibold)
    }

    /// Digits that change every second must not make the layout shimmer.
    public static var monospacedDigits: Font.Design { .default }

    /// The system's own, unmodified.
    ///
    /// Every macOS text token is a pure white or a pure black varying only in
    /// alpha, read from AppKit on macOS 26: label 0.847 in both appearances,
    /// secondary 0.549 dark and 0.498 light, tertiary 0.247 and 0.259,
    /// quaternary 0.098. That is the mechanism of vibrancy rather than an
    /// implementation detail, and it is why they work on a plate that samples
    /// the desktop: the text takes up what is behind it instead of sitting on
    /// top of it opaquely.
    ///
    /// `secondary` used to carry `.opacity(0.85)` on top of that, which took
    /// an already-translucent token to an effective 0.467 dark and 0.423
    /// light. That is below every level the system defines, and measured over
    /// this app's own plates it cost 4.68:1 against 5.95:1 in the dark and
    /// 3.02:1 against 3.86:1 in the light.
    ///
    /// The system ships four levels precisely so that nothing has to invent a
    /// fifth by multiplying one. Where something wants to sit back further
    /// than secondary the answer is `tertiaryLabelColor`, which is a level
    /// rather than a fraction.
    ///
    /// Worth knowing and not worth fighting: secondary over a light plate
    /// reaches 3.86:1, short of WCAG's 4.5:1 for body text. That is macOS's
    /// own figure for supporting text, so matching it is the point. Anything
    /// that must be read at any cost should be `primary`, not a secondary
    /// pushed opaque until it passes.
    public static let primary = Color.primary
    public static let secondary = Color.secondary

    public static func tint(_ color: PaletteColor) -> Color { Color(hex: color.hex) }
    public static func paper(_ color: PaperColor) -> Color { Color(hex: color.hex) }
}

public extension Color {
    /// What panels write and draw with: white on the dark card, near-black on
    /// the light one. Resolved against the view's own colour scheme, so a
    /// panel kept dark on purpose still gets white from the same token.
    ///
    /// Used at an opacity for everything that is not text - a pane at 0.09,
    /// a hairline at 0.1 - which is what lets one token serve both schemes:
    /// black at 9% on light is the same quiet step as white at 9% on dark.
    static let panelInk = Color(nsColor: NSColor(name: "panelInk") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? .white
            : NSColor(white: 0.11, alpha: 1)
    })

    /// `#RRGGBB` / `#RRGGBBAA`. Falls back to clear rather than trapping - a
    /// bad swatch should not take the shelf down.
    init(hex: String) {
        let raw = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard let value = UInt64(raw, radix: 16), raw.count == 6 || raw.count == 8 else {
            self = .clear
            return
        }
        let hasAlpha = raw.count == 8
        let r = Double((value >> (hasAlpha ? 24 : 16)) & 0xFF) / 255
        let g = Double((value >> (hasAlpha ? 16 : 8)) & 0xFF) / 255
        let b = Double((value >> (hasAlpha ? 8 : 0)) & 0xFF) / 255
        let a = hasAlpha ? Double(value & 0xFF) / 255 : 1
        self = Color(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
}

/// The surface every widget draws on.
public struct WidgetSurface<Content: View>: View {
    public var fill: Color?
    /// A picture behind the card instead of a colour.
    ///
    /// Only Now Playing uses it, and it is here rather than drawn by that
    /// tile so a card with a cover behind it is still a card: same corner,
    /// same edge, same lift under the pointer.
    public var image: NSImage?
    @ViewBuilder public var content: Content

    @Environment(\.colorScheme) private var scheme
    @Environment(\.widgetHovered) private var hovered

    /// A card is a *recess* in the plate, not something raised on top of it.
    ///
    /// `Color.primary` is white in the dark, so tinting with it lightened the
    /// card toward the shelf until the two matched exactly - measured at 40
    /// against a plate of 40, which is why the cards did not read as cards.
    /// Dockset holds a card at roughly 0.85x the plate's luminance; a black
    /// tint reproduces that ratio against any backdrop the glass samples.
    private var cardFill: Color {
        // In the dark the card's job is to be darker than a plate whose
        // brightness belongs to the wallpaper rather than to the appearance.
        // 0.16 is right over a dark desktop and nowhere near enough over a
        // white one, where white ink on a card measures 1.37:1. See
        // `DesktopLuminance.cardAlpha`, which returns exactly 0.16 whenever
        // the desktop is dark, so the common case is untouched.
        scheme == .dark
            ? .black.opacity(DesktopLuminance.shared.cardAlpha)
            : .white.opacity(0.40)
    }

    /// Just enough to catch the edge; the fill does the work.
    private var cardEdge: Color {
        scheme == .dark ? .white.opacity(0.07) : .black.opacity(0.06)
    }


    public init(fill: Color? = nil, image: NSImage? = nil,
                @ViewBuilder content: () -> Content) {
        self.fill = fill
        self.image = image
        self.content = content()
    }

    public var body: some View {
        content
            .padding(.horizontal, WidgetStyle.inset)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                RoundedRectangle(cornerRadius: WidgetStyle.corner, style: .continuous)
                    .fill(fill ?? cardFill)
                    .overlay {
                        if let image {
                            Image(nsImage: image)
                                .resizable()
                                // Filled and clipped: a cover is square and a
                                // video thumbnail is not, and a card is
                                // neither. Letterboxing a background would
                                // draw bars inside the card.
                                .aspectRatio(contentMode: .fill)
                                .overlay(Color.black.opacity(WidgetStyle.artworkScrim))
                                .clipShape(RoundedRectangle(cornerRadius: WidgetStyle.corner,
                                                            style: .continuous))
                        }
                    }
                    // Lifted a little out of the recess under the pointer.
                    .overlay {
                        RoundedRectangle(cornerRadius: WidgetStyle.corner, style: .continuous)
                            .fill(.white.opacity(hovered ? (scheme == .dark ? 0.07 : 0.22) : 0))
                    }
            }
            .overlay {
                RoundedRectangle(cornerRadius: WidgetStyle.corner, style: .continuous)
                    .strokeBorder(hovered ? hoverEdge : cardEdge, lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: WidgetStyle.corner, style: .continuous))
            // A transform rather than a layout change, and small.
            //
            // Widgets deliberately do not magnify: a 264pt card swelling the
            // 30% an icon does would displace a quarter of the shelf, so
            // brushing past one would shove every icon aside. But answering
            // nothing at all is what made them feel dead beside the icons.
            // scaleEffect draws bigger without asking for more room, and 2%
            // stays inside the gap between cards.
            .scaleEffect(hovered ? 1.02 : 1)
            .animation(.smooth(duration: 0.16), value: hovered)
    }

    /// The edge catches the light too, or the card reads as merely paler.
    private var hoverEdge: Color {
        scheme == .dark ? .white.opacity(0.16) : .black.opacity(0.12)
    }
}

/// Whether the pointer is over this widget.
///
/// Through the environment rather than `WidgetContext` so that every widget
/// gains the highlight without being edited, and because `WidgetSurface` is
/// the one place that draws a card: putting it there means one definition of
/// what hover looks like instead of twenty.
///
/// Not `.onHover`, which never fires in a non-activating accessory panel.
/// The shelf already tracks the pointer for magnification and already
/// hit-tests it to place a tooltip; this rides on the same answer.
public struct WidgetHoveredKey: EnvironmentKey {
    public static let defaultValue = false
}

public extension EnvironmentValues {
    var widgetHovered: Bool {
        get { self[WidgetHoveredKey.self] }
        set { self[WidgetHoveredKey.self] = newValue }
    }
}

public extension View {
    /// Rolls a changing number instead of hard-cutting it.
    ///
    /// Every widget on the shelf redraws its value on a tick - clock digits,
    /// battery percentage, CPU and memory, prices - and each one swapped its
    /// text instantly, which is what made the widgets look inert next to the
    /// rest of the shelf. `numericText` is Apple's own transition for exactly
    /// this, and it is the difference between a readout and a live one.
    func rollingValue(_ value: some Equatable) -> some View {
        contentTransition(.numericText())
            .animation(.snappy(duration: 0.28), value: value)
    }
}

/// How a widget writes its own state back.
///
/// `WidgetContext` is `Equatable` and `Sendable` so tiles can be diffed
/// cheaply, which rules out carrying a closure. This is the channel instead:
/// the app wires it once at launch, widgets call it, and the change lands in
/// the profile and is persisted like any other edit.
///
/// Without it a widget can only ever be a readout - which is what every tile
/// but Now Playing was. A stopwatch you cannot start is a picture of one.
@MainActor
public enum WidgetWriter {
    public static var update: (WidgetInstance) -> Void = { _ in }

    /// Applies a change to one widget's config.
    public static func write(_ instance: WidgetInstance,
                             _ change: (inout WidgetConfig) -> Void) {
        var updated = instance
        change(&updated.config)
        update(updated)
    }
}
