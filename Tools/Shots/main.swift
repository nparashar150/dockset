import AppKit
import SwiftUI

// Renders the app's real views into real, on-screen windows and prints where
// each one landed, so `scripts/capture-shots.sh` can photograph the screen
// region it occupies. Two kinds of image: every detail panel worth showing,
// and the shelf itself, which is the product.
//
// Why a window on a real display, rather than `ImageRenderer` or
// `cacheDisplay`: a panel's surface is `VisualEffectPlate(material: .popover,
// blending: .behindWindow)` and the shelf's is macOS 26 glass, and both are
// sampled by the window server from what is genuinely composited behind the
// window. Nothing is behind an offscreen bitmap, so an offscreen render comes
// back as a transparent - or, once flattened, black - slab with the text
// floating on it. The material is most of what these surfaces look like, so
// the only honest render is one the display has actually drawn.
//
// The images are documentation, and documentation that overstates the app is
// worse than none. Every view here is the shipping view, handed either live
// readings from this machine or its own `isPreview` sample data - the same
// values the widget library shows - and each shot says on its own line which
// of the two it is, so nothing downstream has to guess. Nothing is mocked up,
// and no number is typed in here to flatter a screenshot.

// MARK: - Protocol with the capture script
//
// One line per shot on stdout - `name x y width height source` - then a
// blocking read of stdin, which the script answers once `screencapture` has
// returned. A handshake rather than a sleep because a fixed wait is either too
// short on a busy machine or wasted on an idle one, and a truncated capture is
// silent.

private func emit(_ line: String) {
    print(line)
    // stdout is a pipe here, so it is block-buffered: without this the script
    // waits for a line that is still sitting in the buffer, and the script's
    // acknowledgement never comes. Deadlock.
    fflush(stdout)
}

private func log(_ message: String) {
    FileHandle.standardError.write(Data("shots: \(message)\n".utf8))
}

/// `screencapture -R` measures from the top-left of the primary display and
/// counts downward; AppKit's screen coordinates start at that display's
/// bottom-left and count upward. Both describe the same global space, so the
/// flip is against the *primary* screen's full frame - not the visible frame,
/// which excludes the menu bar, and not the frame of whichever screen the
/// window happens to be on.
private func topLeftRect(_ rect: CGRect) -> CGRect {
    let primary = NSScreen.screens.first?.frame ?? .zero
    return CGRect(x: rect.minX, y: primary.maxY - rect.maxY,
                  width: rect.width, height: rect.height)
}

/// What the numbers in an image actually are.
///
/// Carried out to the script and printed beside every file, because the one
/// thing a screenshot cannot say about itself is whether it is real. A panel
/// captured on `sample` has to be labelled wherever the image is used.
private enum Source: String {
    /// Live readings from this machine, this network, or this clock.
    case live
    /// The widget's own sample values, as the library draws them.
    case sample
    /// The panel's honest "nothing is connected" state.
    case empty
}

// MARK: - The shots

@MainActor
private struct Shot {
    var name: String
    var instance: WidgetInstance
    var isPreview: Bool
    var source: Source
    /// Run before the window is built, for a panel whose data lives outside
    /// its config: a service to point at a city, a fetch to wait out.
    var prepare: @MainActor () async -> Void = {}
}

/// - Parameter since: when this run began. The stopwatch and the countdown are
///   anchored to it rather than to a figure typed in here, so both have
///   genuinely been running for as long as the image says they have.
@MainActor
private func shots(since started: Date) -> [Shot] {
    [
        // Live. MET Norway needs no key and no consent, so the one thing
        // standing between this tool and a real forecast is a city - and the
        // config carries one. Offline, the panel says "No reading yet", which
        // is the truth about a machine with no network.
        Shot(name: "weather",
             instance: widget(.weather, ["city": .string("Oslo")]),
             isPreview: false, source: .live,
             prepare: { await WeatherService.shared.setLocation(city: "Oslo") }),

        // Live: this machine's own clock, zone and date.
        Shot(name: "clock", instance: widget(.clock), isPreview: false, source: .live),

        // Sample: the panel's own finished answer. A live one would need an
        // API key, and would picture whatever was last asked.
        Shot(name: "ask", instance: widget(.ask), isPreview: true, source: .sample),

        // Live: the zone's own rules do this arithmetic, so the strip is the
        // real overlap between here and Tokyo at the moment of capture.
        Shot(name: "world-clock",
             instance: widget(.world, ["zone": .string("Asia/Tokyo"),
                                       "city": .string("Tokyo")]),
             isPreview: false, source: .live),

        // Live: the calendar and nothing else, so the three bars are exactly
        // how far through the day, month and year the capture happened.
        Shot(name: "time-progress", instance: widget(.progress),
             isPreview: false, source: .live),

        // Live. No drink has been logged, so the panel says so rather than
        // dressing its cycle anchor up as one - which is the state a widget
        // added a minute ago is genuinely in.
        Shot(name: "hydration", instance: widget(.hydration),
             isPreview: false, source: .live),

        // The catalog's own default alarm, with the countdown to it computed
        // against the real clock.
        Shot(name: "alarm", instance: widget(.alarm), isPreview: false, source: .live),

        // Live quotes, fetched here because the panel deliberately does not
        // fetch: it renders whatever the tile's service has already cached,
        // and in this tool there is no tile. One prepare covers the watchlist
        // below as well, since the two share the service's cache.
        Shot(name: "stock",
             instance: widget(.stock), isPreview: false, source: .live,
             prepare: {
                 StockService.shared.track(["AAPL", "MSFT", "NVDA"])
                 await StockService.shared.refresh()
             }),

        Shot(name: "watchlist", instance: widget(.watchlist),
             isPreview: false, source: .live),

        // The one empty state worth a picture. This build ships no Stripe,
        // Paddle or Shopify client, and the panel's whole design is about
        // refusing to draw a plausible amount under a real account name - so
        // this is the app being honest, not the app failing. The account is
        // left unnamed so even the label is something the code produced.
        Shot(name: "stripe", instance: widget(.stripe), isPreview: false, source: .empty),

        // Live: `sharingd`'s own discoverability setting, read straight from
        // its preferences. Whatever this Mac is actually set to is what the
        // image will show.
        Shot(name: "airdrop", instance: widget(.airdrop), isPreview: false, source: .live),

        // The note's own words, which are the widget's content rather than a
        // reading of anything.
        Shot(name: "sticky-note",
             instance: widget(.notes, ["text": .string("Renew the domain")]),
             isPreview: false, source: .live),

        // Sample data. A live read would list this machine's own accessories,
        // which is both less illustrative and more personal than it looks -
        // and a Mac with no battery would leave the panel with nothing to say
        // at all.
        Shot(name: "battery", instance: widget(.battery), isPreview: true, source: .sample),

        // Sample data - the same deterministic traffic the library draws. The
        // sampler works and the panel would happily show it, but an unattended
        // capture run is an idle machine, and the whole point of the panel is
        // the shape of a minute rather than the flat line an idle one has.
        Shot(name: "network", instance: widget(.network), isPreview: true, source: .sample),

        // Live, and genuinely running: `prepare` does exactly what pressing
        // Start does.
        Shot(name: "focus-timer", instance: widget(.timer), isPreview: false,
             source: .live, prepare: startFocusSession),

        // Live. The deadline is a real one, set when this run began, so the
        // figure counting down is the time actually left on it.
        Shot(name: "countdown",
             instance: widget(.countdown,
                              ["duration": .number(600),
                               "deadline": .number(started.timeIntervalSince1970 + 600)]),
             isPreview: false, source: .live),

        // Live, and really has been running that long: `started` is the moment
        // this tool launched, which is the same key the tile writes when the
        // watch is started.
        Shot(name: "stopwatch",
             instance: widget(.stopwatch,
                              ["started": .number(started.timeIntervalSince1970)]),
             isPreview: false, source: .live),

        // Live, and deliberately last of the panels: the graph is drawn from
        // `SystemMetrics`' rolling buffer, which has no `isPreview` stand-in -
        // the only way to show it is to let the sampler fill, which it has
        // been doing since launch while the other panels were captured.
        Shot(name: "system-activity",
             instance: widget(.system, ["metrics": .list([.string("cpu"),
                                                          .string("memory"),
                                                          .string("disk")])]),
             isPreview: false, source: .live,
             prepare: { await waitForHistory(samples: SystemMetrics.historyLength,
                                             limit: .seconds(75)) }),
    ]
}

/// The catalog's defaults under the overrides, so every shot is the widget as
/// the library adds it rather than one carrying only the keys typed here.
/// The three revenue kinds have no catalog entry, which is the fallback.
private func widget(_ kind: WidgetKind,
                    _ values: [String: WidgetConfig.Value] = [:]) -> WidgetInstance {
    WidgetCatalog.make(kind, overrides: values)
        ?? WidgetInstance(kind: kind, config: WidgetConfig(values))
}

/// Starts a focus session the way the panel's own Start button does.
///
/// `TimerStateProvider` is in-memory and is never persisted, so this touches
/// nothing the user has saved - and the countdown in the image is a real one,
/// not a time typed in to look busy.
@MainActor
private func startFocusSession() async {
    var state = TimerState()
    let length = Double(state.work * 60)
    state.duration = length
    state.deadline = Date().addingTimeInterval(length)
    TimerStateProvider.shared.state = state
}

// MARK: - Panels the tool does not take
//
// Calendar and Reminders both read EventKit, and authorisation is granted per
// binary: this tool has none, cannot ask for one without the usage strings a
// bundled app carries, and would be answered by a person at the machine rather
// than by a capture run. Their panels would render the permission line and
// nothing else. Now Playing is the same shape of problem - reading a player
// needs Automation consent this binary has not been granted - and Paddle and
// Shopify are the Stripe panel with a different word in it. One honest empty
// state is worth showing; four is a gallery of apologies.

// MARK: - Windows

/// A neutral field behind everything.
///
/// Three jobs, all honest. The material is translucent and samples what is
/// genuinely behind it, so it needs something with shape to refract or it
/// reads as a flat fill and the whole point of the surface is lost. Whatever
/// else is on the capture machine's screen stays out of the images. And it is
/// deliberately nobody's artwork and nobody else's app: two very soft washes
/// over the system's own window colours, which follow the appearance the Mac
/// is set to, so the panels' text and their backdrop can never end up the same
/// shade of anything.
private struct Backdrop: View {
    var body: some View {
        LinearGradient(colors: [Color(nsColor: .underPageBackgroundColor),
                                Color(nsColor: .windowBackgroundColor)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
            // Placed either side of the middle, which is where every capture
            // lands, so the glass has a gradient running under it rather than
            // one flat colour. Low enough that nothing downstream reads as
            // tinted.
            .overlay {
                RadialGradient(colors: [Color(hex: "#5B7CFA").opacity(0.15), .clear],
                               center: UnitPoint(x: 0.34, y: 0.38),
                               startRadius: 0, endRadius: 760)
            }
            .overlay {
                RadialGradient(colors: [Color(hex: "#E8916A").opacity(0.10), .clear],
                               center: UnitPoint(x: 0.74, y: 0.64),
                               startRadius: 0, endRadius: 700)
            }
    }
}

@MainActor
private func makeBackdrop(on screen: NSScreen) -> NSWindow {
    let window = NSWindow(contentRect: screen.frame, styleMask: .borderless,
                          backing: .buffered, defer: false)
    window.contentView = NSHostingView(rootView: Backdrop())
    window.isOpaque = true
    window.isReleasedWhenClosed = false
    window.ignoresMouseEvents = true
    window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
    // Above everything else on the display, so a terminal window cannot end up
    // inside a screenshot or underneath the material.
    window.level = .screenSaver
    window.setFrame(screen.frame, display: true)
    window.orderFrontRegardless()
    return window
}

/// A borderless, click-through window one step above the backdrop, which is
/// what both the panels and the shelf are photographed in.
///
/// - Parameter shadow: whether the *window* casts one. A panel needs it, since
///   its surface draws none of its own; the shelf's plate already draws one
///   inside its bounds and would get two.
@MainActor
private func makeWindow<Content: View>(_ content: Content, shadow: Bool,
                                       on screen: NSScreen) -> (NSWindow, NSHostingView<Content>)? {
    let hosting = NSHostingView(rootView: content)
    hosting.sizingOptions = [.intrinsicContentSize]
    let size = hosting.fittingSize
    guard size.width > 1, size.height > 1 else { return nil }

    let window = NSWindow(contentRect: CGRect(origin: .zero, size: size),
                          styleMask: .borderless, backing: .buffered, defer: false)
    window.contentView = hosting
    window.isOpaque = false
    window.backgroundColor = .clear
    window.hasShadow = shadow
    window.isReleasedWhenClosed = false
    window.ignoresMouseEvents = true
    window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
    window.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
    centre(window, size: size, on: screen)
    window.orderFrontRegardless()
    return (window, hosting)
}

/// Middle of the screen, well clear of every edge, so the shadow and the
/// padding around it always have room.
@MainActor
private func centre(_ window: NSWindow, size: CGSize, on screen: NSScreen) {
    window.setFrame(CGRect(x: (screen.frame.midX - size.width / 2).rounded(),
                           y: (screen.frame.midY - size.height / 2).rounded(),
                           width: size.width, height: size.height),
                    display: true)
}

@MainActor
private func makePanel(_ shot: Shot, on screen: NSScreen) -> NSWindow? {
    let chrome = WidgetDetailChrome(
        instance: shot.instance,
        context: WidgetContext(position: .bottom, now: .now, isPreview: shot.isPreview),
        // The tail points down, at a shelf on the bottom edge, which is where
        // the Dock is for almost everyone.
        edge: .bottom,
        session: UUID())

    guard let (window, _) = makeWindow(chrome, shadow: true, on: screen) else {
        log("\(shot.name): the panel measured empty, skipping")
        return nil
    }
    return window
}

// MARK: - The shelf
//
// The product itself, and the one thing this tool could not previously render:
// `DockShelfView` needs an `AppState`, and an `AppState` used to mean the
// user's own saved setup. `AppState(store:)` and `Store(directory:)` between
// them make a second, disposable one, so the shelf below is built in a
// temporary directory and nothing of theirs is read or written.

/// 0.5 is the one size where `Geometry.contentScale` is exactly 1: every
/// widget draws at the size it was authored at, with nothing scaled up or
/// down. It is a setting like any other, and the shelf ships smaller.
private let shelfScale: Double = 0.5

/// A shelf built for a picture: apps every Mac has, widgets that read live and
/// look different from one another, in an order that runs left to right.
///
/// Three settings are deliberately not the defaults, because the defaults
/// would photograph whoever is running this rather than the app: following the
/// system Dock would fill the shelf with their pinned apps, and running apps
/// would add whatever they happen to have open.
@MainActor
private func makeShelfState() -> AppState? {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appending(path: "docket-shots-\(UUID().uuidString)", directoryHint: .isDirectory)
    guard (try? FileManager.default.createDirectory(at: directory,
                                                    withIntermediateDirectories: true)) != nil
    else {
        log("could not make a temporary directory for the shelf; skipping it")
        return nil
    }

    var profile = DockProfile(kind: .customDock, name: "Showcase", scale: shelfScale)
    // Widgets first, then the apps, which is the order the shelf is built for:
    // it puts the size grip on the seam between the two, where the shelf keeps
    // it, so the image carries the handle the shelf is actually resized by.
    for instance in [widget(.clock),
                     widget(.world, ["zone": .string("Asia/Tokyo"),
                                     "city": .string("Tokyo")]),
                     widget(.system, ["metrics": .list([.string("cpu"),
                                                        .string("memory")])]),
                     widget(.notes, ["text": .string("Renew the domain")])] {
        profile.items.append(.widget(instance))
    }
    for bundleID in ["com.apple.finder", "com.apple.Safari", "com.apple.mail",
                     "com.apple.Terminal", "com.apple.systempreferences"] {
        // Skipped rather than drawn dead: an app that is genuinely not
        // installed has no icon to show, and the shelf would render it as a
        // repairable gap, which is not what this image is about.
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else {
            log("shelf: \(bundleID) is not installed here, leaving it out")
            continue
        }
        profile.items.append(.app(id: UUID(), bundleID: bundleID, ref: .capture(url)))
    }

    let shelf = AppState(store: Store(directory: directory))
    shelf.state.profiles = [profile]
    shelf.state.customDock.profileID = profile.id
    shelf.state.customDock.scale = shelfScale
    shelf.state.customDock.position = .bottom
    shelf.state.customDock.followSystemDock = false
    shelf.state.customDock.showRunningApps = false
    return shelf
}

/// The plate inside the shelf's window.
///
/// The window is larger than what it draws: `DockShelfView` keeps a margin at
/// each end of the row for a magnified icon to grow along it, and headroom
/// above the plate for a launch bounce to rise into. Neither is ever drawn at
/// rest, so photographing the whole window gives a shelf sitting in a band of
/// empty backdrop, off centre.
///
/// The two figures are recomputed here from the geometry the view derives them
/// from. If the view's reserve ever changes and this does not, the symptom is
/// uneven air around the shelf rather than a wrong picture of it.
@MainActor
private func plateRect(of window: NSWindow, shelf: AppState) -> CGRect {
    let icon = Geometry.iconGeometry(scale: shelf.effectiveScale,
                                     vertical: shelf.effectivePosition.isVertical,
                                     hasWidgets: shelf.hasWidgets).icon
    let magnifies = shelf.magnificationEnabled
    let along = magnifies ? shelf.magnificationRadius * shelf.magnificationPeak * 2 : 0
    let across = max(magnifies ? icon * shelf.magnificationPeak : 0, icon * Bounce.peak) + 12
    return CGRect(x: window.frame.minX + along / 2,
                  y: window.frame.minY,
                  width: window.frame.width - along,
                  height: window.frame.height - across)
}

// MARK: - Run

/// Enough for SwiftUI to lay out, the entrance animation to finish, and the
/// window server to have composited the material at least once.
private let settle = Duration.milliseconds(800)

/// Room around a surface for its shadow, which is part of how it looks and is
/// cropped off by the window frame alone. Only ever fills with backdrop.
private let shadowPadding: CGFloat = 26

/// The shape every panel image is captured in.
///
/// Panels are their own natural size: widths follow `WidgetDetail.width` per
/// kind and heights follow the content, which produced images from 664x334 to
/// 784x780. A grid of those reads as ragged rather than as a set, because a
/// row of images with different aspect ratios cannot line up.
///
/// What fixes that is a common *ratio*, not a common pixel size. One fixed
/// canvas big enough for the tallest panel leaves the short ones as small
/// islands in a field of backdrop, which looks worse than the raggedness it
/// was meant to fix. So each panel gets the smallest 4:3 box that holds it
/// with a margin, and every image then scales to the same shape in a grid
/// while the panel still fills most of its own frame.
private let panelAspect: CGFloat = 4.0 / 3.0

/// A quarter of the panel's longer side, so the surface has room to sit in
/// rather than being trimmed to its own edge.
private let panelMargin: CGFloat = 0.25

private func panelCanvas(for rect: CGRect) -> CGSize {
    let margin = max(rect.width, rect.height) * panelMargin
    let wanted = CGSize(width: rect.width + margin, height: rect.height + margin)
    // Grow whichever side is short of the ratio; never shrink, or the panel
    // would be cropped by its own frame.
    return wanted.width / wanted.height < panelAspect
        ? CGSize(width: wanted.height * panelAspect, height: wanted.height)
        : CGSize(width: wanted.width, height: wanted.width / panelAspect)
}

private extension CGRect {
    /// Slides the rect back inside `bounds` rather than trimming it.
    ///
    /// Panels open just above the Dock, so a canvas centred on one runs off
    /// the bottom of the screen. Cropping there would hand back a shorter
    /// image than every other panel, which is the raggedness the canvas
    /// exists to remove; sliding keeps the shape and only moves where the
    /// panel sits within it. Only a canvas larger than the screen is
    /// trimmed, and none of them are.
    func nudgedInside(_ bounds: CGRect) -> CGRect {
        var r = self
        r.origin.x = min(max(r.minX, bounds.minX), max(bounds.minX, bounds.maxX - r.width))
        r.origin.y = min(max(r.minY, bounds.minY), max(bounds.minY, bounds.maxY - r.height))
        return r.intersection(bounds)
    }
}

/// Waits for the metrics buffer to fill, so the history graph covers the full
/// minute it names rather than the handful of seconds it happened to have.
@MainActor
private func waitForHistory(samples wanted: Int, limit: Duration) async {
    let started = Date()
    while SystemMetrics.shared.cpuHistory.count < wanted {
        if Date().timeIntervalSince(started) > Double(limit.components.seconds) {
            log("history filled to \(SystemMetrics.shared.cpuHistory.count) of \(wanted) before the time limit; the panel will say so itself")
            return
        }
        log("waiting for system history: \(SystemMetrics.shared.cpuHistory.count)/\(wanted)")
        try? await Task.sleep(for: .seconds(2))
    }
}

/// Hands one region to the script and waits for it to come back.
/// - Returns: false once the script has closed the pipe, which ends the run.
@MainActor
private func capture(_ name: String, _ rect: CGRect, _ source: Source,
                     on screen: NSScreen, uniform: Bool = true) -> Bool {
    let region: CGRect
    if uniform {
        // Centred on the surface rather than fitted to it, so every panel
        // arrives at the same shape and a grid of them lines up.
        let canvas = panelCanvas(for: rect)
        region = CGRect(x: rect.midX - canvas.width / 2,
                        y: rect.midY - canvas.height / 2,
                        width: canvas.width, height: canvas.height)
            .nudgedInside(screen.frame)
    } else {
        region = rect.insetBy(dx: -shadowPadding, dy: -shadowPadding)
            .intersection(screen.frame)
    }
    let flipped = topLeftRect(region)
    emit("\(name) \(Int(flipped.minX)) \(Int(flipped.minY)) \(Int(flipped.width)) \(Int(flipped.height)) \(source.rawValue)")
    // Blocks the main thread until the script says the capture is done. Safe
    // to block: the window is already on screen and the window server
    // composites it without this process doing anything at all.
    guard readLine() != nil else {
        log("the capture script closed the pipe; stopping")
        return false
    }
    return true
}

@MainActor
private func run() async {
    // `.main` is the screen with keyboard focus, which a tool that never
    // becomes key may not have; the first screen is the primary display.
    guard let screen = NSScreen.main ?? NSScreen.screens.first else {
        log("no display attached - these shots have to be taken on a real screen")
        exit(1)
    }

    let started = Date()
    // Started first thing so the buffer is filling all through the run, and
    // the system panel - captured last of the panels - has a full minute to
    // draw.
    SystemMetrics.shared.start()

    let backdrop = makeBackdrop(on: screen)
    // The backdrop is what the material samples, so give it a moment to be on
    // screen before the first surface is placed over it.
    try? await Task.sleep(for: settle)

    // SHOTS_ONLY=clock,weather retakes just those, for iterating on a few
    // panels without sitting through every network wait. Unset, all of them.
    let only = ProcessInfo.processInfo.environment["SHOTS_ONLY"]
        .map { Set($0.split(separator: ",").map(String.init)) }

    for shot in shots(since: started) where only?.contains(shot.name) ?? true {
        await shot.prepare()
        guard let window = makePanel(shot, on: screen) else { continue }
        try? await Task.sleep(for: settle)
        let carryOn = capture(shot.name, window.frame, shot.source, on: screen)
        window.orderOut(nil)
        guard carryOn else {
            backdrop.orderOut(nil)
            exit(0)
        }
    }

    // Last, so every service the shelf's tiles read - the metrics sampler
    // above all - has been running for the whole session by the time it draws.
    if only?.contains("shelf-showcase") ?? true {
        await captureShelf(on: screen)
    }

    backdrop.orderOut(nil)
    log("done")
    exit(0)
}

@MainActor
private func captureShelf(on screen: NSScreen) async {
    guard let shelf = makeShelfState() else { return }
    guard let (window, hosting) = makeWindow(DockShelfView().environment(shelf),
                                             shadow: false, on: screen) else {
        log("shelf: measured empty, skipping")
        return
    }

    // Measured twice. The shelf sizes itself against the screen it believes it
    // is on, and it only learns that on its first appearance - so the size it
    // wanted before it was ever shown is not the size it settles at.
    try? await Task.sleep(for: settle)
    centre(window, size: hosting.fittingSize, on: screen)
    try? await Task.sleep(for: settle)

    // No canvas: the shelf is a long strip, and squaring it off would be
    // mostly empty space either side of it.
    _ = capture("shelf-showcase", plateRect(of: window, shelf: shelf), .live,
                on: screen, uniform: false)
    window.orderOut(nil)
}

let app = NSApplication.shared
// No Dock tile and no menu bar for a tool that exists for about a minute.
app.setActivationPolicy(.accessory)
/// SHOTS_RENDER=<dir> renders each panel's body offscreen to <dir>/<name>.png
/// instead of photographing the screen.
///
/// Only honest for surfaces that are opaque: the card every panel now sits on
/// is, the popover material around it is not and comes out transparent. It
/// needs no Screen Recording permission and no display, so it is how a panel
/// is looked at while those are unavailable, never what the README uses.
@MainActor
private func render(to directory: String) async {
    try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    SystemMetrics.shared.start()
    let only = ProcessInfo.processInfo.environment["SHOTS_ONLY"]
        .map { Set($0.split(separator: ",").map(String.init)) }
    for shot in shots(since: Date()) where only?.contains(shot.name) ?? true {
        await shot.prepare()
        // A live panel reads what its service has fetched, and offscreen
        // there is no window to show the number arriving in.
        if !shot.isPreview { try? await Task.sleep(for: .seconds(5)) }
        // SHOTS_PREVIEW draws every panel from its own sample data, for
        // judging a layout without depending on a fetch landing.
        let sample = shot.isPreview || ProcessInfo.processInfo.environment["SHOTS_PREVIEW"] != nil
        let context = WidgetContext(position: .bottom, now: .now, isPreview: sample)
        let view = WidgetDetailBody(instance: shot.instance, context: context)
            .padding(16)
            .frame(width: WidgetDetail.width(shot.instance.kind), alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .background(Color(white: 0.16))
            .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.cgImage,
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        else { log("\(shot.name): nothing rendered"); continue }
        let url = URL(fileURLWithPath: directory).appendingPathComponent("\(shot.name).png")
        try? data.write(to: url)
        print("\(shot.name) \(image.width)x\(image.height)")
    }
    exit(0)
}

/// SHOTS_TILES=<dir> renders every tile kind with its own sample data, on a
/// plate the shelf's colour, into one sheet: for looking at the tiles side by
/// side while the screen cannot be captured.
@MainActor
private func renderTiles(to directory: String) {
    try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    // SHOTS_EDGE=left draws the side shelf's column layouts instead.
    let edge: DockPosition = ProcessInfo.processInfo.environment["SHOTS_EDGE"] == "left" ? .left : .bottom
    let context = WidgetContext(position: edge, now: .now, isPreview: true)
    let kinds = WidgetKind.allCases.filter { WidgetCatalog.make($0) != nil }
    let sheet = LazyVGrid(columns: Array(repeating: GridItem(.fixed(edge == .left ? 190 : 420), alignment: .leading),
                                         count: edge == .left ? 4 : 1), alignment: .leading, spacing: 14) {
        ForEach(kinds, id: \.self) { kind in
            HStack(spacing: 12) {
                Text(kind.rawValue)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(width: 80, alignment: .trailing)
                WidgetTile(instance: widget(kind), context: context)
            }
        }
    }
    .padding(20)
    .background(Color(red: 0.12, green: 0.12, blue: 0.14))
    .environment(\.colorScheme, .dark)
    let renderer = ImageRenderer(content: sheet)
    renderer.scale = 2
    if let image = renderer.cgImage,
       let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
        try? data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("tiles.png"))
        print("tiles \(image.width)x\(image.height)")
    }
    exit(0)
}

Task { @MainActor in
    if let directory = ProcessInfo.processInfo.environment["SHOTS_TILES"] {
        renderTiles(to: directory)
    } else if let directory = ProcessInfo.processInfo.environment["SHOTS_RENDER"] {
        await render(to: directory)
    } else {
        await run()
    }
}
app.run()
