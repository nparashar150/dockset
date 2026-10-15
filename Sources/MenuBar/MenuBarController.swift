import AppKit
import SwiftUI

/// The menu bar item: the app's only persistent UI.
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let app: AppState
    var onShelfSettingsChanged: (() -> Void)?

    init(app: AppState) {
        self.app = app
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        refreshButton()
    }

    func refreshButton() {
        // The toggle was read by nothing: the status item was always created
        // and always shown. Honoured now, but never to the point of leaving
        // the app unreachable - see `canHideStatusItem`.
        statusItem.isVisible = app.state.menuBar.showIcon || !canHideStatusItem

        guard let button = statusItem.button else { return }
        button.image = NSImage(systemSymbolName: "rectangle.bottomthird.inset.filled",
                               accessibilityDescription: "Docket")
        button.image?.isTemplate = true
        button.title = labelText.isEmpty ? "" : " \(labelText)"
    }

    /// Whether there is another way into the app if the icon goes.
    ///
    /// Docket is an accessory app: no Dock tile, no window of its own. With
    /// the shelf on screen its context menu reaches Settings, so hiding the
    /// icon is recoverable. Without a shelf it is the only way in, and hiding
    /// it would strand someone in an app they can see no part of and cannot
    /// quit.
    var canHideStatusItem: Bool { app.state.setup != .macOSDockOnly }

    private var labelText: String {
        let native = app.macOSProfile?.name ?? ""
        let custom = app.customProfile?.name ?? ""
        return switch app.state.menuBar.label {
        case .none: ""
        case .native: native
        case .custom: custom
        case .both: [native, custom].filter { !$0.isEmpty }.joined(separator: " · ")
        }
    }

    // MARK: Menu

    /// Short, and in order of use.
    ///
    /// It used to open on two headed lists, "Custom Dock" and "macOS Dock",
    /// each with its own checkmark and a colour dot, which asked you to know
    /// the model before you could read the menu, and put "Restore Original
    /// Dock", which is rare and rewrites the real Dock, beside everyday
    /// actions. Each kind of layout is now one submenu that names the one in
    /// use, and the Dock's rarer tools live inside its own.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        if let error = app.lastError {
            let item = NSMenuItem(title: error, action: nil, keyEquivalent: "")
            item.image = Self.symbol("exclamationmark.triangle")
            item.isEnabled = false
            menu.addItem(item)
            menu.addItem(.separator())
        }

        let hasShelf = app.state.setup != .macOSDockOnly
        if hasShelf {
            menu.addItem(layoutMenu(.customDock, title: "Shelf Layout"))
        }
        menu.addItem(layoutMenu(.macOSDock, title: "Apple Dock Layout"))
        menu.addItem(.separator())

        // Only when there is one. An always-present "you are up to date" line
        // is a permanent reminder of something nobody needs reminding of.
        if let update = UpdateService.shared.available {
            let entry = item("Update to \(update.version)…", #selector(openUpdate),
                             symbol: "arrow.down.circle")
            menu.addItem(entry)
            menu.addItem(.separator())
        }
        if hasShelf {
            menu.addItem(item("Add Widget…", #selector(openLibrary), symbol: "plus.square"))
        }
        menu.addItem(item("Settings…", #selector(openSettings), key: ",", symbol: "gearshape"))
        menu.addItem(.separator())
        menu.addItem(item("Quit Docket", #selector(quit), key: "q", symbol: "power"))
    }

    @objc private func openUpdate() { UpdateService.shared.openReleasePage() }

    /// One kind of layout: the parent names the one in use, the submenu
    /// switches between them.
    private func layoutMenu(_ kind: ProfileKind, title: String) -> NSMenuItem {
        let profiles = app.profiles(of: kind)
        let activeID = kind == .customDock ? app.state.customDock.profileID : app.state.macOSDock.profileID
        let active = profiles.first { $0.id == activeID }?.name

        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        parent.image = Self.symbol(kind == .customDock ? "rectangle.bottomthird.inset.filled" : "dock.rectangle")
        let submenu = NSMenu()
        for profile in profiles {
            let entry = NSMenuItem(title: profile.name, action: #selector(selectProfile(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = profile.id
            entry.state = profile.id == activeID ? .on : .off
            entry.image = Self.symbol("square.stack")
            submenu.addItem(entry)
        }
        if !profiles.isEmpty { submenu.addItem(.separator()) }
        if kind == .macOSDock {
            submenu.addItem(item("Save Current Dock", #selector(captureDock), symbol: "square.and.arrow.down"))
            if app.state.originalMacOSDock != nil {
                submenu.addItem(item("Restore Original Dock", #selector(restoreDock),
                                     symbol: "arrow.uturn.backward"))
            }
            submenu.addItem(.separator())
        }
        submenu.addItem(item("Edit Layouts…", #selector(openLayouts), symbol: "slider.horizontal.3"))
        parent.submenu = submenu

        // The layout in use, greyed at the trailing edge the way a menu shows
        // a current value, so the top level still says what is active.
        if let active {
            let label = NSMutableAttributedString(string: title + "  ")
            label.append(NSAttributedString(string: active, attributes: [
                .foregroundColor: NSColor.secondaryLabelColor,
            ]))
            parent.attributedTitle = label
        }
        return parent
    }

    /// Every item carries a symbol. Only Update had one, so the menu read as
    /// a list with one decorated line rather than a set of the same thing.
    private func item(_ title: String, _ action: Selector, key: String = "",
                      symbol: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        item.image = Self.symbol(symbol)
        return item
    }

    private static func symbol(_ name: String) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        image?.isTemplate = true
        return image
    }

    // MARK: Actions

    @objc private func selectProfile(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        switchTo(id)
    }

    /// Everything choosing a layout from this menu does, for the layout hot
    /// keys to do the same.
    func switchTo(_ id: UUID) {
        guard let profile = app.state.profile(id) else { return }
        app.select(profile)
        refreshButton()
        onShelfSettingsChanged?()
        if profile.kind == .macOSDock {
            Task { await app.applyMacOSProfile() }
        }
    }

    @objc private func restoreDock() {
        Task { await app.restoreOriginalDock() }
    }

    @objc private func captureDock() {
        Task { await app.captureCurrentDock() }
    }

    @objc private func openLayouts() {
        SettingsWindow.shared.show(app: app, tab: "Layouts")
    }

    @objc private func openLibrary() {
        LibraryWindow.shared.show(app: app)
    }

    @objc private func openSettings() {
        SettingsWindow.shared.show(app: app)
    }

    @objc private func quit() {
        app.saveNow()
        NSApp.terminate(nil)
    }
}
