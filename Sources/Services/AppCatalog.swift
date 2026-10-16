import AppKit
import Observation

public struct RunningApp: Identifiable, Sendable, Hashable {
    public var id: String          // bundle identifier
    public var name: String
    public var url: URL?
    public var isActive: Bool
}

/// Knows what is running and what things look like.
///
/// Icon lookup goes through a cache because `NSWorkspace.icon(forFile:)` hits
/// the disk, and the shelf asks for every icon on every layout pass.
@MainActor
@Observable
public final class AppCatalog {
    public static let shared = AppCatalog()

    public private(set) var running: [RunningApp] = []
    /// Membership only, for the hot path.
    ///
    /// `isRunning` is asked once per tile per render - the context menu alone
    /// calls it for every icon on every layout pass - and a linear scan of
    /// `running` there costs hundreds of string compares a frame. Observed,
    /// not ignored, so a launch or quit still invalidates the tiles.
    public private(set) var runningIDs: Set<String> = []

    @ObservationIgnored private var iconCache: [String: NSImage] = [:]
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    private init() {
        refresh()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.didActivateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
    }

    public func refresh() {
        running = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil }
            .map {
                RunningApp(id: $0.bundleIdentifier!,
                           name: $0.localizedName ?? $0.bundleIdentifier!,
                           url: $0.bundleURL,
                           isActive: $0.isActive)
            }
        runningIDs = Set(running.map(\.id))
    }

    public func isRunning(bundleID: String) -> Bool {
        !bundleID.isEmpty && runningIDs.contains(bundleID)
    }

    /// Apps that are running but not pinned to the given profile - the shelf
    /// shows these after a separator, exactly like Apple's Dock.
    public func unpinned(from items: [DockItem]) -> [RunningApp] {
        let pinned = Set(items.compactMap { item -> String? in
            if case .app(_, let bundleID, _) = item { return bundleID }
            return nil
        })
        return running.filter { !pinned.contains($0.id) }
    }

    public func icon(for url: URL) -> NSImage {
        let key = url.path(percentEncoded: false)
        if let cached = iconCache[key] { return cached }
        let icon = Self.trashIcon(for: url) ?? NSWorkspace.shared.icon(forFile: key)
        icon.size = NSSize(width: 128, height: 128)
        iconCache[key] = icon
        return icon
    }

    /// The Trash needs asking for by name.
    ///
    /// `NSWorkspace.icon(forFile:)` cannot see inside `~/.Trash` without Full
    /// Disk Access, and rather than failing it returns a generic document
    /// icon, which is worse than an error because it looks deliberate. The
    /// named system image is not behind any permission.
    ///
    /// Always the empty can, whatever is in there. Telling full from empty
    /// means listing the directory, and that is the same Full Disk Access
    /// again: the most invasive grant macOS has, asked for so a lid can look
    /// fuller. `NSTrashEmpty` is simply what a trash can looks like, and
    /// nobody reads it as a claim that it is empty.
    static func trashIcon(for url: URL) -> NSImage? {
        guard url.standardizedFileURL == Self.trashURL else { return nil }
        return NSImage(named: NSImage.trashEmptyName)
    }

    /// nil on a system with no home Trash, which should not happen but is not
    /// worth trapping over.
    static let trashURL: URL? = try? FileManager.default.url(
        for: .trashDirectory, in: .userDomainMask, appropriateFor: nil, create: false
    ).standardizedFileURL

    public func icon(forBundleID bundleID: String) -> NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return icon(for: url)
    }

    // MARK: Actions

    public func activate(bundleID: String) -> Bool {
        guard let app = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleID).first else { return false }
        return app.activate(options: [])
    }

    /// Opens an item, reporting when the launch has settled.
    ///
    /// The completion is what stops a launch bounce. Polling for the app in
    /// `running` instead was wrong twice over: that list is filtered to
    /// `activationPolicy == .regular`, so anything that opens without
    /// registering as an ordinary app never satisfied it, and a path that
    /// fails to resolve launches nothing at all - both left the tile bouncing
    /// until its give-up timer while the app was plainly open.
    public func open(_ item: DockItem,
                     completion: (@MainActor @Sendable (Bool) -> Void)? = nil) {
        func done(_ ok: Bool) { completion?(ok) }

        switch item {
        case .app(_, let bundleID, let ref):
            // Already running? Bring it forward rather than bouncing a new launch.
            if !bundleID.isEmpty, activate(bundleID: bundleID) { return done(true) }
            guard let url = ref.resolve() else { return done(false) }
            NSWorkspace.shared.openApplication(at: url, configuration: .init()) { app, _ in
                let launched = app != nil
                Task { @MainActor in completion?(launched) }
            }
        case .folder(_, let ref, _), .file(_, let ref):
            guard let url = ref.resolve() else { return done(false) }
            NSWorkspace.shared.open(url)
            done(true)
        case .link(_, let url, _):
            NSWorkspace.shared.open(url)
            done(true)
        // A group is expanded by the shelf, not opened by the workspace.
        case .spacer, .widget, .group:
            done(false)
        }
    }

    /// Opens whatever a widget points at.
    public func open(_ target: WidgetTarget) {
        switch target {
        case .app(let bundleID):
            if activate(bundleID: bundleID) { return }
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            else { return }
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        case .settings:
            guard let url = target.settingsURL else { return }
            NSWorkspace.shared.open(url)
        }
    }

    /// Asks an app to quit, the way the Dock's own menu does.
    ///
    /// `terminate()` rather than `forceTerminate()`: a document with unsaved
    /// changes must still get its chance to object.
    public func quit(bundleID: String) {
        for running in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) {
            running.terminate()
        }
    }

    /// Empties the Trash by asking Finder, the way the Dock's own menu does.
    ///
    /// Through Finder rather than deleting the files: listing `~/.Trash` needs
    /// Full Disk Access, and Finder also empties the Trash on every mounted
    /// volume, plays the sound and handles locked items. The cost is one
    /// Automation prompt for Finder, the first time. Finder's scripted empty
    /// does not ask first, so the caller confirms before this runs.
    public func emptyTrash() {
        DispatchQueue.global(qos: .userInitiated).async {
            var error: NSDictionary?
            NSAppleScript(source: "tell application id \"com.apple.finder\" to empty trash")?
                .executeAndReturnError(&error)
            // -1743: Automation for Finder is off. Silence would read as the
            // menu item being broken, so go where it can be turned on.
            guard (error?[NSAppleScript.errorNumber] as? Int) == -1743 else { return }
            DispatchQueue.main.async {
                guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")
                else { return }
                NSWorkspace.shared.open(url)
            }
        }
    }

    public func reveal(_ item: DockItem) {
        guard let url = item.fileRef?.resolve() else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
