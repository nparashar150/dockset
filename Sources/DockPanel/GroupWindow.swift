import AppKit
import SwiftUI

/// An opened group, in a window of its own.
///
/// Same reasoning as the hover label: drawing it inside the shelf would mean
/// reserving space for the largest group anyone might make. A separate panel
/// costs nothing when closed and can be as large as it needs to be.
@MainActor
final class GroupWindow {
    static let shared = GroupWindow()

    private var panel: NSPanel?
    private var hosting: FirstMouseHostingView<GroupSheet>?
    /// Which group is open, so clicking the same tile again closes it.
    private(set) var openGroupID: UUID?
    /// Changes on every open, to restart the sheet's entrance.
    private var session = UUID()

    private init() {}

    /// Opens `group`, or closes it if it is already the one showing.
    ///
    /// - Parameters:
    ///   - anchor: the point on the tile to grow away from, in screen coordinates.
    ///   - edge: which way the shelf is docked.
    func toggle(_ group: DockGroup, anchor: CGPoint, edge: DockPosition,
                iconSide: CGFloat,
                open: @escaping (DockItem) -> Void,
                remove: @escaping (DockItem) -> Void,
                rename: @escaping (String) -> Void) {
        if openGroupID == group.id { return close() }
        show(group, anchor: anchor, edge: edge, iconSide: iconSide,
             open: open, remove: remove, rename: rename)
    }

    /// Whether a group is showing, so the shelf can stay put while it is.
    var isOpen: Bool { openGroupID != nil && panel?.isVisible == true }

    /// The sheet's area in screen coordinates, for hit-free pointer tests.
    func contains(_ point: CGPoint) -> Bool {
        guard isOpen, let panel else { return false }
        // The visible sheet plus a little slack, so crossing the gap between
        // tile and sheet does not read as leaving. The window itself is much
        // larger than what is drawn - see GroupSheet.dragRoom.
        let slack = GroupSheet.dragRoom - 14
        return panel.frame.insetBy(dx: slack, dy: slack).contains(point)
    }

    func close() {
        guard panel?.isVisible == true, openGroupID != nil else { return }
        openGroupID = nil
        // orderOut alone is a vanish. The window fades while the sheet inside
        // it scales back toward the tile it came from.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel?.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                // Only if nothing reopened it while the fade was running.
                guard let self, self.openGroupID == nil else { return }
                self.panel?.orderOut(nil)
                self.panel?.alphaValue = 1
            }
        }
    }

    private func show(_ group: DockGroup, anchor: CGPoint, edge: DockPosition,
                      iconSide: CGFloat,
                      open: @escaping (DockItem) -> Void,
                      remove: @escaping (DockItem) -> Void,
                      rename: @escaping (String) -> Void,
                      rebuilt: Bool = false) {
        let panel = existingOrNew()
        // A fresh token per open: the hosting view is reused, so its state
        // survives being ordered out and would otherwise start already-shown.
        session = UUID()
        hosting?.rootView = GroupSheet(group: group, edge: edge, session: session,
                                       iconSide: iconSide,
                                       open: { [weak self] item in
            open(item)
            self?.close()
        }, remove: { [weak self] item in
            remove(item)
            self?.close()
        }, rename: rename)
        openGroupID = group.id

        let size = hosting?.fittingSize ?? .zero
        let room = GroupSheet.dragRoom
        let visible = CGSize(width: size.width - room * 2, height: size.height - room * 2)
        guard visible.width > 1, visible.height > 1 else { return }

        // Everything is positioned against the sheet the user can see; the
        // panel is then offset so its invisible margin falls outside that.
        let gap: CGFloat = 12
        let sheet: CGPoint = switch edge {
        case .bottom: CGPoint(x: anchor.x - visible.width / 2, y: anchor.y + gap)
        case .left: CGPoint(x: anchor.x + gap, y: anchor.y - visible.height / 2)
        case .right: CGPoint(x: anchor.x - visible.width - gap, y: anchor.y - visible.height / 2)
        }
        let placed = clamped(sheet, size: visible)

        panel.setFrame(CGRect(origin: CGPoint(x: placed.x - room, y: placed.y - room),
                              size: size), display: true)
        // See WidgetDetailWindow: a close's fade still in flight would
        // otherwise carry the reopened sheet back to zero opacity.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            panel.animator().alphaValue = 1
        }
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        // See WidgetDetailWindow.place: a window macOS has pinned to another
        // Space is replaced by a fresh one, which lands on this Space.
        if !panel.isOnActiveSpace, !rebuilt {
            self.panel?.orderOut(nil)
            self.panel = nil
            hosting = nil
            openGroupID = nil
            return show(group, anchor: anchor, edge: edge, iconSide: iconSide,
                        open: open, remove: remove, rename: rename, rebuilt: true)
        }
        // Needed for the name field; the shelf itself still never takes key,
        // so clicking a tile does not pull focus out of the user's app.
        panel.makeKey()
    }

    /// Keeps the sheet on screen when the group sits near a corner.
    private func clamped(_ origin: CGPoint, size: NSSize) -> CGPoint {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(origin) })
                ?? NSScreen.main else { return origin }
        let visible = screen.visibleFrame
        return CGPoint(
            x: min(max(origin.x, visible.minX + 6), max(visible.minX, visible.maxX - size.width - 6)),
            y: min(max(origin.y, visible.minY + 6), max(visible.minY, visible.maxY - size.height - 6))
        )
    }

    private func existingOrNew() -> NSPanel {
        if let panel { return panel }
        let hosting = FirstMouseHostingView(rootView: GroupSheet(group: DockGroup(name: ""),
                                                                  edge: .bottom, session: session,
                                                                  iconSide: 48,
                                                                  open: { _ in }, remove: { _ in },
                                                                  rename: { _ in }))
        hosting.sizingOptions = [.intrinsicContentSize]

        let panel = KeyablePanel(contentRect: .zero,
                                 styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered, defer: false)
        // Escape and Command-W, the same as a widget's panel. Escape while
        // renaming abandons the unsubmitted name, as it does in Finder.
        panel.onCancel = { [weak self] in self?.close() }
        panel.contentView = hosting
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        // The sheet holds an editable name, and a panel that can never become
        // key would show a caret that accepts no typing.
        panel.becomesKeyOnlyIfNeeded = true
        panel.worksWhenModal = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        // One above the shelf, so an opened group is never behind the tile it
        // came from.
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) + 2)

        self.panel = panel
        self.hosting = hosting
        return panel
    }
}

/// The opened group's contents: its name, then every item at full size.
struct GroupSheet: View {
    var group: DockGroup
    /// Which way the shelf is docked, so the sheet grows from the tile's side.
    var edge: DockPosition
    /// Identifies one opening, so the entrance replays each time.
    var session: UUID
    /// The shelf's icon size, so a dragged icon becomes what it is about to be.
    var iconSide: CGFloat
    var open: (DockItem) -> Void
    var remove: (DockItem) -> Void
    var rename: (String) -> Void

    @State private var appeared = false
    @State private var draft = ""
    @FocusState private var editing: Bool

    /// Wraps rather than growing without limit - a group with thirty apps
    /// should not produce a sheet wider than the screen.
    private var columns: Int { min(5, max(1, group.items.count)) }
    private let side: CGFloat = 52

    /// Named so a dragged icon can tell when it has left the sheet.
    static let space = "group-sheet"

    /// Invisible room around the sheet for an icon being dragged out.
    ///
    /// The panel's frame is its clip: without this the icon vanished at the
    /// sheet's edge exactly as it started to leave, which is the moment the
    /// gesture most needs to be visible. The margin draws nothing and takes
    /// no clicks, so it costs only window area.
    static let dragRoom: CGFloat = 90

    @State private var bounds: CGSize = .zero

    var body: some View {
        VStack(spacing: 10) {
            // Editable in place. A group's name is the one thing you always
            // want to change right after making one, and burying it in a
            // submenu behind a modal is why it read as not being possible.
            TextField("Name", text: $draft)
                .textFieldStyle(.plain)
                .multilineTextAlignment(.center)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(editing ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .focused($editing)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(editing ? Color.primary.opacity(0.10) : .clear)
                }
                .onSubmit { commit() }
                .onChange(of: editing) { _, focused in if !focused { commit() } }

            VStack(spacing: 10) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    HStack(spacing: 10) {
                        ForEach(row) { item in
                            GroupSheetItem(item: item, side: side, sheet: bounds,
                                           dockSide: iconSide, group: group.id,
                                           open: { open(item) },
                                           remove: { remove(item) })
                        }
                    }
                }
            }
        }
        .padding(14)
        .coordinateSpace(name: Self.space)
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { bounds = proxy.size }
                    .onChange(of: proxy.size) { _, new in bounds = new }
            }
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.regularMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(.white.opacity(0.14), lineWidth: 1)
                }
        }
        .fixedSize()
        // Scales out of the tile it belongs to instead of appearing at full
        // size in place. Anchored on the docked edge, so it reads as the tile
        // opening rather than a panel arriving.
        .scaleEffect(appeared ? 1 : 0.88, anchor: growthAnchor)
        .opacity(appeared ? 1 : 0)
        .padding(Self.dragRoom)
        .onAppear {
            draft = group.name
            enter()
        }
        .onChange(of: session) { _, _ in
            draft = group.name
            appeared = false
            // Next runloop, or setting and clearing in one pass animates nothing.
            Task { @MainActor in enter() }
        }
    }

    /// Ignores an empty name rather than leaving a group with none.
    private func commit() {
        let name = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != group.name else {
            draft = group.name
            return
        }
        rename(name)
    }

    private func enter() {
        withAnimation(.spring(response: 0.30, dampingFraction: 0.78)) { appeared = true }
    }

    private var growthAnchor: UnitPoint {
        switch edge {
        case .bottom: .bottom
        case .left: .leading
        case .right: .trailing
        }
    }

    private var rows: [[DockItem]] {
        stride(from: 0, to: group.items.count, by: columns).map {
            Array(group.items[$0 ..< min($0 + columns, group.items.count)])
        }
    }
}

private struct GroupSheetItem: View {
    var item: DockItem
    var side: CGFloat
    /// The sheet's size, so the icon knows when it has been pulled outside it.
    var sheet: CGSize
    /// What size it becomes once it is over the shelf.
    var dockSide: CGFloat
    /// The group it would be leaving.
    var group: UUID
    var open: () -> Void
    var remove: () -> Void

    @State private var hovering = false
    @State private var offset: CGSize = .zero
    @State private var leaving = false
    /// This icon's own centre in the sheet, so a drag can pin to the pointer.
    @State private var centre: CGPoint = .zero
    /// Released outside: shrinking away at the drop point before the shelf
    /// grows it back in, so the icon travels instead of blinking out.
    @State private var departing = false

    /// Dragging an icon past the edge of the sheet takes it out of the group,
    /// the way dragging one off a folder does on iOS. A cross-window drag
    /// session would be the general answer, but the only destination here is
    /// "not in this group", so leaving the sheet is the whole gesture.
    private func outside(_ point: CGPoint) -> Bool {
        GroupDrag.leavesSheet(point, sheet: sheet)
    }

    /// Once it is over the shelf it is a dock icon, so it becomes one - the
    /// sheet draws at its own size, and an icon that kept it would land at the
    /// wrong scale and snap.
    private var carriedSide: CGFloat { leaving ? dockSide : side }

    var body: some View {
        VStack(spacing: 4) {
            icon
                .frame(width: carriedSide, height: carriedSide)
            Text(name)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: side + 8)
        }
        .padding(4)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(hovering ? Color.primary.opacity(0.10) : .clear)
        }
        .background {
            GeometryReader { proxy in
                let box = proxy.frame(in: .named(GroupSheet.space))
                Color.clear
                    .onAppear { centre = CGPoint(x: box.midX, y: box.midY) }
                    .onChange(of: box) { _, new in
                        // Only while at rest: the frame moves as the icon is
                        // dragged, and following it would chase its own tail.
                        if offset == .zero { centre = CGPoint(x: new.midX, y: new.midY) }
                    }
            }
        }
        .offset(offset)
        .scaleEffect(departing ? 0.25 : 1)
        .opacity(departing ? 0 : (leaving ? 0.8 : 1))
        .zIndex(offset == .zero ? 0 : 1)
        .contentShape(.rect)
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.14)) { hovering = inside }
        }
        .onTapGesture(perform: open)
        .gesture(
            DragGesture(minimumDistance: 8, coordinateSpace: .named(GroupSheet.space))
                .onChanged { value in
                    // Pinned to the pointer, not displaced by it. Offsetting
                    // by the translation leaves the icon wherever the cursor
                    // happened to grab it - press near an edge and the icon
                    // trails the pointer by that much for the whole drag.
                    offset = GroupDrag.offset(cursor: value.location, centre: centre)
                    let out = outside(value.location)
                    if DragOut.shared.item == nil { DragOut.shared.begin(item, from: group) }
                    // The pointer in screen coordinates, which is what the
                    // shelf needs and what no SwiftUI space in this window can
                    // give it. `mouseLocation` is already exactly that.
                    DragOut.shared.update(location: NSEvent.mouseLocation, outside: out)
                    if out != leaving {
                        withAnimation(.spring(response: 0.26, dampingFraction: 0.8)) {
                            leaving = out
                        }
                    }
                }
                .onEnded { value in
                    defer { DragOut.shared.end() }
                    if outside(value.location) {
                        withAnimation(.spring(response: 0.22, dampingFraction: 0.85)) {
                            departing = true
                        }
                        // Hands over once the icon has gone, so the shelf's own
                        // entrance picks up where this leaves off.
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(150))
                            remove()
                        }
                        return
                    }
                    // Dropped back inside: nothing changes, so it springs home.
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.62)) {
                        offset = .zero
                        leaving = false
                    }
                }
        )
        .contextMenu {
            Button("Remove from Group") { remove() }
        }
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(name)
    }

    @ViewBuilder
    private var icon: some View {
        if let url = item.fileRef?.resolve() {
            Image(nsImage: AppCatalog.shared.icon(for: url)).resizable().interpolation(.high)
        } else if case .app(_, let bundleID, _) = item,
                  let image = AppCatalog.shared.icon(forBundleID: bundleID) {
            Image(nsImage: image).resizable().interpolation(.high)
        } else {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.secondary.opacity(0.3))
        }
    }

    private var name: String {
        if let url = item.fileRef?.resolve() {
            return url.deletingPathExtension().lastPathComponent
        }
        if case .link(_, _, let title) = item { return title }
        return "Item"
    }
}
