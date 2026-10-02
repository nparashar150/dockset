import AppKit
import SwiftUI

/// A plain window host for a SwiftUI view.
///
/// The shelf lives in a non-activating `NSPanel`, which cannot present sheets
/// - a `.sheet` attached to it silently does nothing. Anything modal-ish
/// therefore needs a real window of its own.
@MainActor
class HostedWindow {
    var window: NSWindow?

    /// - Parameter chromeless: presents a floating rounded panel with no
    ///   system title bar, the way the shipped app's widget browser appears.
    ///   The view must then supply its own header and close control.
    func present(_ view: some View, title: String, size: NSSize,
                 resizable: Bool = false, chromeless: Bool = false) {
        if let window {
            raise(window)
            return
        }

        let corner: CGFloat = 16
        let root: AnyView = chromeless
            ? AnyView(view.clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous)))
            : AnyView(view)

        let controller = NSHostingController(rootView: root)
        let window = NSWindow(contentViewController: controller)
        window.title = title
        window.setContentSize(size)

        if chromeless {
            // Kept `.titled` rather than `.borderless`: a borderless window
            // cannot become key, which would leave the search field dead.
            // The title bar is made invisible instead.
            window.styleMask = [.titled, .closable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                window.standardWindowButton(button)?.isHidden = true
            }
            window.isOpaque = false
            window.backgroundColor = .clear
            window.isMovableByWindowBackground = true
            window.hasShadow = true
        } else {
            window.styleMask = resizable
                ? [.titled, .closable, .miniaturizable, .resizable]
                : [.titled, .closable, .miniaturizable]
        }

        window.isReleasedWhenClosed = false
        window.center()
        self.window = window
        raise(window)
    }

    /// Brings a window to the front from an accessory app.
    ///
    /// `LSUIElement` apps are never "active" in the usual sense, so
    /// `makeKeyAndOrderFront` plus `activate()` quietly opens the window
    /// *behind* whatever the user is looking at - it exists, it is just
    /// invisible. `orderFrontRegardless` is the call that actually raises it,
    /// and a floating level keeps it from sinking again on the next click.
    private func raise(_ window: NSWindow) {
        window.level = .floating
        window.orderFrontRegardless()
        NSApp.activate()
        window.makeKey()
    }

    func close() {
        window?.close()
        window = nil
    }
}

@MainActor
final class LibraryWindow: HostedWindow {
    static let shared = LibraryWindow()

    /// Whether the library is up. The shelf stays out while it is: adding a
    /// widget is done by looking at the shelf it lands on, and an auto-hidden
    /// shelf slid away the moment the pointer went to the library to pick
    /// one, so every addition happened somewhere out of sight.
    var isOpen: Bool { window?.isVisible == true }

    func show(app: AppState) {
        present(
            WidgetLibraryView(
                onAdd: { [weak self] widget in
                    withAnimation(.snappy(duration: 0.25)) { app.addItem(.widget(widget)) }
                    // Adding is a repeated action - people add three widgets at
                    // a time - so the library stays open, like Shortcuts' own.
                    _ = self
                },
                onClose: { [weak self] in self?.close() }
            ),
            title: "Add Widget",
            size: NSSize(width: 760, height: 470),
            chromeless: true
        )
    }
}

@MainActor
final class SettingsWindow: HostedWindow {
    static let shared = SettingsWindow()

    func show(app: AppState, tab: String = "Shelf", widget: UUID? = nil) {
        // Set before presenting, so a window that is only being raised still
        // lands on the tab, and the widget, the caller asked for.
        SettingsSelection.shared.current = tab
        if let widget { SettingsSelection.shared.widget = widget }
        @Bindable var bindable = app
        present(
            SettingsView(
                state: $bindable.state,
                initialTab: tab,
                onApplyMacOSProfile: { Task { await app.applyMacOSProfile() } },
                onCaptureCurrentDock: { Task { await app.captureCurrentDock() } },
                onSetScale: { app.setScale($0) },
                onResumeFollowingScale: { app.resumeFollowingScale() },
                onResumeMirroringApps: { app.resumeMirroringApps() },
                onBackUp: { Self.backUp(app) },
                onRestore: { Self.restore(app) },
                onCreateProfile: { kind in
                    app.createProfile(kind: kind,
                                      named: kind == .customDock ? "New Shelf" : "New Dock")
                },
                onRenameProfile: { app.renameProfile($0, to: $1) },
                onDuplicateProfile: { if let id = $0 { app.duplicateProfile(id) } },
                onDeleteProfile: { if let id = $0 { app.deleteProfile(id) } },
                lastError: app.lastError,
                onClearError: { app.clearError() },
                onRestoreOriginalDock: { Task { await app.restoreOriginalDock() } },
                onSetHideAppleDock: { app.setHideAppleDock($0) }
            ),
            title: "Docket Settings",
            // Taller and resizable, because the Widgets tab is not a fixed
            // form: it grows by one section per widget on the shelf. At the
            // old fixed 520x460 a shelf with four widgets showed two of them
            // and scrolled the rest inside a box nobody could enlarge.
            // Wide enough for a sidebar and a form beside it without the
            // form's controls crowding their labels.
            size: NSSize(width: 720, height: 600),
            resizable: true
        )
    }

    // MARK: Backup

    /// Writes the profiles to a file the user picks.
    ///
    /// The panel is AppKit's rather than SwiftUI's `fileExporter`, because an
    /// accessory app has no window for a sheet to attach to: a modal panel is
    /// the only kind that reliably comes forward here.
    private static func backUp(_ app: AppState) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = Backup.suggestedName()
        panel.allowedContentTypes = []
        panel.canCreateDirectories = true
        panel.message = "Save your profiles, their items and widget settings."
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try Backup.encode(app.state).write(to: url, options: .atomic)
        } catch {
            report("Could not save the backup.", error)
        }
    }

    /// Reads a backup and merges it in.
    private static func restore(_ app: AppState) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose a Docket profiles backup."
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let payload = try Backup.decode(Data(contentsOf: url))
            var state = app.state
            let before = state.profiles.count
            Backup.merge(payload, into: &state)
            app.state = state

            let added = state.profiles.count - before
            let updated = payload.profiles.count - added
            let alert = NSAlert()
            alert.messageText = "Restored \(payload.profiles.count) profile\(payload.profiles.count == 1 ? "" : "s")."
            // Says what it did rather than just that it worked: a merge that
            // replaced something should not look identical to one that only
            // added.
            alert.informativeText = updated > 0
                ? "\(added) added, \(updated) replaced from the backup."
                : "\(added) added."
            alert.runModal()
        } catch {
            report("Could not read that backup.", error)
        }
    }

    private static func report(_ message: String, _ error: any Error) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.runModal()
    }
}
