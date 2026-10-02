import AppKit
import SwiftUI
import Observation

/// Which Settings tab is showing.
///
/// Outside the view because the window is reused: raising an existing one
/// runs no `onAppear`, so a view holding this in `@State` could never be told
/// to go anywhere.
@MainActor @Observable
final class SettingsSelection {
    static let shared = SettingsSelection()
    var current = "Shelf"
    /// The widget the Widgets tab shows, when a caller named one. Here for the
    /// same reason as `current`: "Widget Settings…" on a shelf widget has to
    /// land on that widget even when the window is only being raised.
    var widget: UUID?
    private init() {}
}

/// Docket's Settings window.
///
/// It owns no state: the app passes a binding to the single `PersistedState`
/// it already persists, so every edit here is saved by the same code path that
/// saves everything else.
struct SettingsView: View {
    @Binding var state: PersistedState
    /// Which tab opens first. The menu bar and the Dock's own menu both land
    /// on Shelf; a caller with something specific to show can say so.
    var initialTab: String = "Shelf"
    var onApplyMacOSProfile: () -> Void
    var onCaptureCurrentDock: () -> Void
    /// Sizing the shelf goes through `AppState.setScale`, which also writes
    /// the active profile and records that the size is now the user's. The
    /// slider used to bind straight to the stored value and do neither.
    var onSetScale: (Double) -> Void
    /// Undoing that, and the same for the app list. Both overrides used to be
    /// one directional, with nothing in the app able to clear them.
    var onResumeFollowingScale: () -> Void
    var onResumeMirroringApps: () -> Void
    /// Stops matching Apple's Dock, keeping the values in use. See
    /// `AppState.takeOverFromSystemDock`.
    var onTakeOver: () -> Void = {}
    /// What the shelf is actually using, which while matching comes from
    /// Apple's Dock rather than from the stored settings.
    var inUse: () -> (position: DockPosition, autoHide: Bool, magnification: Bool) = {
        (.bottom, false, false)
    }
    /// Both present a file panel, which is AppKit's job rather than a view's.
    var onBackUp: () -> Void
    var onRestore: () -> Void
    /// Profile management. Through closures for the same reason as the rest:
    /// this view owns no state and every one of these has to reach AppState,
    /// which also decides what is allowed.
    var onCreateProfile: (ProfileKind) -> Void
    var onRenameProfile: (UUID, String) -> Void
    var onDuplicateProfile: (UUID?) -> Void
    var onDeleteProfile: (UUID?) -> Void
    /// The last Dock-apply failure, and a way to be rid of it. Read rather
    /// than bound because it belongs to AppState and this view holds only the
    /// persisted state.
    var lastError: String?
    var onClearError: () -> Void
    /// Puts Apple's Dock back the way it was before Docket first wrote to it.
    /// Only offered once there is something to go back to.
    var onRestoreOriginalDock: () -> Void
    /// Hiding Apple's Dock writes its preferences and restarts it, which is
    /// AppState's to do, not this view's.
    var onSetHideAppleDock: (Bool) -> Void

    /// Which tab is showing, held outside the view.
    ///
    /// It was `@State` set from `initialTab` in `onAppear`, and `onAppear`
    /// does not fire again for a window that is merely being raised. So
    /// "Widget Settings…" opened the Widgets tab exactly once, and every time
    /// after that raised whatever tab was last looked at while claiming to go
    /// somewhere specific.
    @State private var selection = SettingsSelection.shared

    /// The size the shelf is actually drawn at, which is the Dock's while
    /// following and the stored one once overridden. Showing the stored value
    /// unconditionally meant the readout disagreed with the shelf.
    private var shownScale: Double {
        DockFollowing.scale(overridden: state.customDock.scaleOverridden == true,
                            custom: state.customDock.scale,
                            system: SystemDockSettings.shared.matchedScale,
                            following: state.customDock.followSystemDock)
    }

    /// Both overrides only mean anything while following: with following off,
    /// the shelf's size and app list are the user's by definition and there is
    /// nothing to hand back.
    private var scaleOverridden: Bool {
        state.customDock.followSystemDock && state.customDock.scaleOverridden == true
    }

    private var adoptedApps: Bool {
        state.customDock.followSystemDock && state.customDock.mirrorSystemApps == false
    }


    /// The sections, in the order the sidebar lists them.
    ///
    /// Ordered by how often each is wanted. The shelf is what people come
    /// here to change; General, which used to open first, held the setup and
    /// the profiles, the two least general things in the app, under a name
    /// that promised neither. Plain glyphs rather than tinted tiles: four
    /// rows need no colour to be told apart, and the tiles made a small
    /// window read as a phone's settings screen.
    private static let sections: [(id: String, title: String, symbol: String)] = [
        ("Shelf", "Shelf", "rectangle.bottomthird.inset.filled"),
        ("Widgets", "Widgets", "square.grid.2x2"),
        ("Layouts", "Layouts", "square.stack.3d.up"),
        ("General", "General", "gearshape"),
    ]

    var body: some View {
        // A sidebar rather than a segmented strip along the top: a strip
        // says nothing about where you are in a scroll, and it cannot grow.
        NavigationSplitView {
            List(selection: Binding(
                get: { selection.current },
                set: { selection.current = $0 ?? "Shelf" })) {
                ForEach(Array(Self.sections.enumerated()), id: \.element.id) { index, section in
                    Label(section.title, systemImage: section.symbol)
                        .tag(section.id)
                        .staggered(index, step: 0.05)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 150, ideal: 160, max: 200)
        } detail: {
            pane
                // Opens at the top. The Shelf pane landed scrolled past its
                // own setup cards, onto whichever control took focus.
                .defaultScrollAnchor(.top)
                // Keyed on the section, so switching sections replays the
                // stagger instead of swapping a finished pane for another
                // finished pane.
                .id(selection.current)
                .navigationTitle(Self.sections.first { $0.id == selection.current }?.title ?? "Settings")
        }
        // A minimum rather than a fixed size: the window is resizable, and a
        // hard frame here would win against it.
        .frame(minWidth: 640, minHeight: 440)
        .onAppear { selection.current = initialTab }
    }

    @ViewBuilder private var pane: some View {
        switch selection.current {
        case "Widgets": widgets
        case "Layouts": layouts
        case "General": general
        default: shelf
        }
    }

    // MARK: - Shelf

    /// The setup first, as three pictures rather than three paragraphs: which
    /// Dock is on screen is a spatial question, and a sketch of the screen
    /// answers it before the caption is read. With no shelf, nothing below
    /// it applies, so nothing below it is shown.
    private var shelf: some View {
        Form {
            Section {
                HStack(spacing: 10) {
                    ForEach(DockSetup.allCases, id: \.self) { setup in
                        ChoiceCard(title: title(setup), caption: detail(setup),
                                   selected: state.setup == setup) {
                            withAnimation(.smooth(duration: 0.2)) { state.setup = setup }
                        } picture: {
                            SetupSketch(setup: setup).frame(height: 58)
                        }
                    }
                }
                .padding(.vertical, 2)
            }

            if state.setup == .macOSDockOnly {
                Section {
                    Text("The shelf is off. Apple's Dock layouts are under Layouts.")
                        .foregroundStyle(.secondary)
                }
            } else {
                shelfSections
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Layouts

    /// Every saved layout, for both Docks, as lists you act on in place.
    ///
    /// These were a picker, a name field and a row of buttons per kind, which
    /// is the model's API drawn as a form: you had to pick a layout in one
    /// control to rename it in a second and delete it with a third. Now each
    /// layout is a row: click to use it, type to rename it, and its menu does
    /// the rest.
    private var layouts: some View {
        Form {
            layoutList(.customDock, title: "Shelf",
                       selection: $state.customDock.profileID, allowsNone: false)
                .disabled(state.setup == .macOSDockOnly)

            layoutList(.macOSDock, title: "Apple Dock",
                       selection: $state.macOSDock.profileID, allowsNone: true)

            Section {
                Toggle(isOn: Binding(get: { state.hideAppleDock }, set: onSetHideAppleDock)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Hide Apple's Dock")
                        Text(state.setup == .customReplacement
                             ? "Shelf only keeps the Dock behind the shelf to hold its place, so it cannot be hidden there."
                             : "It never appears, even at the screen edge. Turn this off to bring it back.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(state.setup == .customReplacement)

                HStack {
                    Button("Apply to Dock", action: onApplyMacOSProfile)
                        .disabled(state.activeMacOSProfile == nil)
                        .help("Write the selected layout to Apple's Dock.")
                    Button("Save Current Dock", action: onCaptureCurrentDock)
                        .help("Save Apple's Dock as it is right now as a new layout.")
                    Spacer()
                    if state.originalMacOSDock != nil {
                        Button("Restore Original", action: onRestoreOriginalDock)
                            .help("Put Apple's Dock back the way it was before Docket first changed it.")
                    }
                }

                // In the window holding the button that caused it, so pressing
                // Apply and having nothing happen does not look like a broken
                // button, and dismissable, so it does not describe something
                // that happened once for ever.
                if let failure = lastError {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(failure)
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        Button("Dismiss", action: onClearError)
                            .buttonStyle(.link)
                    }
                }
            }

            Section {
                HStack {
                    Button("Back Up…", action: onBackUp)
                        .disabled(state.profiles.isEmpty)
                    Button("Restore…", action: onRestore)
                }
            } header: {
                Text("Backup")
            } footer: {
                Text("A backup holds your layouts, their items and widget settings, not the apps or files they point to. Restoring adds to what you have rather than replacing it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func layoutList(_ kind: ProfileKind, title: String,
                            selection: Binding<UUID?>, allowsNone: Bool) -> some View {
        let mine = state.profiles(of: kind)
        Section {
            // "None" is the documented "leave the live Dock completely alone"
            // state, which has to stay reachable after the first capture.
            if allowsNone {
                // Named for what it does. "None" read as an action that had
                // quietly failed: choosing it changes nothing, by design.
                LayoutRow(name: .constant("Leave the Dock as it is"), editable: false,
                          active: selection.wrappedValue == nil,
                          onUse: { selection.wrappedValue = nil }) { EmptyView() }
            }
            ForEach(mine) { profile in
                LayoutRow(
                    name: Binding(get: { profile.name },
                                  set: { onRenameProfile(profile.id, $0) }),
                    editable: true,
                    active: selection.wrappedValue == profile.id,
                    onUse: { selection.wrappedValue = profile.id },
                    onDuplicate: { onDuplicateProfile(profile.id) },
                    // The shelf has to point at something: deleting its last
                    // layout would leave it empty with no way back.
                    onDelete: kind == .customDock && mine.count <= 1
                        ? nil : { onDeleteProfile(profile.id) }) {
                    strip(profile.items)
                }
            }
        } header: {
            HStack {
                Text(title)
                Spacer()
                Button {
                    onCreateProfile(kind)
                } label: {
                    Label("New Layout", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }
        }
    }

    /// The first few things in a layout, as their icons: two layouts with
    /// similar names are told apart at a glance by what is in them.
    private func strip(_ items: [DockItem]) -> some View {
        HStack(spacing: 3) {
            ForEach(items.prefix(7)) { item in
                icon(for: item).frame(width: 18, height: 18)
            }
            if items.count > 7 {
                Text("+\(items.count - 7)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }

    // MARK: - General

    private var general: some View {
        Form {
            Section {
                HStack(spacing: 10) {
                    ForEach(AppAppearance.allCases, id: \.self) { option in
                        ChoiceCard(title: title(option), selected: state.appearance == option) {
                            state.appearance = option
                        } picture: {
                            AppearanceSketch(appearance: option).frame(height: 52)
                        }
                    }
                }
                .padding(.vertical, 2)
            }

            Section("Menu Bar") {
                // Refused when there is no shelf, because the icon is then the
                // only way into an app with no Dock tile and no window of its
                // own. Disabled and explained rather than accepted and ignored.
                Toggle("Show menu bar icon", isOn: $state.menuBar.showIcon)
                    .disabled(state.setup == .macOSDockOnly)
                    .help(state.setup == .macOSDockOnly
                          ? "With no shelf on screen, this is the only way to reach Docket."
                          : "The shelf's own menu can still reach Settings with this off.")
                Picker("Show next to it", selection: $state.menuBar.label) {
                    ForEach(MenuBarLabelMode.allCases, id: \.self) { Text(title($0)).tag($0) }
                }
            }

            Section("Updates") {
                // The consent alert promises this control exists, so it does.
                // Binding through a default of false means a state file that
                // predates the question reads as off rather than as answered.
                Toggle("Check for new versions", isOn: Binding(
                    get: { state.checkForUpdates == true },
                    set: { state.checkForUpdates = $0 }))
                    .help("Once a day, Docket asks GitHub for the latest version number and tells you in its menu bar item if it is newer. Nothing is installed for you, and nothing else is sent.")
            }

            // About, folded in. A whole section in the sidebar for an icon and
            // a version number was a fifth place to look for four things.
            Section {
                HStack(spacing: 12) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 44, height: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Docket \(shortVersion)")
                            .font(.headline)
                            .monospacedDigit()
                        Text("Everything stays on this Mac, in one file in Application Support. Nothing is synced.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .formStyle(.grouped)
    }

    private var shortVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-"
    }

    // MARK: - Shelf settings

    /// Everything about the shelf itself, shown under the setup cards while
    /// there is a shelf to set up.
    ///
    /// Four groups, each one idea: where it sits, how it looks, how it
    /// behaves, and what is on it. It was six, with a toggle, a "Currently"
    /// row and a footnote all spent on following the Dock, and two controls
    /// spent on one choice of material.
    @ViewBuilder private var shelfSections: some View {
        Section {
            Toggle(isOn: $state.customDock.followSystemDock) {
                // A starting point, not a mode that hides the shelf's own
                // settings: every one stays below, and changing any of them
                // makes the shelf's settings its own.
                subtitled("Match Apple's Dock", state.customDock.followSystemDock
                          ? "\(SystemDockSettings.shared.summary). Change anything below to set your own."
                          : "The shelf keeps its own settings.")
            }

            HStack(spacing: 10) {
                ForEach(DockPosition.allCases, id: \.self) { edge in
                    ChoiceCard(title: title(edge), selected: inUse().position == edge) {
                        onTakeOver()
                        state.customDock.position = edge
                    } picture: {
                        EdgeSketch(edge: edge).frame(height: 44)
                    }
                }
            }
            .padding(.vertical, 2)

            Picker("Display", selection: $state.customDock.displayID) {
                Text("Wherever the pointer is").tag(UInt32?.none)
                ForEach(NSScreen.screens, id: \.self) { screen in
                    if let id = screen.docketDisplayID {
                        Text(screen.localizedName).tag(UInt32?.some(id))
                    }
                }
            }

            LabeledContent("Size") {
                HStack {
                    // Through setScale, not around it. Binding straight to
                    // the stored value skipped the override flag and never
                    // wrote the profile, so the size silently reverted.
                    Slider(value: Binding(get: { shownScale },
                                          set: { onTakeOver(); onSetScale($0) }),
                           in: Geometry.scaleRange)
                    Text("\(Int((shownScale * 100).rounded()))%")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 44, alignment: .trailing)
                    // The way back from sizing the shelf with its grip while
                    // matching, beside the size it puts back rather than as a
                    // second Size row.
                    if scaleOverridden {
                        Button("Match", action: onResumeFollowingScale)
                            .controlSize(.small)
                    }
                }
            }

        }

        Section("Look") {
            // One choice, not a material and then a style of that material:
            // the three are what anyone is actually choosing between.
            // Drawn in the real materials over a scrap of wallpaper, because
            // the difference between them is only visible over something.
            HStack(spacing: 10) {
                ForEach([Look.frosted, .glass, .clear], id: \.self) { option in
                    ChoiceCard(title: option.title, selected: look.wrappedValue == option) {
                        look.wrappedValue = option
                    } picture: {
                        MaterialSample(look: option).frame(height: 52)
                    }
                }
            }
            .padding(.vertical, 2)
            .help("Reduce Transparency in Accessibility settings overrides Glass and Clear.")

            Toggle("Magnify under the pointer", isOn: Binding(
                get: { inUse().magnification },
                set: { onTakeOver(); state.customDock.magnification = $0 }))
        }

        Section("Behaviour") {
            Toggle("Hide until the pointer reaches the edge", isOn: Binding(
                get: { inUse().autoHide },
                set: { onTakeOver(); state.customDock.autoHide = $0 }))
            // Only means anything while something is hiding.
            if inUse().autoHide {
                Toggle(isOn: $state.customDock.showHandleWhenHidden) {
                    subtitled("Leave a sliver when hidden", "So you can see where it is.")
                }
            }
            Toggle(isOn: $state.customDock.hideWhenMacOSDockAppears) {
                subtitled("Make way for Apple's Dock",
                          "When both are on one edge, reaching for one uncovers the other.")
            }
            Toggle(isOn: $state.customDock.useAsDesktopWidget) {
                subtitled("Stay behind windows", "Sit on the desktop like a widget.")
            }
        }

        itemList
    }

    /// A control's label with one line of explanation under it, the way
    /// System Settings does it, in place of a tooltip nobody hovers for.
    private func subtitled(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    fileprivate enum Look: Hashable {
        case frosted, glass, clear

        var title: String {
            switch self {
            case .frosted: "Frosted"
            case .glass: "Glass"
            case .clear: "Clear"
            }
        }
    }

    private var look: Binding<Look> {
        Binding(
            get: {
                guard state.customDock.material == .liquidGlass else { return .frosted }
                return state.customDock.glass == .clear ? .clear : .glass
            },
            set: { look in
                state.customDock.material = look == .frosted ? .frosted : .liquidGlass
                if look != .frosted { state.customDock.glass = look == .clear ? .clear : .regular }
            })
    }

    // MARK: - Widgets

    /// Whether any widget on the active shelf is a Focus Timer.
    private var hasFocusTimer: Bool {
        guard let id = state.customDock.profileID,
              let profile = state.profiles.first(where: { $0.id == id })
        else { return false }
        return profile.items.contains { $0.widget?.kind == .timer }
    }

    /// A minute count that shows the number it is set to.
    private func minutes(_ title: String, _ value: Binding<Int>,
                         in range: ClosedRange<Int>) -> some View {
        Stepper(value: value, in: range) {
            LabeledContent(title) { Text("\(value.wrappedValue) min") }
        }
    }

    /// What is actually on the shelf, in order.
    ///
    /// Everything about the shelf's contents used to be a toggle: whether to
    /// show running apps, whether to mirror the Dock's. The list itself was
    /// only visible on the shelf, and only editable by dragging on it, so
    /// there was no way to see what was pinned without going and looking, and
    /// no way to remove something you could not reach.
    ///
    /// Reordering stays on the shelf, where dragging is the obvious gesture
    /// and already works. This is for seeing the list and taking things off
    /// it.
    @ViewBuilder private var itemList: some View {
        let items = activeItems
        Section {
            // What the shelf holds, beside the list of what it holds.
            Toggle("Widgets only", isOn: $state.customDock.widgetsOnly)
            // Both add apps, so neither is a question a widgets-only shelf
            // is asking.
            if !state.customDock.widgetsOnly {
                Toggle("Show running apps", isOn: $state.customDock.showRunningApps)
                Toggle("Show Trash", isOn: $state.customDock.showTrash)
            }
            // Rearranging a mirrored app takes the list over, which is right,
            // but there has to be a way to give it back.
            if adoptedApps {
                LabeledContent {
                    Button("Mirror Again", action: onResumeMirroringApps)
                } label: {
                    subtitled("Apps", "Your own order. The Dock's changes are not followed.")
                }
            }

            if items.isEmpty {
                Label("Nothing on the shelf yet.", systemImage: "tray")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    HStack(spacing: 9) {
                        icon(for: item)
                            .frame(width: 20, height: 20)
                        Text(item.displayName)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text(item.kindName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button {
                            remove(item.id)
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Take this off the shelf")
                    }
                    .staggered(index)
                }
            }
        } header: {
            Text("On the shelf")
        } footer: {
            Text("Drag on the shelf itself to reorder, and add with the + at its end.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func icon(for item: DockItem) -> some View {
        if let image = item.listIcon {
            Image(nsImage: image).resizable().interpolation(.high)
        } else {
            Image(systemName: item.listSymbol)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var activeProfileIndex: Int? {
        guard let id = state.customDock.profileID else { return nil }
        return state.profiles.firstIndex { $0.id == id }
    }

    private var activeItems: [DockItem] {
        guard let index = activeProfileIndex else { return [] }
        return state.profiles[index].items
    }

    private func remove(_ id: UUID) {
        guard let index = activeProfileIndex else { return }
        withAnimation(.smooth(duration: 0.22)) {
            state.profiles[index].items.removeAll { $0.id == id }
        }
    }

    private var widgets: some View {
        Form {
            WidgetSettingsSections(state: $state)

            // Only when there is one to configure. These are settings for a
            // widget, and showing them to somebody whose shelf has no Focus
            // Timer on it is the same noise as any other control that does
            // nothing.
            if hasFocusTimer {
                Section {
                    // Every one of these showed a label and a pair of arrows
                    // and no number, so the only way to find out what the
                    // focus length was set to was to click an arrow and
                    // watch the tile change. A Stepper with a title draws
                    // the title, never the value; the value has to be put
                    // there. Same shape the per-widget number controls use.
                    minutes("Focus", $state.timer.work, in: 1...180)
                    minutes("Break", $state.timer.rest, in: 1...60)
                    minutes("Long break", $state.timer.longBreak, in: 1...180)
                    Stepper(value: $state.timer.sessions, in: 1...12) {
                        LabeledContent("Sessions before a long break") {
                            Text("\(state.timer.sessions)")
                        }
                    }
                    LabeledContent("Colour") { swatches }
                    Toggle("Alerts", isOn: $state.timer.alerts)
                        .help("Notify when a focus session or break ends.")
                } header: {
                    Text("Focus Timer")
                } footer: {
                    Text("Every Focus Timer widget shares these settings - Docket treats them as one timer.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var swatches: some View {
        HStack(spacing: 10) {
            ForEach(PaletteColor.picker, id: \.self) { colour in
                Button {
                    state.timer.color = colour
                } label: {
                    Circle()
                        .fill(Color(hex: colour.hex))
                        .frame(width: 18, height: 18)
                        .overlay {
                            Circle()
                                .strokeBorder(.primary.opacity(state.timer.color == colour ? 0.7 : 0), lineWidth: 2)
                                .padding(-3)
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(colour.rawValue.capitalized)
            }
        }
    }
}

// MARK: - Labels

private func title(_ value: AppAppearance) -> String {
    switch value {
    case .system: "System"
    case .light: "Light"
    case .dark: "Dark"
    }
}

private func title(_ value: DockSetup) -> String {
    switch value {
    case .macOSDockOnly: "Apple Dock"
    case .both: "Dock and Shelf"
    case .customReplacement: "Shelf only"
    }
}

private func detail(_ value: DockSetup) -> String {
    switch value {
    case .macOSDockOnly: "Just Apple's Dock, with saved layouts."
    case .both: "Apple's Dock for apps, a shelf of widgets on another edge."
    case .customReplacement: "One shelf for apps and widgets. Apple's Dock stays hidden."
    }
}

private func title(_ value: DockPosition) -> String {
    switch value {
    case .left: "Left"
    case .bottom: "Bottom"
    case .right: "Right"
    }
}

private func title(_ value: MenuBarLabelMode) -> String {
    switch value {
    case .none: "Nothing"
    case .native: "Apple Dock layout"
    case .custom: "Shelf layout"
    case .both: "Both layouts"
    }
}

private extension NSScreen {
    /// `CGDirectDisplayID` for this screen, which is what `displayID` stores.
    var docketDisplayID: UInt32? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32
    }
}


// MARK: - Pieces

/// A choice shown as a picture of its result, with its name under it.
///
/// Used wherever the options differ in how something looks. A segmented
/// control of three words asks you to imagine each one; a picture shows it.
private struct ChoiceCard<Picture: View>: View {
    let title: String
    var caption: String?
    let selected: Bool
    let action: () -> Void
    @ViewBuilder let picture: () -> Picture

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                picture()
                    .frame(maxWidth: .infinity)
                    .clipShape(.rect(cornerRadius: 6))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.callout.weight(.semibold))
                    if let caption {
                        Text(caption)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(caption == nil ? 8 : 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(selected ? Color.accentColor : .primary.opacity(0.08),
                                  lineWidth: selected ? 2 : 1)
            }
            .contentShape(.rect(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// A screen with the shelf along one edge.
private struct EdgeSketch: View {
    let edge: DockPosition

    var body: some View {
        let vertical = edge != .bottom
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(.primary.opacity(0.06))
            .overlay(alignment: edge == .left ? .leading : edge == .right ? .trailing : .bottom) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.accentColor.opacity(0.85))
                    .frame(width: vertical ? 6 : 44, height: vertical ? 26 : 6)
                    .padding(4)
            }
    }
}

/// The shelf's material, for real, over a scrap of colour.
private struct MaterialSample: View {
    let look: SettingsView.Look

    var body: some View {
        ZStack {
            LinearGradient(colors: [.orange, .pink, .indigo],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            // Something behind the shelf for the material to act on.
            Circle().fill(.yellow.opacity(0.9)).frame(width: 22).offset(x: -18, y: 6)
            slab
        }
    }

    @ViewBuilder private var slab: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        let tiles = HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 3).fill(.white.opacity(0.9)).frame(width: 12, height: 12)
            }
        }
        .padding(6)
        switch look {
        case .frosted: tiles.background(.regularMaterial, in: shape)
        case .glass: tiles.glassEffect(.regular, in: shape)
        case .clear: tiles.glassEffect(.clear, in: shape)
        }
    }
}

/// A window in each appearance, and System as both at once.
private struct AppearanceSketch: View {
    let appearance: AppAppearance

    var body: some View {
        switch appearance {
        case .light: window(dark: false)
        case .dark: window(dark: true)
        case .system:
            HStack(spacing: 0) {
                window(dark: false)
                window(dark: true)
            }
        }
    }

    private func window(dark: Bool) -> some View {
        ZStack(alignment: .topLeading) {
            Rectangle().fill(dark ? Color(white: 0.16) : Color(white: 0.93))
            VStack(alignment: .leading, spacing: 4) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(dark ? Color(white: 0.35) : Color(white: 0.75))
                    .frame(width: 34, height: 5)
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.accentColor)
                    .frame(width: 22, height: 5)
            }
            .padding(8)
        }
    }
}

/// A thumbnail of the screen: Apple's Dock in grey along the bottom, the
/// shelf in the accent colour wherever it goes.
private struct SetupSketch: View {
    let setup: DockSetup

    var body: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(.primary.opacity(0.06))
            .overlay(alignment: .bottom) {
                if setup != .customReplacement {
                    bar(tiles: 5, colour: .primary.opacity(0.35))
                        .padding(.bottom, 5)
                }
            }
            .overlay(alignment: setup == .both ? .trailing : .bottom) {
                if setup != .macOSDockOnly {
                    // Beside Apple's Dock it takes a free edge, which is what
                    // the shelf does rather than stack on the Dock's.
                    shelf(vertical: setup == .both)
                        .padding(setup == .both ? .trailing : .bottom, 5)
                }
            }
    }

    private func bar(tiles: Int, colour: Color) -> some View {
        HStack(spacing: 2.5) {
            ForEach(0..<tiles, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 1.5).fill(colour).frame(width: 6, height: 6)
            }
        }
        .padding(3)
        .background(.primary.opacity(0.1), in: .rect(cornerRadius: 3.5))
    }

    /// Apps and one wide widget, so it reads as the shelf and not a second
    /// Dock.
    private func shelf(vertical: Bool) -> some View {
        let tile = RoundedRectangle(cornerRadius: 1.5).fill(Color.accentColor.opacity(0.85))
        let layout = vertical
            ? AnyLayout(VStackLayout(spacing: 2.5)) : AnyLayout(HStackLayout(spacing: 2.5))
        return layout {
            tile.frame(width: vertical ? 6 : 14, height: vertical ? 14 : 6)
            tile.frame(width: 6, height: 6)
            tile.frame(width: 6, height: 6)
        }
        .padding(3)
        .background(Color.accentColor.opacity(0.18), in: .rect(cornerRadius: 3.5))
    }
}

/// A saved layout: click to use it, type to rename it.
private struct LayoutRow<Preview: View>: View {
    @Binding var name: String
    let editable: Bool
    let active: Bool
    let onUse: () -> Void
    var onDuplicate: (() -> Void)?
    var onDelete: (() -> Void)?
    @ViewBuilder var preview: () -> Preview

    /// Renaming is asked for, not always on. An always-live field took focus
    /// when the pane opened and showed the first name selected, as if it was
    /// about to be typed over.
    @State private var renaming = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onUse) {
                Image(systemName: active ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(active ? Color.accentColor : .secondary)
                    .imageScale(.large)
            }
            .buttonStyle(.plain)
            .help(active ? "In use" : "Use this layout")
            .accessibilityLabel(active ? "In use" : "Use \(name)")

            if renaming {
                // Unlabelled and leading: inside a form a titled field draws
                // its title as a row label and pushes the name to the far
                // edge, so every row read "Name ... Everyday".
                TextField("Name", text: $name)
                    .textFieldStyle(.plain)
                    .labelsHidden()
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .focused($focused)
                    .onSubmit { renaming = false }
                    .onChange(of: focused) { _, now in if !now { renaming = false } }
                    .onAppear { focused = true }
            } else if editable {
                Text(name)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
                    .onTapGesture(count: 2) { renaming = true }
                    .onTapGesture(perform: onUse)
            } else {
                Text(name)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
                    .onTapGesture(perform: onUse)
            }

            preview()

            if onDuplicate != nil || onDelete != nil {
                Menu {
                    if editable { Button("Rename") { renaming = true } }
                    if let onDuplicate { Button("Duplicate", action: onDuplicate) }
                    if let onDelete { Button("Delete", role: .destructive, action: onDelete) }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
    }
}
