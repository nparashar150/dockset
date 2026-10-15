import AppKit
import SwiftUI

@main
struct DocketMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // Agent app: no Dock tile of our own, no menu bar of our own. Docket's
        // only permanent UI is its status item.
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var state: AppState!
    private var shelf: DockPanelController!
    private var menuBar: MenuBarController!
    private var observation: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let state = AppState()
        self.state = state

        // A first run with nothing saved should still show something, or the
        // app looks broken. An empty shelf with a visible Add Widget affordance
        // is better than no window at all.
        state.installDefaultProfile()

        // Widgets write their own state through here - see WidgetWriter. An
        // open detail panel holds the instance by value, so it is redrawn from
        // the same funnel rather than left showing what the tile used to say.
        WidgetWriter.update = { [state] instance in
            state.updateWidget(instance)
            WidgetDetailWindow.shared.refresh(instance)
        }

        shelf = DockPanelController(app: state)
        menuBar = MenuBarController(app: state)
        menuBar.onShelfSettingsChanged = { [weak self] in self?.shelf.refresh() }
        // The Settings window writes the model directly rather than going
        // through the menu bar, so it needs the same wire.
        state.onShelfSettingsChanged = { [weak self] in self?.shelf.refresh() }
        state.onMenuBarSettingsChanged = { [weak self] in self?.menuBar.refreshButton() }
        state.onAppearanceChanged = { [weak self] in self?.applyAppearance() }
        ProfileHotkeys.shared.onFire = { [weak self] id in self?.menuBar.switchTo(id) }
        ProfileHotkeys.shared.apply(state.shortcuts)
        state.onShortcutsChanged = { ProfileHotkeys.shared.apply($0) }

        // The Focus Timer runs through a shared provider the widgets read,
        // and Settings edits the persisted copy. Neither knew about the
        // other, so the six controls in Settings changed nothing and a
        // session was forgotten on quit. Both ends are connected here.
        TimerStateProvider.shared.adopt(state.state.timer)
        TimerStateProvider.shared.onChange = { [state] timer in state.state.timer = timer }
        state.onTimerChanged = { timer in TimerStateProvider.shared.adopt(timer) }

        applyAppearance()
        if state.state.setup != .macOSDockOnly {
            shelf.show()
        }

        if ProcessInfo.processInfo.environment["PLINTH_OPEN_LIBRARY"] != nil {
            LibraryWindow.shared.show(app: state)
        }
        if let tab = ProcessInfo.processInfo.environment["PLINTH_OPEN_SETTINGS"] {
            SettingsWindow.shared.show(app: state, tab: tab.isEmpty ? "Shelf" : tab)
        }
        if ProcessInfo.processInfo.environment["PLINTH_PROBE_LOCATION"] != nil {
            SettingsWindow.shared.show(app: state)
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                LocationService.shared.start()
            }
        }
        // A recorded snapshot means a previous run changed Apple's Dock and
        // did not put it back, which is what a crash or a force quit leaves
        // behind. The debt is paid before anything else touches the Dock.
        Task { @MainActor [state] in
            await StrutMode.repayIfOwed(state: state.state,
                                        clear: { state.state.borrowedDockPrefs = nil })
            // After the strip's debt is settled, so a hidden Dock is hidden
            // over the preferences the user actually has.
            state.applyAppleDockVisibility()
        }

        startUpdateChecks(state)

        SystemDockSettings.shared.start()
        // Reads the wallpaper, not the screen, so it needs no permission.
        DesktopLuminance.shared.start()
        SystemMetrics.shared.start()
        NetworkMetrics.shared.start()
        BatteryMetrics.shared.start()

        observation = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.shelf.refresh() }
        }

        // The Dock's own preferences drive our edge, size and hiding, so
        // follow them. Through SystemDockSettings rather than by observing the
        // notification here: it is a *distributed* notification, posted by
        // another process, and the observer this used to register on
        // NotificationCenter.default could never have fired. Nothing re-placed
        // or re-hid the shelf when the Dock changed, so "Match the macOS Dock"
        // only matched it at launch.
        SystemDockSettings.shared.onChange = { [weak self] in self?.shelf.refresh() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Synchronous on purpose. Restoring the Dock means writing its
        // preferences and restarting it, and a Task would not be given the
        // time: quitting must not be how someone loses their Dock settings.
        if let borrowed = state?.state.borrowedDockPrefs {
            state?.state.borrowedDockPrefs = nil
            DockStrut.releaseNow(borrowed)
        }
        // Then the hide, which was applied first and so is undone last. The
        // choice itself is kept; the next launch hides the Dock again.
        if let hidden = state?.state.hiddenDockPrefs {
            state?.state.hiddenDockPrefs = nil
            DockStrut.restoreVisibility(hidden)
        }
        state?.saveNow()
    }

    /// Asks once, then remembers.
    ///
    /// Checking for releases is the only thing Docket does unprompted that
    /// talks to a server, and it necessarily tells GitHub that someone ran it.
    /// Everything else that leaves this machine is there because the user
    /// added a weather or stocks widget. So it is asked rather than assumed,
    /// and asked once: a nil answer means the question has not been put yet.
    ///
    /// Deferred so the question does not land while the shelf is still
    /// appearing, which would make it the first thing a new user ever sees.
    private func startUpdateChecks(_ state: AppState) {
        guard state.state.checkForUpdates != false else { return }
        if state.state.checkForUpdates == true {
            UpdateService.shared.start()
            return
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard self != nil else { return }
            let alert = NSAlert()
            alert.messageText = "Check for new versions of Docket?"
            alert.informativeText = """
                Docket can look for new releases once a day and tell you when \
                one appears, in its menu bar item. Updates are never installed \
                for you.

                Checking asks GitHub for the latest version number, and \
                nothing else is sent. You can change this in Settings.
                """
            alert.alertStyle = .informational
            alert.addButton(withTitle: "Check for Updates")
            alert.addButton(withTitle: "Don't Check")
            NSApp.activate(ignoringOtherApps: true)
            let wanted = alert.runModal() == .alertFirstButtonReturn
            state.state.checkForUpdates = wanted
            if wanted { UpdateService.shared.start() }
        }
    }

    private func applyAppearance() {
        NSApp.appearance = switch state.state.appearance {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}
