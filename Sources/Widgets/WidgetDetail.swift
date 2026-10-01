import AppKit
import SwiftUI

/// A widget's detail panel: what opens when its tile is clicked.
///
/// This is the shape the reference shelf takes and the one thing the tiles
/// were missing. A tile is a glance - a temperature, a percentage, a title -
/// and the panel is where the same widget says everything it knows: the whole
/// day's events rather than the next one, every battery rather than the Mac's,
/// a chart behind the number.
///
/// Its own window for the same reason the hover label and an opened group have
/// theirs: drawing it inside the shelf would mean reserving space for the
/// largest panel any widget might want.
@MainActor
final class WidgetDetailWindow {
    static let shared = WidgetDetailWindow()

    /// Which widget is showing, so clicking its tile again closes it.
    private(set) var openWidgetID: UUID?

    private var panel: KeyablePanel?
    private var hosting: FirstMouseHostingView<WidgetDetailChrome>?
    /// Watches for the click that dismisses it - one monitor for clicks
    /// landing in another app, one for clicks landing in this one.
    private var monitors: [Any] = []
    /// The shelf's own frame, which the dismissal watcher ignores.
    ///
    /// The shelf already decides what a click on it means - the same tile
    /// toggles this shut, another widget swaps it, an app tile closes it. A
    /// monitor closing it first would let the tile's own tap reopen it on the
    /// very same press.
    private var host: CGRect = .zero
    /// Changes on every open, to replay the entrance.
    private var session = UUID()
    /// What the open panel was shown with, so a config change underneath it
    /// can be redrawn without reopening it.
    private var shown: (context: WidgetContext, edge: DockPosition,
                        arrowOffset: CGFloat)?

    private init() {}

    var isOpen: Bool { openWidgetID != nil && panel?.isVisible == true }

    func toggle(_ instance: WidgetInstance, context: WidgetContext,
                anchor: CGPoint, edge: DockPosition, host: CGRect) {
        if openWidgetID == instance.id { return close() }
        show(instance, context: context, anchor: anchor, edge: edge, host: host)
    }

    /// Redraws the open panel after its widget's config changed.
    ///
    /// The panel is handed a `WidgetInstance` by value, so a tile that edits
    /// its own config - the stocks chevron stepping to the next symbol, a
    /// setting changed while the panel is up - left the two disagreeing until
    /// it was closed and reopened. Every widget write funnels through
    /// `WidgetWriter`, which is where this is called from.
    ///
    /// Deliberately keeps `session`, so the entrance does not replay, and the
    /// frame, so the panel does not jump: the width is fixed per kind, and a
    /// config change that made the panel *taller* would keep the old height
    /// until reopened.
    func refresh(_ instance: WidgetInstance) {
        guard openWidgetID == instance.id, let shown else { return }
        hosting?.rootView = WidgetDetailChrome(
            instance: instance, context: shown.context, edge: shown.edge,
            session: session, arrowOffset: shown.arrowOffset)
    }

    /// Closes on the next click outside the panel and its own tile.
    ///
    /// The panel used to close when the *pointer* left it, on a half-second
    /// timer - which is why it needed a close button: a panel that vanishes
    /// because you looked away is one you cannot trust to stay. Nothing on
    /// this platform behaves that way. A popover waits for a click.
    private func watchForDismissal() {
        stopWatching()
        let dismiss: (NSEvent) -> Void = { [weak self] event in
            guard let self, let panel = self.panel else { return }
            // A local event reports a window-relative location; a global one
            // is already on screen.
            let point = event.window?.convertPoint(toScreen: event.locationInWindow)
                ?? NSEvent.mouseLocation
            guard !panel.frame.contains(point),
                  !self.host.contains(point) else { return }
            self.close()
        }
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: dismiss) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { event in
            dismiss(event)
            return event
        }) { monitors.append(local) }
    }

    private func stopWatching() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
    }

    func close() {
        guard openWidgetID != nil else { return }
        openWidgetID = nil
        shown = nil
        stopWatching()
        guard panel?.isVisible == true else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel?.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.openWidgetID == nil else { return }
                self.panel?.orderOut(nil)
                self.panel?.alphaValue = 1
            }
        }
    }

    private func show(_ instance: WidgetInstance, context: WidgetContext,
                      anchor: CGPoint, edge: DockPosition, host: CGRect) {
        let panel = existingOrNew()
        session = UUID()
        shown = (context, edge, 0)
        self.host = host
        hosting?.rootView = WidgetDetailChrome(
            instance: instance, context: context, edge: edge, session: session)

        let size = hosting?.fittingSize ?? .zero
        // Claimed only once there is something to show. Setting it above the
        // guard meant a bail here left the widget marked open with no window,
        // and `toggle` would then answer every later click by closing a panel
        // that was never up.
        guard size.width > 1, size.height > 1 else { return }
        openWidgetID = instance.id

        // Almost touching the tile: the panel's own padding already includes
        // the tail's depth, so this is the gap between the tail's tip and the
        // tile, not between the tile and the body.
        let gap: CGFloat = 2
        let origin: CGPoint = switch edge {
        case .bottom: CGPoint(x: anchor.x - size.width / 2, y: anchor.y + gap)
        case .left: CGPoint(x: anchor.x + gap, y: anchor.y - size.height / 2)
        case .right: CGPoint(x: anchor.x - size.width - gap, y: anchor.y - size.height / 2)
        }
        let placed = clamped(origin, size: size)

        // Only now is the tail's offset knowable: clamping against the end of
        // the screen moves the panel but not the tile, and a tail still
        // pointing at the panel's own middle would point at nothing. Assigning
        // the root view twice is cheap and cannot change the measured size -
        // the offset moves the tail within the outline, not the frame.
        let offset: CGFloat = switch edge {
        case .bottom: anchor.x - (placed.x + size.width / 2)
        // Screen y counts up and the panel's own coordinates count down, so
        // the sign flips on a side shelf.
        case .left, .right: (placed.y + size.height / 2) - anchor.y
        }
        shown = (context, edge, offset)
        hosting?.rootView = WidgetDetailChrome(
            instance: instance, context: context, edge: edge, session: session,
            arrowOffset: offset)

        panel.setFrame(CGRect(origin: placed, size: size), display: false)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        // A panel carrying a text field or a slider needs the keyboard, and a
        // borderless window is refused key status without the override.
        panel.makeKey()
        watchForDismissal()
    }

    private func clamped(_ origin: CGPoint, size: NSSize) -> CGPoint {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(origin) })
                ?? NSScreen.main else { return origin }
        let visible = screen.visibleFrame
        return CGPoint(
            x: min(max(origin.x, visible.minX + 8), max(visible.minX, visible.maxX - size.width - 8)),
            y: min(max(origin.y, visible.minY + 8), max(visible.minY, visible.maxY - size.height - 8))
        )
    }

    private func existingOrNew() -> NSPanel {
        if let panel { return panel }
        let hosting = FirstMouseHostingView(
            rootView: WidgetDetailChrome(instance: WidgetInstance(kind: .clock,
                                                                  config: WidgetConfig()),
                                         context: WidgetContext(),
                                         edge: .bottom, session: session))
        hosting.sizingOptions = [.intrinsicContentSize]

        let panel = KeyablePanel(contentRect: .zero,
                                 styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered, defer: false)
        panel.onCancel = { [weak self] in self?.close() }
        panel.contentView = hosting
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary,
                                    .fullScreenAuxiliary, .ignoresCycle]
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) + 2)

        self.panel = panel
        self.hosting = hosting
        return panel
    }
}

/// What every detail panel is wrapped in: the surface, its outline, and the
/// tail pointing back at the tile.
///
/// There is no header at all. It carried the widget's name, a settings button
/// and a close button, and each has somewhere better to be - the tail says
/// which tile this belongs to, settings are in that tile's context menu, and
/// it closes on a click outside, on Escape or on Command-W. A close button is
/// what you add when you do not trust the dismissal, and it was the first
/// thing that made this read as a web dialog rather than a Mac window.
struct WidgetDetailChrome: View {
    var instance: WidgetInstance
    var context: WidgetContext
    var edge: DockPosition
    /// Identifies one opening, so the entrance replays each time.
    var session: UUID
    /// How far the tile's centre is from the panel's along the shelf. Zero
    /// until the panel is clamped against the end of the screen, after which
    /// the tail has to reach back toward the tile.
    var arrowOffset: CGFloat = 0

    @Environment(\.colorScheme) private var scheme
    @State private var appeared = false

    var body: some View {
        WidgetDetailBody(instance: instance, context: context)
            .padding(16)
            // Room for the tail on whichever side the shelf is.
            .padding(tailSide, PanelShape.arrowDepth)
            .frame(width: WidgetDetail.width(instance.kind), alignment: .leading)
            .background(surface(WidgetDetailBody.ground(instance, context)))
            .fixedSize()
            // Rises a little and fades in. It used to scale up out of the
            // tile, which is an iOS sheet's entrance; a panel on this
            // platform arrives more or less where it means to stay.
            .offset(x: rise.width, y: rise.height)
            .opacity(appeared ? 1 : 0)
            .onAppear { enter() }
            .onChange(of: session) { _, _ in
                appeared = false
                Task { @MainActor in enter() }
            }
    }

    /// Which side the tail sits on, which is the side facing the shelf.
    private var tailSide: Edge.Set {
        switch edge {
        case .bottom: .bottom
        case .left: .leading
        case .right: .trailing
        }
    }

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    private var outline: PanelShape {
        PanelShape(edge: edge, arrowOffset: arrowOffset)
    }

    /// The material AppKit gives a popover, not a guess at one.
    ///
    /// This has been wrong twice. First `.regularMaterial` with the widget's
    /// accent flooded over the whole surface, which reads as a web card and
    /// defeats vibrancy - the thing that makes native text sit *in* a surface
    /// rather than on it. Then an opaque window background, which fixed the
    /// stain and lost the vibrancy with it. `.popover` is documented as
    /// exactly this material, and a real popover's layer tree carries no tint
    /// at all, so neither does this.
    private func surface(_ ground: ArtworkTint?) -> some View {
        VisualEffectPlate(material: .popover, blending: .behindWindow)
            // Inside the clip rather than behind the plate. As a
            // `.background` on the body it would paint the whole window
            // rect, which is wider than the panel by the tail's depth, and
            // leave a square-cornered strip across the shelf-facing edge
            // that the panel's shadow traces.
            .overlay {
                if let ground {
                    LinearGradient(colors: [Self.colour(ground.top), Self.colour(ground.bottom)],
                                   startPoint: .top, endPoint: .bottom)
                }
            }
            // Opaque where there is a ground, because a translucent tint over
            // a sampled desktop is how the accent stain happened twice
            // before: the colour underneath is somebody's wallpaper and the
            // result is unpredictable. Where there is no ground this is
            // untouched and vibrancy still does its work.
            //
            // Reduce Transparency and Increase Contrast take the same door,
            // which closes a gap every one of these panels had: the chrome
            // never read either setting.
            .overlay {
                if ground == nil, reduceTransparency || contrast == .increased {
                    Rectangle().fill(scheme == .dark ? Color(white: 0.11) : Color(white: 0.95))
                }
            }
            .clipShape(outline)
            .overlay {
                // A hairline at the edge, not a drawn border. White over a
                // ground: a dark hairline on a dark colour disappears.
                outline.stroke(ground == nil
                               ? Color.primary.opacity(scheme == .dark ? 0.16 : 0.10)
                               : Color.white.opacity(0.14),
                               lineWidth: 0.5)
            }
    }

    /// `ArtworkTint` stays free of SwiftUI so the core can hold it, so the
    /// conversion lives at the only place that needs it.
    private static func colour(_ c: (red: Double, green: Double, blue: Double)) -> Color {
        Color(.sRGB, red: c.red, green: c.green, blue: c.blue, opacity: 1)
    }

    /// Three points, away from the shelf, so it settles toward the tile.
    private var rise: CGSize {
        guard !appeared else { return .zero }
        return switch edge {
        case .bottom: CGSize(width: 0, height: 3)
        case .left: CGSize(width: -3, height: 0)
        case .right: CGSize(width: 3, height: 0)
        }
    }

    private func enter() {
        withAnimation(.easeOut(duration: 0.14)) { appeared = true }
    }
}

/// How wide each kind's panel is.
///
/// Per kind rather than one width for all: a battery panel is a list of four
/// rows, a revenue panel carries a chart, and a sticky note is a square of
/// paper. Forcing them to a common width leaves most of them padded out.
enum WidgetDetail {
    /// Whether this kind has more to say than its tile already shows.
    ///
    /// Kinds without a panel keep opening their app instead. A panel that
    /// only restates the tile, or apologises for having nothing, is worse
    /// than the app the widget is about.
    static func exists(for kind: WidgetKind) -> Bool {
        switch kind {
        // Everything with a tile and something to say. `.aiUsage` is the
        // only kind left out, and it is a stub - no tile, no service,
        // nothing a panel could honestly show.
        case .aiUsage:
            false
        default:
            true
        }
    }

    static func width(_ kind: WidgetKind) -> CGFloat {
        switch kind {
        // Wide enough for a table or a line of code without wrapping it.
        case .ask: 360
        case .stripe, .paddle, .shopify: 340
        case .calendar, .reminders: 320
        // Set by the twelve-column strip of the next hours there.
        case .world: 320
        // A big time, a date and two rows: 300 left a gutter wide enough to
        // read as padding.
        case .clock: 280
        case .battery: 330
        case .notes: 300
        case .system, .network: 340
        // Wide enough for the whole hourly series as a strip; the tile fits
        // five of those hours and the service publishes twelve.
        case .weather: 340
        case .music: 330
        default: 300
        }
    }
}

/// The panel's outline: a rounded rectangle with a tail pointing at the tile
/// that opened it.
///
/// The tail is the thing that was missing. Apple's positioning rules for a
/// popover are written entirely in terms of it, and without one the panel is
/// a rectangle that happens to be near a tile rather than something belonging
/// to it. Measured off a real `NSPopover`: a 20pt continuous corner, and a
/// tail roughly 26pt across and 10pt deep.
struct PanelShape: Shape {
    /// Which edge the shelf is on; the tail goes on the side facing it.
    var edge: DockPosition
    /// Distance along the shelf from the panel's middle to the tile's, which
    /// is zero until the panel is clamped against the end of the screen.
    var arrowOffset: CGFloat

    static let radius: CGFloat = 20
    static let arrowBase: CGFloat = 26
    static let arrowDepth: CGFloat = 10

    func path(in rect: CGRect) -> Path {
        let depth = Self.arrowDepth
        var body = rect
        switch edge {
        case .bottom: body.size.height -= depth
        case .left: body.origin.x += depth; body.size.width -= depth
        case .right: body.size.width -= depth
        }

        let outline = Path(roundedRect: body, cornerRadius: Self.radius, style: .continuous)

        // Kept clear of the corners: a tail growing out of the curve reads as
        // a dent in the outline rather than a point at anything.
        let half = Self.arrowBase / 2
        let limit = Self.radius + half
        // The tail starts a little inside the body so the two overlap, and
        // is then merged into it. It used to be a second shape added beside
        // the rounded rectangle, so the hairline traced both: a line straight
        // across the tail's base, and the tail's sides drawn over the body's
        // edge where they met. One outline has neither.
        let overlap: CGFloat = 2
        var tail = Path()
        switch edge {
        case .bottom:
            let x = min(max(body.minX + limit, body.midX + arrowOffset), body.maxX - limit)
            tail.move(to: CGPoint(x: x - half, y: body.maxY - overlap))
            tail.addLine(to: CGPoint(x: x - 2.5, y: rect.maxY - 1.4))
            // A softened point, the way a popover's tail ends.
            tail.addQuadCurve(to: CGPoint(x: x + 2.5, y: rect.maxY - 1.4),
                              control: CGPoint(x: x, y: rect.maxY + 0.4))
            tail.addLine(to: CGPoint(x: x + half, y: body.maxY - overlap))
        case .left:
            let y = min(max(body.minY + limit, body.midY + arrowOffset), body.maxY - limit)
            tail.move(to: CGPoint(x: body.minX + overlap, y: y - half))
            tail.addLine(to: CGPoint(x: rect.minX + 1.4, y: y - 2.5))
            tail.addQuadCurve(to: CGPoint(x: rect.minX + 1.4, y: y + 2.5),
                              control: CGPoint(x: rect.minX - 0.4, y: y))
            tail.addLine(to: CGPoint(x: body.minX + overlap, y: y + half))
        case .right:
            let y = min(max(body.minY + limit, body.midY + arrowOffset), body.maxY - limit)
            tail.move(to: CGPoint(x: body.maxX - overlap, y: y - half))
            tail.addLine(to: CGPoint(x: rect.maxX - 1.4, y: y - 2.5))
            tail.addQuadCurve(to: CGPoint(x: rect.maxX - 1.4, y: y + 2.5),
                              control: CGPoint(x: rect.maxX + 0.4, y: y))
            tail.addLine(to: CGPoint(x: body.maxX - overlap, y: y + half))
        }
        tail.closeSubpath()
        return outline.union(tail)
    }
}
