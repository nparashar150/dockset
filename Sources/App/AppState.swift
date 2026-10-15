import SwiftUI
import AppKit
import Observation

/// The single source of truth.
///
/// Owns the persisted state, the 1s tick that drives time-based widgets, and
/// the one path through which Apple's Dock is ever written.
@MainActor
@Observable
public final class AppState {

    public var state: PersistedState {
        didSet {
            scheduleSave()
            // Saving is not applying. Settings wrote straight into this and
            // nothing told the shelf, so auto-hide, the display pin and the
            // desktop-widget level all sat in the file doing nothing until
            // some unrelated event happened to refresh the shelf: a screen
            // change, a menu bar action, or a relaunch.
            //
            // Skipped while the grip is dragging. That writes a new scale on
            // every pointer event, and re-placing the window under each one
            // fights the resize it is reporting.
            guard !ShelfResize.isDragging else { return }
            if state.customDock != oldValue.customDock || state.setup != oldValue.setup {
                onShelfSettingsChanged?()
            }
            if state.menuBar != oldValue.menuBar || state.setup != oldValue.setup {
                onMenuBarSettingsChanged?()
            }
            if state.appearance != oldValue.appearance {
                onAppearanceChanged?()
            }
            if state.timer != oldValue.timer {
                onTimerChanged?(state.timer)
            }
            if shortcuts != oldValue.shortcuts {
                onShortcutsChanged?(shortcuts)
            }
            // A panel open on a widget that has just left the shelf. Removing
            // one goes through the shelf's menu, the Settings list, a drag
            // off the shelf or a change of layout, and every one of them
            // lands here, so this is the one place that sees them all. The
            // panel used to stay up pointing at nothing, still answering
            // clicks for a widget that no longer existed.
            if let open = WidgetDetailWindow.shared.openWidgetID,
               !effectiveItems.contains(where: { $0.widget?.id == open }) {
                WidgetDetailWindow.shared.close()
            }
        }
    }

    /// Called when a setting the shelf draws from changes.
    @ObservationIgnored public var onShelfSettingsChanged: (@MainActor () -> Void)?
    /// The same for the status item, whose icon and label both used to wait
    /// for a relaunch, and for the app's appearance.
    @ObservationIgnored public var onMenuBarSettingsChanged: (@MainActor () -> Void)?
    @ObservationIgnored public var onAppearanceChanged: (@MainActor () -> Void)?
    /// The Focus Timer settings, which the widgets read through their own
    /// shared provider rather than from here.
    @ObservationIgnored public var onTimerChanged: (@MainActor (TimerState) -> Void)?
    /// Every layout's hot key, for the registry that listens for them.
    @ObservationIgnored public var onShortcutsChanged: (@MainActor ([UUID: KeyCombo]) -> Void)?

    public var shortcuts: [UUID: KeyCombo] { state.shortcuts }

    /// Gives `profileID` a hot key, taking it from any layout that had it:
    /// two layouts must never answer one combination.
    public func setShortcut(_ combo: KeyCombo?, for profileID: UUID) {
        for index in state.profiles.indices {
            if state.profiles[index].id == profileID {
                state.profiles[index].shortcut = combo
            } else if combo != nil, state.profiles[index].shortcut == combo {
                state.profiles[index].shortcut = nil
            }
        }
    }

    /// Ticks once a second. Widgets read this rather than each starting a
    /// timer of their own - one timer for the whole shelf.
    public private(set) var now: Date = .now

    /// Set when applying a macOS Dock layout fails, for the menu bar to surface.
    public private(set) var lastError: String?
    public private(set) var isApplying = false

    private let store: Store
    private let nativeDock = NativeDockAdapter()
    private var saveTask: Task<Void, Never>?
    /// Holds `self` weakly and exits on its own once AppState goes away, so
    /// there is nothing for a deinit to tear down (and Swift 6 would not let
    /// a deinit touch these anyway).
    private var tickTask: Task<Void, Never>?

    public init() {
        self.store = Store()
        self.state = store.load()
        startTicking()
    }

    /// Reads and writes somewhere other than the user's own setup.
    ///
    /// For the shot renderer, which needs a shelf full of widgets to
    /// photograph and must not build it out of, or on top of, whatever the
    /// person running it actually has.
    public init(store: Store) {
        self.store = store
        self.state = store.load()
        startTicking()
    }

    // MARK: Lifecycle

    private func startTicking() {
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                self.now = .now
            }
        }
    }

    /// Coalesces the writes that a slider drag would otherwise produce sixty
    /// times a second.
    private func scheduleSave() {
        saveTask?.cancel()
        // Snapshotted *after* the wait, not before it. Copying the whole model
        // up front costs a deep copy of every profile, item and config on each
        // mutation - and a grip drag mutates dozens of times a second, so the
        // resize paid for a full copy per event and dropped frames for it.
        saveTask = Task { [store, weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self else { return }
            try? store.save(self.state)
        }
    }

    public func saveNow() {
        saveTask?.cancel()
        try? store.save(state)
    }

    // MARK: Profiles

    public var customProfile: DockProfile? { state.activeCustomProfile }
    public var macOSProfile: DockProfile? { state.activeMacOSProfile }

    public func profiles(of kind: ProfileKind) -> [DockProfile] { state.profiles(of: kind) }

    @discardableResult
    public func addProfile(kind: ProfileKind, name: String, color: PaletteColor = .blue) -> DockProfile {
        let profile = DockProfile(kind: kind, name: name, color: color)
        state.profiles.append(profile)
        if kind == .customDock, state.customDock.profileID == nil {
            select(profile)
        }
        return profile
    }

    public func rename(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = index(of: id) else { return }
        state.profiles[index].name = trimmed
    }

    public func delete(_ id: UUID) {
        state.profiles.removeAll { $0.id == id }
        if state.customDock.profileID == id { state.customDock.profileID = nil }
        if state.macOSDock.profileID == id { state.macOSDock.profileID = nil }
    }

    public func duplicate(_ id: UUID) {
        guard let source = state.profile(id) else { return }
        var copy = source
        copy.id = UUID()
        copy.name = "\(source.name) copy"
        copy.shortcut = nil          // two profiles must never claim one hotkey
        state.profiles.append(copy)
    }

    /// Selecting a Custom Dock profile adopts its scale - size travels with
    /// the profile, which is what makes a "big shelf for work, small for
    /// everything else" setup possible.
    public func select(_ profile: DockProfile) {
        switch profile.kind {
        case .customDock:
            state.customDock.profileID = profile.id
            state.customDock.scale = profile.scale
        case .macOSDock:
            state.macOSDock.profileID = profile.id
        }
    }

    private func index(of id: UUID) -> Int? {
        state.profiles.firstIndex { $0.id == id }
    }

    // MARK: Items

    /// Editing the list takes ownership of it first.
    ///
    /// While mirroring, `effectiveItems` drops every app the profile holds and
    /// substitutes the real Dock's - so appending an app to the profile was
    /// filtered straight back out and removing one touched an array the shelf
    /// was not reading. Both looked like the buttons did nothing.
    public func addItem(_ item: DockItem, to profileID: UUID? = nil) {
        if profileID == nil, mirroringApps { adoptSystemApps() }
        let target = profileID ?? state.customDock.profileID
        guard let target, let index = index(of: target) else { return }
        state.profiles[index].items.append(item)
    }

    // MARK: Profiles

    /// Adds an empty profile and makes it the active one for its surface.
    ///
    /// Profiles are the app's central idea and none of this was reachable:
    /// the model could create, rename and delete them, and no control
    /// anywhere did. The only way to get a second one was to capture Apple's
    /// Dock, which always made another called "Current Dock".
    @discardableResult
    public func createProfile(kind: ProfileKind, named name: String) -> DockProfile {
        let profile = DockProfile(kind: kind, name: uniqueName(name))
        state.profiles.append(profile)
        switch kind {
        case .customDock: state.customDock.profileID = profile.id
        case .macOSDock: state.macOSDock.profileID = profile.id
        }
        return profile
    }

    public func renameProfile(_ id: UUID, to name: String) {
        guard let index = index(of: id) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        state.profiles[index].name = uniqueName(trimmed, excluding: id)
    }

    /// Copies a profile, including everything on it.
    @discardableResult
    public func duplicateProfile(_ id: UUID) -> DockProfile? {
        guard let index = index(of: id) else { return nil }
        var copy = state.profiles[index]
        copy.id = UUID()
        copy.name = uniqueName("\(copy.name) copy")
        // Fresh identities throughout, or the copy and the original would
        // share item ids and editing one would move things on the other.
        copy.items = copy.items.map(Self.reidentified)
        state.profiles.insert(copy, at: index + 1)
        return copy
    }

    /// Deletes a profile, moving whichever surface was using it to another.
    ///
    /// The last custom profile cannot go: the shelf has to point at
    /// something, and deleting it would leave an empty shelf with no way to
    /// get a profile back.
    public func deleteProfile(_ id: UUID) {
        guard let index = index(of: id) else { return }
        let kind = state.profiles[index].kind
        let siblings = state.profiles.filter { $0.kind == kind && $0.id != id }
        guard kind == .macOSDock || !siblings.isEmpty else { return }

        state.profiles.remove(at: index)
        if state.customDock.profileID == id { state.customDock.profileID = siblings.first?.id }
        // A macOS Dock profile may go to nothing, which is the documented
        // "leave the live Dock completely alone" state.
        if state.macOSDock.profileID == id { state.macOSDock.profileID = nil }
    }

    /// Whether deleting this one is allowed, for a control to grey itself out.
    public func canDeleteProfile(_ id: UUID) -> Bool {
        guard let profile = state.profile(id) else { return false }
        if profile.kind == .macOSDock { return true }
        return state.profiles.contains { $0.kind == .customDock && $0.id != id }
    }

    /// "Current Dock", then "Current Dock 2", and so on.
    ///
    /// Capture used to make another profile with the identical name every
    /// time, silently, and nothing could rename or remove the duplicates.
    private func uniqueName(_ wanted: String, excluding: UUID? = nil) -> String {
        let taken = Set(state.profiles.filter { $0.id != excluding }.map(\.name))
        guard taken.contains(wanted) else { return wanted }
        var n = 2
        while taken.contains("\(wanted) \(n)") { n += 1 }
        return "\(wanted) \(n)"
    }

    private static func reidentified(_ item: DockItem) -> DockItem {
        switch item {
        case .app(_, let bundleID, let ref):
            return .app(id: UUID(), bundleID: bundleID, ref: ref)
        case .folder(_, let ref, let icon):
            return .folder(id: UUID(), ref: ref, icon: icon)
        case .file(_, let ref):
            return .file(id: UUID(), ref: ref)
        case .link(_, let url, let title):
            return .link(id: UUID(), url: url, title: title)
        case .spacer(_, let size):
            return .spacer(id: UUID(), size: size)
        case .widget(let widget):
            var copy = widget
            copy.id = UUID()
            return .widget(copy)
        case .group(let group):
            var copy = group
            copy.id = UUID()
            copy.items = copy.items.map(reidentified)
            return .group(copy)
        }
    }

    /// Puts an item directly after another one.
    ///
    /// Appending is wrong for a spacer, whose entire purpose is to sit between
    /// two particular things. Falls back to appending when the anchor is not
    /// in the profile, which happens for a running app that was never pinned.
    public func insertItem(_ item: DockItem, after anchorID: UUID) {
        if mirroringApps { adoptSystemApps() }
        guard let target = state.customDock.profileID, let index = index(of: target) else { return }
        if let slot = state.profiles[index].items.firstIndex(where: { $0.id == anchorID }) {
            state.profiles[index].items.insert(item, at: slot + 1)
        } else {
            state.profiles[index].items.append(item)
        }
    }

    /// Replaces an item in place, keeping its position on the shelf.
    public func replaceItem(_ itemID: UUID, with item: DockItem) {
        if mirroringApps { adoptSystemApps() }
        guard let target = state.customDock.profileID, let index = index(of: target),
              let slot = state.profiles[index].items.firstIndex(where: { $0.id == itemID })
        else { return }
        state.profiles[index].items[slot] = item
    }

    /// Drops one item onto another. See `ShelfItems.combining`.
    public func combine(_ itemID: UUID, into targetID: UUID, named name: String) {
        mutateItems { ShelfItems.combining(itemID, into: targetID, named: name, in: $0) }
    }

    /// Takes an item out of a group. See `ShelfItems.removingFromGroup`.
    public func removeFromGroup(_ itemID: UUID, group groupID: UUID, at destination: Int? = nil) {
        mutateItems {
            ShelfItems.removingFromGroup(itemID, group: groupID, in: $0, at: destination)
        }
    }

    /// Editing the shelf's own list always takes ownership of it first.
    private func mutateItems(_ transform: ([DockItem]) -> [DockItem]) {
        if mirroringApps { adoptSystemApps() }
        guard let profile = state.customDock.profileID, let index = index(of: profile)
        else { return }
        state.profiles[index].items = transform(state.profiles[index].items)
    }

    /// Spills a group's contents back onto the shelf, in its place.
    public func ungroup(_ groupID: UUID) {
        if mirroringApps { adoptSystemApps() }
        guard let target = state.customDock.profileID, let index = index(of: target),
              let slot = state.profiles[index].items.firstIndex(where: { $0.id == groupID }),
              let group = state.profiles[index].items[slot].group
        else { return }
        state.profiles[index].items.replaceSubrange(slot...slot, with: group.items)
    }

    /// Every group on the shelf, for "Add to Group".
    public var groups: [DockGroup] { effectiveItems.compactMap(\.group) }

    public func removeItem(_ itemID: UUID, from profileID: UUID? = nil) {
        if profileID == nil, mirroringApps { adoptSystemApps() }
        let target = profileID ?? state.customDock.profileID
        guard let target, let index = index(of: target) else { return }
        state.profiles[index].items.removeAll { $0.id == itemID }
    }

    public func moveItem(from source: Int, to destination: Int, in profileID: UUID? = nil) {
        let target = profileID ?? state.customDock.profileID
        guard let target, let index = index(of: target) else { return }
        var items = state.profiles[index].items
        guard items.indices.contains(source) else { return }
        let clamped = min(max(destination, 0), items.count - 1)
        guard clamped != source else { return }
        let moved = items.remove(at: source)
        items.insert(moved, at: clamped)
        state.profiles[index].items = items
    }

    public func updateWidget(_ instance: WidgetInstance, in profileID: UUID? = nil) {
        let target = profileID ?? state.customDock.profileID
        guard let target, let pIndex = index(of: target),
              let iIndex = state.profiles[pIndex].items.firstIndex(where: { $0.id == instance.id })
        else { return }
        state.profiles[pIndex].items[iIndex] = .widget(instance)
    }

    // MARK: Effective appearance

    /// These read through to the real Dock while `followSystemDock` is on,
    /// rather than copying its values into our state. One source of truth
    /// means there is no sync to get wrong when the user drags the Dock size
    /// slider in System Settings.
    private var system: SystemDockSettings { .shared }
    private var following: Bool { state.customDock.followSystemDock }
    /// Whether the shelf's *apps* come from the real Dock. Settings can keep
    /// following after the user has taken the list over.
    private var mirroringApps: Bool { following && (state.customDock.mirrorSystemApps ?? true) }

    public var isFollowingDock: Bool { following }
    public var isMirroringApps: Bool { mirroringApps }

    /// Which edge the shelf sits on.
    ///
    /// While following, it takes a *free* edge rather than the Dock's own.
    /// Two shelves on one edge share a reveal trigger and an auto-hide timer,
    /// so they uncover each other and stack - the shelf is far more useful
    /// beside the Dock than on top of it. Everything else about the look
    /// (size, magnification, material, apps) is still mirrored.
    public var effectivePosition: DockPosition {
        // Following means taking the edge Apple's Dock is *not* on, so the
        // two surfaces do not stack. That is right while both are on screen
        // and exactly wrong once the shelf has replaced the Dock.
        //
        // In `customReplacement` the shelf covers the Dock rather than
        // avoiding it, and the Dock is moved to the shelf's edge to reserve
        // the strip: `syncStrut` claims at this very property. So following
        // here is the shelf chasing a move it caused. Claiming put the Dock
        // at the bottom, this read the Dock at the bottom and sent the shelf
        // to the left, off the strip it had just claimed, which is how the
        // shelf ended up standing on its end away from the Dock it was
        // supposed to be covering.
        //
        // Size, magnification and hiding still follow; it is only the edge
        // that cannot, because the edge is the thing being dictated.
        guard following, state.setup != .customReplacement else {
            return state.customDock.position
        }
        return system.position == .bottom ? .left : .bottom
    }

    public var effectiveScale: Double {
        DockFollowing.scale(overridden: state.customDock.scaleOverridden == true,
                            custom: state.customDock.scale,
                            system: system.matchedScale,
                            following: following)
    }

    public var effectiveAutoHide: Bool {
        following ? system.autoHide : state.customDock.autoHide
    }

    public var magnificationEnabled: Bool {
        following ? system.magnification : state.customDock.magnification
    }

    public var magnificationPeak: Double {
        following ? system.magnificationPeak : Geometry.magnificationPeak
    }

    public var magnificationRadius: Double {
        following ? system.magnificationRadius : Geometry.magnificationRadius
    }

    /// What the shelf actually shows.
    ///
    /// While following, the apps come straight from the real Dock and the
    /// profile contributes everything the Dock cannot hold - widgets, folders,
    /// files and links. That way the shelf is the user's Dock *plus* the
    /// things they came to Docket for, with nothing to keep in sync by hand.
    public var effectiveItems: [DockItem] {
        guard mirroringApps, let profile = customProfile else {
            return customProfile?.items ?? []
        }
        return ShelfItems.displayed(profile: profile.items,
                                    mirrored: system.pinnedApps,
                                    mirroring: true)
    }

    /// Whether the shelf holds any widget.
    ///
    /// Asked once per tile per render, through `iconGeometry` - so it must not
    /// build `effectiveItems`, which allocates two fresh arrays every call and
    /// turned the layout solve into O(n²) on every pointer move. Widgets only
    /// ever come from the profile; the mirrored list is apps by construction.
    public var hasWidgets: Bool {
        customProfile?.items.contains(where: \.isWidget) ?? false
    }

    /// True when this item came from the real Dock rather than the profile.
    public func isMirrored(_ item: DockItem) -> Bool {
        guard mirroringApps, case .app = item else { return false }
        return system.pinnedApps.contains { $0.id == item.id }
    }

    /// Take ownership of the mirrored Dock apps so they can be rearranged.
    ///
    /// Freezes exactly what is on screen rather than rebuilding the order, so
    /// nothing jumps at the moment the user starts dragging.
    public func adoptSystemApps() {
        guard let id = state.customDock.profileID, let index = self.index(of: id) else { return }
        let displayed = effectiveItems          // must be read while still mirroring
        state.customDock.mirrorSystemApps = false
        state.profiles[index].items = displayed
    }

    /// Whether the shelf is holding its own copy of the Dock's apps.
    public var hasAdoptedApps: Bool { following && state.customDock.mirrorSystemApps == false }

    /// Hand the app list back to the real Dock.
    ///
    /// The counterpart to `adoptSystemApps`, which had none: taking the list
    /// over happened implicitly on the first drag, and nothing anywhere turned
    /// it back on, so rearranging one icon stopped the shelf tracking the Dock
    /// for good.
    ///
    /// Undoing it has to remove the copies as well as flip the flag, or the
    /// adopted apps and the mirrored ones would both be shown and every app
    /// would appear twice. Matched by bundle identifier against what the Dock
    /// currently pins, so an app the user added themselves, and which the Dock
    /// does not have, survives.
    public func resumeMirroringApps() {
        guard let id = state.customDock.profileID, let index = self.index(of: id) else { return }
        func bundleID(_ item: DockItem) -> String? {
            if case .app(_, let bundleID, _) = item, !bundleID.isEmpty { return bundleID }
            return nil
        }
        let pinned = Set(system.pinnedApps.compactMap(bundleID))
        state.profiles[index].items.removeAll { pinned.contains(bundleID($0) ?? "") }
        state.customDock.mirrorSystemApps = true
    }

    /// Applies a displayed ordering back to the active profile.
    ///
    /// Reordering has to work by identity, not by index: while mirroring, the
    /// shelf shows the profile's own items *plus* the Dock's apps, so a
    /// position on screen has no relationship to a position in the profile's
    /// array. Indexing into it moved the wrong item.
    public func reorder(_ displayed: [UUID]) {
        guard let id = state.customDock.profileID, let index = self.index(of: id) else { return }
        state.profiles[index].items = Reorder.apply(order: displayed,
                                                    to: state.profiles[index].items)
    }

    // MARK: Size

    /// Writes through to the active profile so the size sticks to it, not to
    /// the app.
    public func setScale(_ scale: Double) {
        // An override of the size alone. Everything else - edge, hiding,
        // magnification - keeps following the real Dock.
        state.customDock.scaleOverridden = true
        let clamped = Geometry.clamp(scale, Geometry.scaleRange)
        state.customDock.scale = clamped
        if let id = state.customDock.profileID, let index = index(of: id) {
            state.profiles[index].scale = clamped
        }
    }

    /// Whether the shelf's size is the user's rather than the Dock's.
    public var isScaleOverridden: Bool { following && state.customDock.scaleOverridden == true }

    /// Go back to taking the size from the real Dock.
    ///
    /// `setScale` had no counterpart, so dragging the grip once stopped the
    /// shelf matching the Dock's size permanently, with nothing in the app
    /// able to undo it. The stored size is deliberately left alone: it is what
    /// the shelf goes back to if following is turned off later, and throwing
    /// it away would make this button destructive rather than reversible.
    public func resumeFollowingScale() {
        state.customDock.scaleOverridden = false
    }

    /// Makes the shelf's settings its own, starting from what it is showing.
    ///
    /// Matching Apple's Dock is where a shelf starts, not a mode that hides
    /// its controls: every setting is always there, and changing one while
    /// matching first copies the values in use, so the shelf does not jump
    /// to stale stored ones, and then stops matching.
    public func takeOverFromSystemDock() {
        guard state.customDock.followSystemDock else { return }
        var dock = state.customDock
        dock.position = effectivePosition
        dock.autoHide = effectiveAutoHide
        dock.magnification = magnificationEnabled
        dock.scale = effectiveScale
        dock.scaleOverridden = false
        dock.followSystemDock = false
        state.customDock = dock
    }

    // MARK: Apple's Dock

    /// Captures the live Dock into a new profile without changing anything.
    @discardableResult
    public func captureCurrentDock(named name: String = "Current Dock") async -> DockProfile? {
        do {
            let tiles = try await nativeDock.capture()
            // Remember the very first capture as the user's original layout,
            // so there is always a way back to what they had before Docket.
            if state.originalMacOSDock == nil { state.originalMacOSDock = tiles }
            // Numbered rather than identical. Capturing twice used to make two
            // profiles with the same name, silently, and nothing could tell
            // them apart or remove either.
            var profile = DockProfile(kind: .macOSDock, name: uniqueName(name))
            profile.items = tiles.compactMap(Self.item(from:))
            state.profiles.append(profile)
            state.macOSDock.profileID = profile.id
            return profile
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    /// The only place Apple's Dock is ever written.
    public func applyMacOSProfile() async {
        guard let profile = state.activeMacOSProfile, !isApplying else { return }
        isApplying = true
        defer { isApplying = false }
        let tiles = profile.applicableItems.compactMap(Self.tile(from:))
        do {
            try await nativeDock.apply(tiles)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Puts back whatever the user had before Docket first wrote to the Dock.
    /// Hides Apple's Dock entirely, or brings it back.
    public func setHideAppleDock(_ hide: Bool) {
        state.hideAppleDock = hide
        applyAppleDockVisibility()
    }

    /// Makes the Dock's visibility match `hideAppleDock`.
    ///
    /// Not while the shelf is borrowing the Dock's strip ("Shelf only"): that
    /// works by keeping the Dock showing behind the shelf, and hiding it would
    /// collapse the strip the shelf stands in. Settings disables the switch
    /// there, and this refuses it too, for a state file that asks anyway.
    public func applyAppleDockVisibility() {
        if state.hideAppleDock, state.hiddenDockPrefs == nil, state.borrowedDockPrefs == nil {
            state.hiddenDockPrefs = DockStrut.hideCompletely()
        } else if !state.hideAppleDock, let snapshot = state.hiddenDockPrefs {
            state.hiddenDockPrefs = nil
            DockStrut.restoreVisibility(snapshot)
        }
        SystemDockSettings.shared.refresh()
    }

    public func restoreOriginalDock() async {
        guard let original = state.originalMacOSDock else { return }
        isApplying = true
        defer { isApplying = false }
        do {
            try await nativeDock.apply(original)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: Tile <-> item bridging

    private static func item(from tile: MacOSDockTile) -> DockItem? {
        if tile.isSpacer {
            return .spacer(id: UUID(), size: tile.tileType == SpacerSize.small.dockTileType ? .small : .regular)
        }
        guard let urlString = tile.urlString, let url = URL(string: urlString) else { return nil }
        return .app(id: UUID(), bundleID: tile.bundleID ?? "", ref: .capture(url))
    }

    private static func tile(from item: DockItem) -> MacOSDockTile? {
        switch item {
        // Apple's Dock has no group tile, so there is nothing to mirror back.
        case .group:
            return nil
        case .spacer(_, let size):
            return .spacer(size)
        case .app(_, let bundleID, let ref):
            guard let url = ref.resolve() else { return nil }   // dead path: skip, never invent
            let label = url.deletingPathExtension().lastPathComponent
            return .app(url: url, bundleID: bundleID.isEmpty ? nil : bundleID, label: label)
        case .folder, .file, .link, .widget:
            return nil                                           // not representable in Apple's Dock
        }
    }

    public func clearError() { lastError = nil }

    // MARK: First run

    /// A brand-new install gets a shelf with something on it.
    ///
    /// An empty shelf reads as broken, and "add your first widget" is a worse
    /// introduction than simply showing what the thing does. Everything here
    /// is removable.
    public func installDefaultProfile() {
        guard state.profiles.isEmpty else { return }
        var profile = DockProfile(kind: .customDock, name: "Everyday", color: .blue)

        for bundleID in ["com.apple.finder", "com.apple.Safari", "com.apple.mail"] {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { continue }
            profile.items.append(.app(id: UUID(), bundleID: bundleID, ref: .capture(url)))
        }
        profile.items.append(.spacer(id: UUID(), size: .small))
        for kind in [WidgetKind.clock, .system, .battery] {
            if let widget = WidgetCatalog.make(kind) { profile.items.append(.widget(widget)) }
        }

        state.profiles.append(profile)
        state.customDock.profileID = profile.id
        state.customDock.scale = profile.scale
    }
}
