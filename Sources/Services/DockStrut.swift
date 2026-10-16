import AppKit

/// The strip of screen Apple's Dock reserves, and how to borrow it.
///
/// A window that zooms fills `NSScreen.visibleFrame`, and a borderless panel
/// does not shrink that by existing, at any window level. So a visible shelf
/// sits on top of zoomed windows and permanently covers their bottom edge,
/// which is issue #46 and the reason the shelf was only really usable
/// auto-hidden.
///
/// `-[NSScreen visibleFrame]` is `_layoutFrame` with exactly one rect taken
/// out of it: the global dock rect WindowServer hands out through
/// `SLSGetDockRectWithOrientation`. That rect is the only lever there is.
///
/// Writing it directly is possible and useless. `SLSSetDockRectWithReason`
/// returns success from an unentitled, ad-hoc signed process and really does
/// move `visibleFrame`, but only for processes launched afterwards: AppKit
/// caches the rect per process and refreshes it only from a broadcast over the
/// Dock's own MachService, which is SIP protected and which nothing else can
/// send. Apple's Dock then re-asserts its own rect within about a second and a
/// half. So the write lands, nothing that is already running notices, and the
/// Dock takes it back.
///
/// What works is to stop treating Apple's Dock as an obstacle. Leave it
/// running and visible on the shelf's own edge, sized so the strip it already
/// reserves is the strip the shelf wants, and draw the shelf over the top of
/// it. `visibleFrame` shrinks for free, and because the reservation belongs to
/// the Dock, every running app is told about it properly and immediately.
@MainActor
public enum DockStrut {

    // MARK: Reading

    private typealias GetDockRect = @convention(c) (
        Int32, UnsafeMutablePointer<CGRect>,
        UnsafeMutablePointer<Int32>, UnsafeMutablePointer<Int32>
    ) -> Int32
    private typealias MainConnection = @convention(c) () -> Int32

    private static let skylight: UnsafeMutableRawPointer? = dlopen(
        "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)

    /// Reads rather than writes, which is the whole point: nothing here asks
    /// WindowServer to do anything, it only asks what the Dock already claimed.
    /// A missing symbol degrades to "no strip", never to a guess.
    public static func reserved() -> CGRect {
        guard let skylight,
              let rectSymbol = dlsym(skylight, "SLSGetDockRectWithOrientation"),
              let connectionSymbol = dlsym(skylight, "SLSMainConnectionID")
        else { return .zero }

        let read = unsafeBitCast(rectSymbol, to: GetDockRect.self)
        let connection = unsafeBitCast(connectionSymbol, to: MainConnection.self)()

        var rect = CGRect.zero
        var reason: Int32 = 0
        var orientation: Int32 = 0
        guard read(connection, &rect, &reason, &orientation) == 0 else { return .zero }
        return rect
    }

    /// How thick the reserved strip is across the shelf's own axis.
    ///
    /// Zero while the Dock is hidden: WindowServer keeps the rect but collapses
    /// it, which is exactly the state that leaves windows running underneath.
    ///
    /// Zero, too, for a rect still laid along another edge. Moving the Dock
    /// restarts it, and until it comes back WindowServer still reports the
    /// old one: a Dock that had been on the left read as a strip 963pt
    /// "thick" on the bottom, the settle loop took two identical stale
    /// readings as settled, and the shelf was centred in that, floating in
    /// the middle of the screen with the enlarged Dock showing beneath it.
    public static func thickness(on edge: DockPosition) -> CGFloat {
        let rect = reserved()
        let alongEdge = edge.isVertical ? rect.height >= rect.width : rect.width >= rect.height
        guard alongEdge else { return 0 }
        return edge.isVertical ? rect.width : rect.height
    }

    // MARK: Writing

    private static let domain = "com.apple.dock"

    public static func snapshot() -> DockPrefs {
        let defaults = UserDefaults.standard.persistentDomain(forName: domain) ?? [:]
        return DockPrefs(
            autoHide: defaults["autohide"] as? Bool ?? false,
            // Apple's own default, used when the key has never been written.
            tileSize: defaults["tilesize"] as? Double ?? 48,
            orientation: defaults["orientation"] as? String ?? "bottom")
    }

    /// Puts the Dock on `edge`, visible, at `tileSize`, and waits for
    /// WindowServer to report the strip that results.
    ///
    /// Returns the measured thickness, never a predicted one. The relationship
    /// between tile size and reserved thickness was measured once, at one size,
    /// on one edge, and a formula derived from a single point is a guess. The
    /// caller sizes the shelf from what comes back.
    @discardableResult
    public static func claim(edge: DockPosition, tileSize: Double) async -> CGFloat {
        write(autoHide: false, tileSize: tileSize, orientation: edge.rawValue)
        await restartDock()
        return await settledThickness(on: edge)
    }

    /// Puts back exactly what `snapshot()` recorded.
    public static func release(_ snapshot: DockPrefs) async {
        releaseNow(snapshot)
    }

    /// The same, without the suspension.
    ///
    /// `applicationWillTerminate` has no time to await anything, and the Dock
    /// being restored is more important than the app exiting promptly: the
    /// alternative is quitting Docket and silently keeping its Dock settings.
    public static func releaseNow(_ snapshot: DockPrefs) {
        write(autoHide: snapshot.autoHide,
              tileSize: snapshot.tileSize,
              orientation: snapshot.orientation)
        restartDockNow()
    }

    private static func write(autoHide: Bool, tileSize: Double, orientation: String) {
        let defaults = UserDefaults.standard
        var domainValues = defaults.persistentDomain(forName: domain) ?? [:]
        domainValues["autohide"] = autoHide
        domainValues["tilesize"] = tileSize
        domainValues["orientation"] = orientation
        defaults.setPersistentDomain(domainValues, forName: domain)
        // The Dock reads its preferences at launch, so the write alone changes
        // nothing until it is restarted.
        CFPreferencesAppSynchronize(domain as CFString)
    }

    // MARK: Hiding entirely

    /// Hides the Dock for good: auto-hide on, with a reveal delay so long it
    /// never comes. Returns what was there before, for `restoreVisibility`.
    public static func hideCompletely() -> DockVisibility {
        let values = UserDefaults.standard.persistentDomain(forName: domain) ?? [:]
        let snapshot = DockVisibility(autoHide: values["autohide"] as? Bool,
                                      delay: (values["autohide-delay"] as? NSNumber)?.doubleValue,
                                      timeModifier: (values["autohide-time-modifier"] as? NSNumber)?.doubleValue)
        writeVisibility(autoHide: true, delay: 1000, timeModifier: snapshot.timeModifier)
        restartDockNow()
        return snapshot
    }

    /// Puts back exactly what `hideCompletely` found.
    public static func restoreVisibility(_ snapshot: DockVisibility) {
        writeVisibility(autoHide: snapshot.autoHide, delay: snapshot.delay,
                        timeModifier: snapshot.timeModifier)
        restartDockNow()
    }

    /// A nil value deletes the key, so a preference the user never set is
    /// not left behind as one they did.
    private static func writeVisibility(autoHide: Bool?, delay: Double?, timeModifier: Double?) {
        let defaults = UserDefaults.standard
        var values = defaults.persistentDomain(forName: domain) ?? [:]
        values["autohide"] = autoHide
        values["autohide-delay"] = delay
        values["autohide-time-modifier"] = timeModifier
        defaults.setPersistentDomain(values, forName: domain)
        CFPreferencesAppSynchronize(domain as CFString)
    }

    private static func restartDock() async { restartDockNow() }

    private static func restartDockNow() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        task.arguments = ["Dock"]
        // A Dock that is not running is not an error: launchd brings it back,
        // and killall's failure exit is the only thing that would be lost.
        try? task.run()
        task.waitUntilExit()
    }

    /// Polls until the reported thickness stops changing.
    ///
    /// The Dock takes most of a second to come back and publish its rect, and
    /// the value is briefly zero on the way. Waiting for two equal non-zero
    /// readings avoids sizing the shelf against a Dock that is still starting.
    private static func settledThickness(on edge: DockPosition) async -> CGFloat {
        var previous: CGFloat = -1
        for _ in 0 ..< 40 {
            try? await Task.sleep(for: .milliseconds(100))
            let current = thickness(on: edge)
            if current > 0, current == previous { return current }
            previous = current
        }
        return max(previous, 0)
    }
}
