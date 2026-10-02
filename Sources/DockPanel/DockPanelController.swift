import AppKit
import SwiftUI

/// Owns the floating shelf window: where it sits, what level it floats at, and
/// hiding it against the screen edge.
///
/// An `NSPanel` rather than an `NSWindow` so it never takes key status -
/// clicking the shelf must not deactivate whatever the user was working in.
@MainActor
final class DockPanelController: NSObject, NSWindowDelegate {
    private var panel: NSPanel?
    private let app: AppState

    private var revealed = true
    private var hideWorkItem: DispatchWorkItem?
    private var groupCloseItem: DispatchWorkItem?
    /// True while any menu of ours is open.
    ///
    /// A context menu draws *above* the shelf, so reaching for an item takes
    /// the pointer outside the shelf's own frame - which is exactly what the
    /// hide timer watches for. The shelf then slid away and took the menu
    /// with it, which reads as a menu that will not let you pick anything.
    private var menuIsOpen = false
    private var menuObservers: [any NSObjectProtocol] = []
    private var pollTimer: Timer?

    /// How close to the screen edge the pointer must get to bring the shelf back.
    private let revealZoneDepth: CGFloat = 3
    /// Grace before hiding again, so brushing past the edge of the shelf on the
    /// way somewhere else does not make it flicker.
    private let hideDelay: TimeInterval = 0.35

    init(app: AppState) {
        self.app = app
        super.init()
        for (name, opening) in [(NSMenu.didBeginTrackingNotification, true),
                                (NSMenu.didEndTrackingNotification, false)] {
            menuObservers.append(
                NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) {
                    [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.menuIsOpen = opening
                        MenuTracking.isOpen = opening
                        if opening {
                            self.hideWorkItem?.cancel()
                            self.hideWorkItem = nil
                        }
                    }
                })
        }
    }

    // MARK: Lifecycle

    func show() {
        guard panel == nil else { return refresh() }

        // The view rather than a controller, so it can handle the scroll
        // wheel; it resizes the panel itself in `layout()`.
        let host = ScrollingHostingView(rootView: DockShelfView().environment(app))
        host.sizingOptions = [.intrinsicContentSize]
        host.onWantedSize = { [weak self] size in self?.resize(to: size) }

        let panel = NSPanel(contentRect: .zero,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.contentView = host
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false                 // the SwiftUI surface draws its own
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        // Borderless panels get no mouse-moved events by default, which means
        // no hover, which means no magnification and no tooltips.
        panel.acceptsMouseMovedEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.delegate = self
        panel.level = level

        self.panel = panel
        panel.orderFrontRegardless()
        refresh()
    }

    func hide() {
        GroupWindow.shared.close()
        WidgetDetailWindow.shared.close()
        TooltipWindow.shared.hide()
        panel?.orderOut(nil)
    }

    func close() {
        stopPolling()
        GroupWindow.shared.close()
        WidgetDetailWindow.shared.close()
        TooltipWindow.shared.hide()
        panel?.close()
        panel = nil
    }

    /// Re-read everything that can change: whether there is a shelf at all,
    /// level, placement, auto-hide.
    func refresh() {
        // The setup decides whether there is a shelf, and it used to be read
        // once at launch. Choosing "Apple Dock" in Settings saved the choice
        // and left the shelf on screen, and choosing a shelf from there
        // showed nothing until a relaunch. Every setup change already lands
        // here, so this is where it is honoured.
        guard app.state.setup != .macOSDockOnly else {
            stopPolling()
            hide()
            // Still: leaving "Shelf only" for "Apple Dock" has to hand the
            // Dock's strip back.
            syncStrut()
            return
        }
        guard let panel else { return show() }
        if !panel.isVisible { panel.orderFrontRegardless() }
        panel.level = level
        if app.effectiveAutoHide {
            startPolling()
        } else {
            stopPolling()
            revealed = true
        }
        applyPlacement(animated: false)
        syncStrut()
    }

    /// Takes or gives back Apple's Dock reserved strip as the setup changes.
    ///
    /// Restarting the Dock takes the best part of a second, so this runs
    /// detached and re-places the shelf when the strip is known. Entering is
    /// also the one place in the app that asks the user a question, which is
    /// another reason it cannot be on the path of an ordinary settings write.
    private func syncStrut() {
        let wanted = StrutMode.wanted(for: app.state.setup)
        let borrowed = app.state.borrowedDockPrefs != nil
        guard wanted != borrowed else { return }

        Task { @MainActor [weak self] in
            guard let self else { return }
            if wanted {
                let thickness = await StrutMode.enter(
                    edge: app.effectivePosition,
                    wanting: panel?.frame.size.thickness(on: app.effectivePosition) ?? 0,
                    state: app.state,
                    record: { [weak self] prefs in self?.app.state.borrowedDockPrefs = prefs })
                // Declined, so the setup goes back rather than leaving a mode
                // selected that is not in effect.
                if thickness == nil { app.state.setup = .both }
            } else {
                await StrutMode.leave(state: app.state,
                                      clear: { [weak self] in self?.app.state.borrowedDockPrefs = nil })
            }
            // Re-read Apple's Dock before deciding where the shelf goes.
            //
            // Docket has just written those preferences itself and restarted
            // the Dock. The distributed notification that keeps this cache
            // honest is posted for *other* processes changing the Dock;
            // nothing re-reads after our own write. So everything derived
            // from it would be computed from what the Dock looked like
            // before we changed it: `effectivePosition` takes the edge
            // opposite the Dock's, and `effectiveAutoHide` follows its
            // hiding.
            //
            // Both went stale here. Claiming the strip moves the Dock to the
            // shelf's edge, so a stale read put the shelf on the edge
            // opposite the one it was already on, which is how it ended up
            // vertical in the middle of the screen; and the claim turns the
            // Dock's auto-hide off, so a stale read left the shelf parked
            // off-screen believing it still auto-hid. Giving the strip back
            // did the same in reverse.
            //
            // `refresh()` rather than `applyPlacement` because the auto-hide
            // poller has to be started or stopped on the new answer too. It
            // calls `syncStrut` again, which returns at its own guard now
            // that what is wanted and what is borrowed agree.
            SystemDockSettings.shared.refresh()
            refresh()
        }
    }

    func reposition() { applyPlacement(animated: false) }

    /// Above Apple's Dock normally; behind everything when acting as a desktop
    /// widget, where the point is for windows to cover it.
    private var level: NSWindow.Level {
        app.state.customDock.useAsDesktopWidget
            ? NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
            : NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) + 1)
    }

    // MARK: Placement

    private var targetScreen: NSScreen {
        if let id = app.state.customDock.displayID,
           let match = NSScreen.screens.first(where: { $0.displayID == id }) {
            return match
        }
        // One display, the main one, unless another is chosen in Settings.
        //
        // It used to follow the pointer from display to display, first on
        // any move and then only at a display's own edge, and both went wrong
        // with a laptop below a monitor: reaching for the monitor's bottom
        // edge crosses onto the laptop, and the shelf left, or showed up on
        // the screen nobody was looking at. A shelf belongs somewhere. The
        // first screen is the one carrying the menu bar, which is what
        // "main display" means in System Settings.
        return NSScreen.screens.first ?? NSScreen.main!
    }

    /// Where the shelf sits when visible.
    private var revealedOrigin: CGPoint { revealedOrigin(for: panel?.frame.size ?? .zero) }

    private func revealedOrigin(for size: CGSize) -> CGPoint {
        // Borrowing the Dock's strip means sitting *in* it, not above it.
        // `visibleFrame` already excludes the reservation, so placing against
        // it would put the shelf beside its own strut and leave the reserved
        // band showing the Dock underneath.
        if app.state.borrowedDockPrefs != nil {
            return borrowedOrigin(for: size)
        }

        let visible = targetScreen.visibleFrame
        let inset: CGFloat = 6 + systemDockClearance

        let origin: CGPoint = switch app.effectivePosition {
        case .bottom: CGPoint(x: visible.midX - size.width / 2, y: visible.minY + inset)
        case .left: CGPoint(x: visible.minX + inset, y: visible.midY - size.height / 2)
        case .right: CGPoint(x: visible.maxX - size.width - inset, y: visible.midY - size.height / 2)
        }

        // Never let the shelf hang off-screen at large scales on small displays.
        return CGPoint(
            x: min(max(origin.x, visible.minX), max(visible.minX, visible.maxX - size.width)),
            y: min(max(origin.y, visible.minY), max(visible.minY, visible.maxY - size.height))
        )
    }

    /// Centred in the strip Apple's Dock is reserving on the shelf's behalf.
    ///
    /// Measured from the screen's own frame rather than `visibleFrame`, since
    /// the reservation is precisely what was taken out of the latter. Centred
    /// rather than flush so a shelf thinner than the strip does not leave the
    /// Dock visible along one edge of it.
    private func borrowedOrigin(for size: CGSize) -> CGPoint {
        let frame = targetScreen.frame
        let strip = DockStrut.thickness(on: app.effectivePosition)
        let shelf = size.thickness(on: app.effectivePosition)
        let slack = max(0, strip - shelf) / 2

        return switch app.effectivePosition {
        case .bottom: CGPoint(x: frame.midX - size.width / 2, y: frame.minY + slack)
        case .left: CGPoint(x: frame.minX + slack, y: frame.midY - size.height / 2)
        case .right: CGPoint(x: frame.maxX - size.width - slack, y: frame.midY - size.height / 2)
        }
    }

    /// Clearance for Apple's Dock if the user has put us on its edge anyway.
    ///
    /// Normally zero: while following we pick a free edge, and a Dock that is
    /// not auto-hidden has already been excluded from `visibleFrame`.
    private var systemDockClearance: CGFloat {
        let system = SystemDockSettings.shared
        guard app.effectivePosition == system.position, system.autoHide else { return 0 }
        return system.tileSize + 22
    }

    /// Fully off the edge it is docked to, like Apple's Dock.
    private var hiddenOrigin: CGPoint { hiddenOrigin(for: panel?.frame.size ?? .zero) }

    private func hiddenOrigin(for size: CGSize) -> CGPoint {
        let frame = targetScreen.frame
        let shown = revealedOrigin(for: size)
        // With another display past the edge there is no "off screen" to
        // park in: the shelf would sit on the neighbouring display, and slide
        // across the seam to come back. It stays on its own screen instead,
        // a short way toward the edge, and fades; see `edgeIsShared`.
        if edgeIsShared {
            let nudge: CGFloat = 14
            return switch app.effectivePosition {
            case .bottom: CGPoint(x: shown.x, y: shown.y - nudge)
            case .left: CGPoint(x: shown.x - nudge, y: shown.y)
            case .right: CGPoint(x: shown.x + nudge, y: shown.y)
            }
        }
        let peek = handlePeek
        return switch app.effectivePosition {
        case .bottom: CGPoint(x: shown.x, y: frame.minY - size.height + peek)
        case .left: CGPoint(x: frame.minX - size.width + peek, y: shown.y)
        case .right: CGPoint(x: frame.maxX - peek, y: shown.y)
        }
    }

    /// Whether another display continues past the shelf's edge.
    ///
    /// A MacBook below an external monitor shares the monitor's bottom edge,
    /// and hiding by moving off that edge parked the shelf on the top of the
    /// laptop's screen, from where every reveal slid it up across the seam.
    /// Measured against every other screen's frame, with a point of slack for
    /// arrangements that do not quite meet, and only where the two overlap
    /// along the edge: a display that merely touches a corner does not count.
    private var edgeIsShared: Bool {
        let screen = targetScreen
        let frame = screen.frame
        return NSScreen.screens.contains { other in
            guard other != screen else { return false }
            let o = other.frame
            switch app.effectivePosition {
            case .bottom: return abs(o.maxY - frame.minY) < 2 && o.maxX > frame.minX && o.minX < frame.maxX
            case .left: return abs(o.maxX - frame.minX) < 2 && o.maxY > frame.minY && o.minY < frame.maxY
            case .right: return abs(o.minX - frame.maxX) < 2 && o.maxY > frame.minY && o.minY < frame.maxY
            }
        }
    }

    /// How opaque the shelf should be: hidden against a shared edge means
    /// faded, everywhere else it is moved out of sight and stays opaque.
    private var targetAlpha: CGFloat { (!revealed && edgeIsShared) ? 0 : 1 }

    /// How much of the shelf stays on screen while hidden.
    ///
    /// "Show handle when hidden" was read by nothing: hiding moved the panel
    /// entirely off the edge, so there was never a handle to show and the
    /// toggle had no effect in either position.
    ///
    /// Three points, which is enough to see and to aim at without being a
    /// stripe along the edge of the screen. The reveal still happens on
    /// approach rather than on hitting it, so this is a marker of where the
    /// shelf is rather than the only way to bring it back.
    private var handlePeek: CGFloat {
        app.state.customDock.showHandleWhenHidden ? 3 : 0
    }

    /// Why the shelf is moving, which decides how it moves.
    ///
    /// A pointer at the screen edge wants the shelf *now*, so that motion is
    /// short and decisive. Mission Control is a slow heavy transition of the
    /// whole screen, and a shelf that snaps into place in a fifth of a second
    /// beside it looks like a separate event rather than part of the same
    /// one.
    enum Motion {
        case pointer
        case missionControl
        /// The rest of a swipe after the fingers let go. It is already moving,
        /// so it starts at speed and slows, rather than easing in from rest
        /// the way a slide that begins from nothing does.
        case swipeRelease

        var duration: TimeInterval {
            switch self {
            case .pointer: 0.22
            case .missionControl: 0.35
            case .swipeRelease: 0.25
            }
        }

        var timing: CAMediaTimingFunctionName {
            switch self {
            // Eased at both ends, because it is accompanying something that
            // starts and stops rather than answering a flick.
            case .pointer: .easeOut
            case .missionControl: .easeInEaseOut
            case .swipeRelease: .easeOut
            }
        }
    }

    private func applyPlacement(animated: Bool, motion: Motion = .pointer) {
        guard let panel, panel.frame.width > 1, panel.frame.height > 1 else { return }
        let origin = revealed ? revealedOrigin : hiddenOrigin
        // Faded out, it must not take the clicks meant for whatever is behind.
        let alpha = targetAlpha
        panel.ignoresMouseEvents = alpha == 0
        if panel.alphaValue != alpha {
            if animated {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = motion.duration
                    panel.animator().alphaValue = alpha
                }
            } else {
                panel.alphaValue = alpha
            }
        }
        guard panel.frame.origin != origin else { return }
        if animated {
            // NSWindow's animator proxy only animates `setFrame(_:display:)`.
            // `setFrameOrigin` through the proxy silently does nothing, which
            // left the shelf parked off-screen while it believed it was shown.
            NSAnimationContext.runAnimationGroup { context in
                context.duration = motion.duration
                context.timingFunction = CAMediaTimingFunction(name: motion.timing)
                panel.animator().setFrame(CGRect(origin: origin, size: panel.frame.size),
                                          display: true)
            }
        } else {
            panel.setFrameOrigin(origin)
        }
    }

    /// Takes the shelf to a new size and the position that size belongs at,
    /// in one move.
    ///
    /// The hosting view used to set the window's size itself, which kept the
    /// old origin - so the shelf stretched out of one corner, and only then
    /// did `windowDidResize` snap it back to centre. Two instant steps, and
    /// the jump between them is what made resizing look broken.
    func resize(to size: CGSize) {
        guard let panel, size.width > 1, size.height > 1 else { return }
        let origin = revealed ? revealedOrigin(for: size) : hiddenOrigin(for: size)
        let frame = CGRect(origin: origin, size: size)
        guard panel.frame != frame else { return }

        // The very first layout has nothing to animate from, and a grip drag
        // must not be eased at all - see ShelfResize.
        guard panel.frame.width > 1, panel.frame.height > 1,
              !ShelfResize.isDragging else {
            // `display: false`. Forcing a synchronous redraw on every event of
            // a grip drag is the largest single cost in the resize - measured
            // heavier than the layout solve it triggers - and it buys nothing:
            // the content changed, so the window redraws on the next cycle
            // regardless. The same mistake the hover label made.
            return panel.setFrame(frame, display: false)
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(frame, display: false)
        }
    }

    // MARK: Auto-hide

    /// Polls the pointer rather than installing a global event monitor.
    ///
    /// While hidden the shelf is off-screen, so its own tracking area can never
    /// fire - something has to watch the screen edge. `NSEvent.mouseLocation`
    /// is a plain static read needing no permission, and 30Hz of that is far
    /// cheaper than a global event tap (which users would have to approve).
    private func startPolling() {
        guard pollTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
        revealed = false
        gesture.start { [weak self] in self?.follow($0) }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
        hideWorkItem?.cancel()
        hideWorkItem = nil
        groupCloseItem?.cancel()
        groupCloseItem = nil
        gesture.stop()
        swiping = false
        swipe = nil
    }

    /// Cached behind its own throttle; see MissionControlProbe.
    private var missionControl = MissionControlProbe()

    /// Whether the shelf is out because Mission Control is, so that its
    /// closing can take the shelf with it.
    private var heldForMissionControl = false

    /// Only while auto-hiding, like the poller: a shelf that never leaves has
    /// nothing to bring out.
    private let gesture = MissionControlGesture()

    /// Whether a swipe is under the fingers, and which way it carries the
    /// shelf - nil for one it is leaving alone. Decided on the first event
    /// and kept to the end, so a swipe that started ignored stays ignored.
    private var swiping = false
    private var swipe: MissionControlSwipe?

    /// When the last followed swipe let go. Mission Control finishes on its
    /// own after that, and its backdrop lingers through a spring-back, so
    /// the probe is not listened to until it has settled.
    private var swipeEndedAt = Date.distantPast
    private let swipeSettle: TimeInterval = 0.5

    private func poll() {
        guard panel != nil else { return }
        let mouse = NSEvent.mouseLocation

        // Never while a menu of ours is up - see `menuIsOpen`.
        if menuIsOpen {
            hideWorkItem?.cancel()
            hideWorkItem = nil
            return
        }

        // An opened group pins the shelf. The sheet is anchored to one of the
        // tiles, so sliding the shelf out from under it would leave it
        // floating over the desktop - and the group is exactly when the user
        // is *using* the shelf. It closes on its own once the pointer has
        // left both, and hiding resumes from the next tick.
        // An open detail panel pins the shelf for the same reason an open
        // group does: the panel is anchored to a tile, and it is precisely
        // when the user is using the shelf.
        // The panel closes itself on a click outside, on Escape and on
        // Command-W - it does not close because the pointer wandered off, any
        // more than a popover does. So there is nothing to schedule here; the
        // shelf just stays put while the panel is up.
        // The widget library pins it for the same reason: what is picked
        // there lands on the shelf, and it should be in view when it does.
        if WidgetDetailWindow.shared.isOpen || LibraryWindow.shared.isOpen {
            hideWorkItem?.cancel()
            hideWorkItem = nil
            if !revealed { setRevealed(true) }
            return
        }

        if GroupWindow.shared.isOpen {
            hideWorkItem?.cancel()
            hideWorkItem = nil
            if !revealed { setRevealed(true) }

            // An icon being dragged out is *meant* to be outside both. Closing
            // the sheet under it would cancel the gesture that is carrying it,
            // which is why dragging one out could not be completed at all.
            if withinShelf(mouse) || GroupWindow.shared.contains(mouse)
                || DragOut.shared.item != nil {
                groupCloseItem?.cancel()
                groupCloseItem = nil
            } else if groupCloseItem == nil {
                scheduleGroupClose()
            }
            return
        }
        groupCloseItem?.cancel()
        groupCloseItem = nil

        // A swipe is carrying the shelf, or has just let go of it. The
        // fingers are the authority until Mission Control has settled.
        if swipe != nil { return }
        if Date().timeIntervalSince(swipeEndedAt) < swipeSettle { return }

        // Mission Control is up, so the shelf belongs on screen with it.
        //
        // It was never hidden *by* Mission Control. The shelf sits at CG
        // layer 21 and Mission Control composites at 18 and 20, so it already
        // draws above it; what actually happens is that an auto-hidden shelf
        // is parked off the edge and nothing about a three finger swipe puts
        // the pointer in the reveal strip. Measured: across a full open and
        // close the shelf never moved from 97 of its 100 points below the
        // screen. So it needs telling, not raising.
        //
        // Ahead of the Dock-yield below on purpose. Mission Control *is*
        // Dock.app, and it reveals Apple's Dock as part of itself, which the
        // next branch would otherwise read as "the Dock is coming, get out of
        // the way" and use to hide the shelf at exactly the moment it was
        // asked for.
        if missionControl.isShowing() {
            hideWorkItem?.cancel()
            hideWorkItem = nil
            if !revealed { setRevealed(true, motion: .missionControl) }
            heldForMissionControl = true
            return
        }

        // Mission Control has just closed, so leave with it.
        //
        // Falling through to the ordinary path would schedule a hide behind
        // `hideDelay`, which exists so that brushing past the shelf on the
        // way somewhere else does not make it flicker. That has nothing to do
        // with this, and a third of a second of the shelf sitting alone on
        // the desktop after the thumbnails have gone is the exit half of the
        // same seam the entrance had.
        if heldForMissionControl {
            heldForMissionControl = false
            if revealed, !withinShelf(mouse) {
                hideWorkItem?.cancel()
                hideWorkItem = nil
                setRevealed(false, motion: .missionControl)
                return
            }
        }

        // Apple's Dock is sliding in over the same edge. Two surfaces stacked
        // on one edge fight: they share a reveal trigger, so reaching for one
        // uncovers the other and the shelf sits on top of the Dock the user
        // was actually going for. Yielding is the only way either is usable.
        if app.state.customDock.hideWhenMacOSDockAppears, systemDockIsShowing(mouse) {
            hideWorkItem?.cancel()
            hideWorkItem = nil
            if revealed { setRevealed(false) }
            return
        }

        if revealed {
            // A generous margin: the shelf must not vanish the instant the
            // pointer crosses its border on the way to a tile at the far end.
            if withinShelf(mouse) {
                hideWorkItem?.cancel()
                hideWorkItem = nil
            } else if hideWorkItem == nil {
                scheduleHide()
            }
        } else if revealZone.contains(mouse) {
            setRevealed(true)
        }
    }

    /// Whether Apple's Dock is on screen, or about to be, on the shelf's edge.
    ///
    /// Only its own edge matters: a Dock on the left and a shelf on the bottom
    /// never contend for the same pixels, so the setting does nothing there.
    ///
    /// The two cases need different signals, and getting that wrong is easy.
    /// A Dock that does not auto-hide is simply always out, which the rect it
    /// publishes says plainly. An auto-hidden Dock is the case this setting
    /// actually exists for, and **the rect does not move when it slides in**:
    /// measured, it stays collapsed the whole time, because `visibleFrame` is
    /// not supposed to change when the Dock temporarily reveals. Nothing
    /// public reports that it is out.
    ///
    /// So the second case is inferred from the pointer, which is the same
    /// thing that causes it: within the Dock's own reveal strip on the shared
    /// edge, the Dock is coming out whether or not it has arrived yet. The
    /// shelf yields on the way rather than after the collision, which is also
    /// the right moment for it.
    private func systemDockIsShowing(_ mouse: CGPoint) -> Bool {
        let system = SystemDockSettings.shared
        let edge = app.effectivePosition
        guard edge == system.position else { return false }

        if !system.autoHide { return DockStrut.thickness(on: edge) > 0 }

        guard let screen = targetScreen as NSScreen? else { return false }
        let frame = screen.frame
        // Matches the depth the Dock itself treats as its trigger.
        let strip: CGFloat = 4
        return switch edge {
        case .bottom: mouse.y <= frame.minY + strip
        case .left: mouse.x <= frame.minX + strip
        case .right: mouse.x >= frame.maxX - strip
        }
    }

    /// A generous margin: the shelf must not vanish the instant the pointer
    /// crosses its border on the way to a tile at the far end.
    private func withinShelf(_ point: CGPoint) -> Bool {
        shelfFrame.insetBy(dx: -12, dy: -12).contains(point)
    }

    private var shelfFrame: CGRect {
        guard let panel else { return .zero }
        return CGRect(origin: revealedOrigin, size: panel.frame.size)
    }

    /// A thin strip along the docked edge, spanning the shelf's extent.
    private var revealZone: CGRect {
        let frame = targetScreen.frame
        let shelf = shelfFrame
        // A shared edge is not a wall the pointer stops against: it carries
        // straight on to the next display, and a 3pt strip on this side is
        // crossed between two samples. So the band reaches a little past the
        // seam as well, where the pointer is when it has just gone over.
        let past: CGFloat = edgeIsShared ? 6 : 0
        let depth = revealZoneDepth + past
        return switch app.effectivePosition {
        case .bottom:
            CGRect(x: shelf.minX, y: frame.minY - past, width: shelf.width, height: depth)
        case .left:
            CGRect(x: frame.minX - past, y: shelf.minY, width: depth, height: shelf.height)
        case .right:
            CGRect(x: frame.maxX - revealZoneDepth, y: shelf.minY,
                   width: depth, height: shelf.height)
        }
    }

    /// Closes an opened group once the pointer has left both it and the
    /// shelf. Longer than the hide delay: reaching a sheet that sits above
    /// the shelf means crossing empty space, and that must not dismiss it.
    private func scheduleGroupClose() {
        let work = DispatchWorkItem {
            MainActor.assumeIsolated { GroupWindow.shared.close() }
        }
        groupCloseItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func scheduleHide() {
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.app.effectiveAutoHide else { return }
                self.setRevealed(false)
            }
        }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + hideDelay, execute: work)
    }

    /// Moves the shelf with a three finger swipe, the way Apple's Dock moves
    /// with Mission Control. See MissionControlGesture.
    private func follow(_ event: MissionControlGesture.Event) {
        guard let panel else { return }
        if !swiping {
            swiping = true
            swipe = swipeDirection()
        }
        if case .ended = event { swiping = false }
        guard let direction = swipe else { return }

        switch event {
        case .moved(let progress):
            let amount = CGFloat(direction.revealed(at: progress))
            let hidden = hiddenOrigin, shown = revealedOrigin
            panel.setFrameOrigin(CGPoint(x: hidden.x + (shown.x - hidden.x) * amount,
                                         y: hidden.y + (shown.y - hidden.y) * amount))
            // Against a shared edge the reveal is a fade, so it follows the
            // fingers in opacity as well as in place.
            if edgeIsShared {
                panel.alphaValue = amount
                panel.ignoresMouseEvents = amount == 0
            }
        case .ended(let progress, let velocity):
            swipe = nil
            swipeEndedAt = Date()
            let commits = direction.commits(at: progress, velocity: velocity)
            let target = direction == .opening ? commits : !commits
            heldForMissionControl = target
            // `setRevealed` does nothing when the state already matches, and
            // a spring-back is exactly that: the shelf is mid-way but still
            // believes it is where it started.
            if revealed == target {
                applyPlacement(animated: true, motion: .swipeRelease)
            } else {
                setRevealed(target, motion: .swipeRelease)
            }
        }
    }

    /// Whether this swipe is one to follow, and which way. Nil to leave it.
    private func swipeDirection() -> MissionControlSwipe? {
        // Anything that pins the shelf out pins it through a swipe too.
        if menuIsOpen || GroupWindow.shared.isOpen || WidgetDetailWindow.shared.isOpen
            || LibraryWindow.shared.isOpen {
            return nil
        }
        if !revealed, !heldForMissionControl { return .opening }
        // Out for Mission Control, and not being reached for.
        if revealed, heldForMissionControl, !withinShelf(NSEvent.mouseLocation) {
            return .closing
        }
        // Out because the pointer brought it out: Mission Control opening
        // does not change that, and the probe keeps it there.
        return nil
    }

    private func setRevealed(_ value: Bool, motion: Motion = .pointer) {
        guard revealed != value else { return }
        // Everything anchored to a tile has to go with it. Hiding is a window
        // *move*, not an orderOut - the shelf slides to `hiddenOrigin` and its
        // view never disappears - so nothing here tears itself down on its
        // own. The hover label is the one that showed it: the tracking area
        // only reports an exit when the pointer leaves, and when the shelf
        // slides out from under a pointer that never moved, it does not. The
        // label was left sitting over the desktop pointing at nothing.
        if !value {
            GroupWindow.shared.close()
            WidgetDetailWindow.shared.close()
            TooltipWindow.shared.hide()
        }
        revealed = value
        hideWorkItem?.cancel()
        hideWorkItem = nil
        applyPlacement(animated: true, motion: motion)
    }

    // MARK: NSWindowDelegate

    func windowDidResize(_ notification: Notification) {
        // `resize(to:)` already places the frame it animates to. Re-placing on
        // every intermediate step of that animation would fight it.
        guard !NSAnimationContext.current.allowsImplicitAnimation else { return }
        applyPlacement(animated: false)
    }
}

extension NSScreen {
    var displayID: UInt32? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32
    }
}
