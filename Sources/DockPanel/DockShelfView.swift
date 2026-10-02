import SwiftUI
import AppKit

struct DockShelfView: View {
    @Environment(AppState.self) private var app

    @State private var cursor: CGPoint?
    @State private var drag: DragState?
    /// The dragged tile's own displacement, deliberately *outside* `drag`.
    ///
    /// SwiftUI coalesces writes to one @State within an update cycle, so the
    /// last write carries the transaction - animating `destination` after
    /// setting `translation` on the same value still spring-smooths the
    /// translation, and the tile trails the cursor. Kept apart, the finger's
    /// position can never end up inside an animated transaction.
    @State private var dragTranslation: CGFloat = 0
    /// Bumped per tile to fire one arc of its launch bounce.
    @State private var bounceTick: [UUID: Int] = [:]
    /// Keeps bouncing until the app reports that it started.
    @State private var bounceTask: [UUID: Task<Void, Never>] = [:]
    /// Screen point of the tile under the pointer, for anchoring an open group.
    @State private var hoverAnchor: CGPoint?
    /// The gap an icon leaving a group is currently aimed at.
    @State private var lastIncoming: Int?
    /// Screen centre of the hovered tile's icon, for the removal poof.
    @State private var hoverIconCentre: CGPoint?
    /// Tiles the poof is standing in for, which therefore leave instantly.
    @State private var poofing: Set<UUID> = []
    /// Arms `groupTarget` once the dragged tile has rested over another.
    @State private var dwell: Task<Void, Never>?
    /// What that timer is currently counting down for.
    @State private var dwellOver: UUID?
    @State private var scroll: CGFloat = 0
    /// The grip drag's last reported delta, so each event applies only the
    /// step since the previous one. Not an anchor scale: see the grip.
    @State private var lastResizeDelta: Double?
    /// Both axes, so a stale one is impossible.
    ///
    /// This used to cache a single value picked by orientation at the time it
    /// was measured. Moving the shelf to a side then compared its height
    /// against the screen's *width*: it never registered as overflowing, so
    /// nothing clipped and nothing scrolled, and the column simply ran off
    /// the top and bottom of the display.
    @State private var screenSize: CGSize = .zero
    @State private var addHovered = false
    @State private var shelfWindow: NSWindow?

    /// Stable across solves: keying it on a fresh UUID would tell SwiftUI the
    /// Trash was removed and re-added on every pointer move.
    private static let trashID = UUID.stable(from: "docket.trash")

    private struct DragState {
        var id: UUID
        /// Index among draggable entries.
        var from: Int
        var destination: Int
        /// The tile being hovered long enough to drop onto, if any.
        var groupTarget: UUID?
    }

    private struct Entry: Identifiable {
        var id: UUID
        var item: DockItem
        var isRunningApp: Bool
        /// The Trash, which is a destination rather than a thing you arrange.
        var isTrash: Bool = false
        /// Resolved once per solve. Deriving it in the tile body meant a
        /// `stat(2)` and a string allocation for every app on every pointer
        /// move, since `FileRef.resolve()` touches the filesystem.
        var label: String

        /// What another tile can be dropped onto to make or join a group.
        var canReceiveDrop: Bool { !isRunningApp && !item.isWidget && !isTrash }

        /// Only pinned, non-widget tiles can go in a group: a running app
        /// that is not on the shelf has no slot to take with it.
        var canBeGrouped: Bool { !isRunningApp && !item.isWidget && item.group == nil && !isTrash }

        /// Whether clicking this tile does anything: unfold a group, open an
        /// app, or - for a widget - show its detail panel, and failing that
        /// open the app it is about.
        ///
        /// Has to agree with `open(_:)`, which tries the panel first and the
        /// app only when there is none. Asking `openTarget` alone left the
        /// tiles that *only* have a panel with no gesture at all.
        var opens: Bool {
            if let widget = item.widget {
                WidgetDetail.exists(for: widget.kind)
                    || WidgetCatalog.openTarget(widget.kind) != nil
            } else { true }
        }

        /// Names the click for assistive tech, matching what `open(_:)` will
        /// actually do - a panel for a widget that has one, otherwise the app.
        var actionLabel: String {
            if let widget = item.widget, WidgetDetail.exists(for: widget.kind) {
                "Show Details"
            } else { "Open" }
        }
        /// Running-but-unpinned apps have no stored position to move, and
        /// neither does the Trash: it is pinned to the end the way the Dock
        /// pins its own.
        var isDraggable: Bool { !isRunningApp && !isTrash }
    }

    /// One position along the shelf: either an entry or the hairline that
    /// separates pinned items from running apps.
    ///
    /// Modelling the separator as a slot keeps every layout calculation
    /// uniform - otherwise its width silently skews every position after it,
    /// and magnification drifts off the running apps.
    private enum Slot: Identifiable {
        case item(Entry)
        case separator
        /// The size grip, which sits where the widgets end and the apps begin.
        case grip

        /// Stable across renders, and *not* the array index.
        ///
        /// Keying the row on its index told SwiftUI that adding or removing an
        /// item was a content change to the view at that position rather than
        /// an insertion or a removal - so no insertion ever happened, no
        /// transition could fire, and every tile after the change swapped its
        /// contents in place. That is why nothing animated.
        var id: UUID {
            switch self {
            case .item(let entry): entry.id
            case .separator: Self.separatorID
            case .grip: Self.gripID
            }
        }

        private static let separatorID = UUID()
        private static let gripID = UUID()
    }

    /// The whole shelf geometry, solved once.
    ///
    /// Every piece of this used to be a separate computed property, so a
    /// single render rebuilt the entry list six or eight times over - once per
    /// property that happened to touch it. On a pointer move that is the
    /// difference between feeling immediate and feeling sluggish.
    private struct Solved {
        var slots: [Slot] = []
        var lengths: [CGFloat] = []
        var starts: [CGFloat] = []
        var centers: [CGFloat] = []
        var scales: [CGFloat] = []
        var offsets: [CGFloat] = []
        /// Centre of each slot *as rendered*, measured inside the plate.
        ///
        /// Distinct from `centers`, which are rest positions. Once tiles grow
        /// along the shelf everything after them shifts, so anything that has
        /// to point at a tile on screen - the hover label, the hit test - has
        /// to use these instead.
        var viewCenters: [CGFloat] = []
        /// Leading gap before each slot. Not uniform: a widget sits almost
        /// flush against its neighbour, while icons are spaced apart.
        var gaps: [CGFloat] = []
        /// Total growth, i.e. how much wider the plate is than at rest.
        var totalExtra: CGFloat = 0
        var restLength: CGFloat = 0
        var restCross: CGFloat = 0

        var entries: [Entry] {
            slots.compactMap { if case .item(let e) = $0 { e } else { nil } }
        }
    }

    // MARK: Settings

    private var settings: CustomDockSettings { app.state.customDock }
    private var position: DockPosition { app.effectivePosition }
    private var vertical: Bool { position.isVertical }
    private var scale: Double { app.effectiveScale }
    private var magnifies: Bool { app.magnificationEnabled }
    private var chrome: Geometry.Chrome { Geometry.chrome(scale: scale) }

    private var iconGeometry: Geometry.IconGeometry {
        Geometry.iconGeometry(scale: scale, vertical: vertical, hasWidgets: hasWidgets)
    }

    private var hasWidgets: Bool { app.hasWidgets }
    /// Hairline plus its margins.
    private var separatorExtent: CGFloat { 7 }
    /// The grip's own extent along the shelf, as a slot in the row.
    private var gripSlotExtent: CGFloat { 16 }

    // MARK: Solve

    private func solve() -> Solved {
        var result = Solved()

        // Read once: it is not stored, so each access rebuilds the array.
        //
        // Filtered rather than edited: the apps stay in the profile and come
        // back the moment the setting goes off, so turning it on costs
        // nothing and turning it off loses nothing.
        let items = settings.widgetsOnly
            ? app.effectiveItems.filter(\.isWidget)
            : app.effectiveItems
        var entries = items.map {
            Entry(id: $0.id, item: $0, isRunningApp: false, label: label(for: $0))
        }
        // Running apps are apps. Offering to append them to a shelf that is
        // deliberately showing no apps would be the same control contradicting
        // itself.
        if settings.showRunningApps, !settings.widgetsOnly {
            let running = AppCatalog.shared.unpinned(from: items)
            if !running.isEmpty { result.slots = entries.map(Slot.item) + [.separator] }
            for app in running {
                guard let url = app.url else { continue }
                let id = UUID.stable(from: app.id)
                entries.append(Entry(id: id,
                                     item: .app(id: id, bundleID: app.id, ref: FileRef(url: url)),
                                     isRunningApp: true,
                                     label: app.name))
            }
        }

        // Last, behind its own divider, which is where Apple's Dock keeps it.
        // Not a profile item: it is a setting, so it is appended per solve
        // rather than stored, and it can never be dragged out of place.
        // The Trash is not a widget either.
        if settings.showTrash, !settings.widgetsOnly, let trash = AppCatalog.trashURL {
            entries.append(Entry(id: Self.trashID,
                                 item: .folder(id: Self.trashID,
                                               ref: FileRef(url: trash),
                                               icon: FolderIcon()),
                                 isRunningApp: false,
                                 isTrash: true,
                                 label: "Trash"))
        }

        // Rebuild slots with the separator and the grip in the right places.
        //
        // The grip goes on the seam between the widgets and the apps rather
        // than after everything: that is the edge the drag actually moves, and
        // at the end of the row it sat a long way from the thing it resizes.
        // Modelled as a slot for the same reason the separator is - anything
        // occupying width that the layout does not know about silently skews
        // every position after it.
        let lastWidget = entries.lastIndex { $0.item.isWidget }
        result.slots = []
        for (index, entry) in entries.enumerated() {
            if entry.isRunningApp, index > 0, !entries[index - 1].isRunningApp {
                result.slots.append(.separator)
            }
            if entry.isTrash, index > 0 { result.slots.append(.separator) }
            result.slots.append(.item(entry))
            if let lastWidget, index == lastWidget, index < entries.count - 1 {
                result.slots.append(.grip)
            }
        }

        result.lengths = result.slots.map { slot in
            switch slot {
            case .separator: separatorExtent
            case .grip: gripSlotExtent
            case .item(let entry): longLength(entry.item)
            }
        }

        for index in result.slots.indices {
            result.gaps.append(index == 0 ? 0
                               : gap(between: result.slots[index - 1], and: result.slots[index]))
        }

        var cursor: CGFloat = 0
        for (index, length) in result.lengths.enumerated() {
            cursor += result.gaps[index]
            result.starts.append(cursor)
            result.centers.append(cursor + length / 2)
            cursor += length
        }

        let crossExtents = result.slots.map { slot -> CGFloat in
            switch slot {
            case .separator, .grip:
                return 0
            case .item(let entry):
                let size = baseSize(entry.item)
                return vertical ? size.width : size.height
            }
        }
        result.restCross = (crossExtents.max() ?? 0) + chrome.padding * 2
        result.restLength = cursor + chrome.padding * 2 + gripExtent

        let peaks = result.slots.map { slot -> Double in
            switch slot {
            // Neither the separator nor the grip magnifies: they are chrome,
            // and a hairline swelling under the pointer reads as a glitch.
            case .separator, .grip: 0
            // Widgets never magnify. The shipped port is explicit about it
            // ("The custom Dock never magnifies"), and the reason is plain
            // once you try it: magnification exists so you can tell which
            // small icon you are about to hit, while a widget is already
            // large and readable. Worse, a 264pt card swelling even 20%
            // displaces a quarter of the shelf, so brushing past one shoves
            // every icon aside.
            case .item(let entry): entry.item.isWidget ? 0 : app.magnificationPeak
            }
        }

        if magnifies, drag == nil, let pointer {
            let rest = pointer - chrome.padding - scroll
            result.scales = DockMagnification.scales(pointer: rest, centers: result.centers,
                                                     peaks: peaks, radius: app.magnificationRadius)
            result.offsets = Array(repeating: 0, count: result.slots.count)
        } else {
            result.scales = Array(repeating: 1, count: result.slots.count)
            result.offsets = Array(repeating: 0, count: result.slots.count)
        }

        var viewCursor: CGFloat = 0
        for (index, length) in result.lengths.enumerated() {
            let grown = length * result.scales[index]
            viewCursor += result.gaps[index]
            result.viewCenters.append(viewCursor + grown / 2)
            viewCursor += grown
            result.totalExtra += grown - length
        }
        return result
    }

    /// Spacing between two neighbouring slots.
    ///
    /// Uniform. The shipped metrics list a *negative* gap for widget-touching
    /// edges, but that assumes a tile which carries its own outer margin -
    /// ours does not, so applying it crushed neighbouring cards to within a
    /// point of each other and they read as one fused slab. Measured at 0.5pt
    /// apart before this was reverted.
    private func gap(between previous: Slot, and next: Slot) -> CGFloat {
        chrome.itemGap
    }

    private func longLength(_ item: DockItem) -> CGFloat {
        let size = baseSize(item)
        return vertical ? size.height : size.width
    }

    private func baseSize(_ item: DockItem) -> CGSize {
        if let widget = item.widget {
            return WidgetCatalog.tileSize(widget, position: position, scale: scale)
        }
        let geo = iconGeometry
        if case .spacer(_, let size) = item {
            let full = vertical ? geo.height : geo.width
            let length = size == .small ? full / 2 : full
            return vertical ? CGSize(width: geo.width, height: length)
                            : CGSize(width: length, height: geo.height)
        }
        return CGSize(width: geo.width, height: geo.height)
    }

    /// Grip plus the add button, neither of which magnifies.
    /// What the row carries after its last item: the add button alone, now
    /// that the grip has moved onto the widget/app seam.
    ///
    /// The add button's extent along the shelf is its *height* on a side
    /// shelf. Budgeting `width` in both orientations left the model longer
    /// than the row actually rendered, and every length derived from it - the
    /// plate, the scroll limit, the hover label - inherited the error.
    private var gripExtent: CGFloat {
        chrome.itemGap + (vertical ? iconGeometry.height : iconGeometry.width)
    }

    /// Which item the pointer is over, when it is a widget.
    @State private var hoveredID: UUID?

    private var pointer: CGFloat? {
        guard let cursor else { return nil }
        return vertical ? cursor.y : cursor.x
    }

    // MARK: Body

    var body: some View {
        let solved = solve()

        ZStack(alignment: edgeAlignment) {
            Color.clear
                .frame(width: vertical ? solved.restCross + crossHeadroom
                                       : plateLength(solved) + longReserve,
                       height: vertical ? plateLength(solved) + longReserve
                                        : solved.restCross + crossHeadroom)
                // Headroom for magnified icons to grow into. It is invisible,
                // so it must not eat clicks aimed at the desktop behind it.
                .allowsHitTesting(false)
            shelf(solved)
        }
        .background { WindowReader { shelfWindow = $0 } }
        .onChange(of: hoverTarget(solved)) { _, new in
            applyHoverLabel(new)
            // Written here rather than read during body, where a state write
            // is not allowed, which is the same reason `centre` is carried on
            // the target itself.
            hoveredID = new?.id
        }
        .onDisappear { TooltipWindow.shared.hide() }
        .onAppear { measureScreen() }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didChangeScreenParametersNotification)) { _ in measureScreen() }
        .onChange(of: solved.slots.count) { scroll = clampedScroll(scroll, solved) }
    }

    private func measureScreen() {
        screenSize = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame.size ?? .zero
    }

    private var edgeAlignment: Alignment {
        switch position {
        case .bottom: .bottom
        case .left: .leading
        case .right: .trailing
        }
    }

    /// Pins the row to the start of the long axis. Centring splits any overflow
    /// across both ends and silently eats the first and last items.
    private var contentAlignment: Alignment { vertical ? .top : .bottomLeading }

    private var maxLength: CGFloat {
        let along = vertical ? screenSize.height : screenSize.width
        guard along > 0 else { return 1_200 }
        // The window also has to hold the magnification reserve, or it ends up
        // taller than the screen and spills over the menu bar.
        return along - 40 - longReserve
    }
    private func isOverflowing(_ s: Solved) -> Bool { s.restLength > maxLength }
    private func plateLength(_ s: Solved) -> CGFloat { min(s.restLength, maxLength) }

    /// Room for a magnified icon to grow out of the plate - and for a launch
    /// bounce to leave it.
    ///
    /// This used to be zero whenever magnification was off, which sized the
    /// panel window to the plate exactly and clipped the whole bounce away.
    private var crossHeadroom: CGFloat {
        max(magnifies ? iconGeometry.icon * app.magnificationPeak : 0, bouncePeak) + 12
    }

    /// How far a tile rises when its app is launching.
    private var bouncePeak: CGFloat { iconGeometry.icon * Bounce.peak }

    /// How far a magnified icon rises above the plate.
    private var iconGrowth: CGFloat {
        magnifies ? iconGeometry.icon * app.magnificationPeak : 0
    }

    private var longReserve: CGFloat {
        magnifies ? app.magnificationRadius * app.magnificationPeak * 2 : 0
    }

    private func shelf(_ solved: Solved) -> some View {
        Group {
            if isOverflowing(solved) {
                row(solved)
                    .offset(x: vertical ? 0 : scroll, y: vertical ? scroll : 0)
                    // Frame *then* clip. Clipping first applies the shape to
                    // the row's own bounds, which contain it by definition -
                    // a no-op - and items ran straight off the end of the
                    // plate and off the screen.
                    .frame(width: vertical ? solved.restCross : plateLength(solved),
                           height: vertical ? plateLength(solved) : solved.restCross,
                           alignment: contentAlignment)
                    .clipShape(LongAxisClip(vertical: vertical, headroom: crossHeadroom + 24))
            } else {
                // Let the layout size itself so the plate matches it exactly.
                row(solved)
            }
        }
        // The panel catches the scroll wheel and pushes it here. Applied
        // straight, with no animation, so the row tracks the fingers 1:1 the
        // way the trackpad expects; the OS already supplies momentum as a
        // tail of ordinary events.
        .onChange(of: ScrollRelay.shared.tick) { _, _ in
            scroll = clampedScroll(scroll + ScrollRelay.shared.delta, solved)
        }
        .background(alignment: edgeAlignment) {
            MaterialBackground(material: settings.material,
                               glass: settings.glass,
                               radius: chrome.radius)
        }
        .overlay {
            // allowsHitTesting(false) is essential: an overlay takes part in
            // SwiftUI hit testing whatever the underlying NSView's hitTest
            // returns, and without it this pane swallowed every click.
            HoverCatcher { point in
                if point == nil {
                    withAnimation(.easeOut(duration: 0.14)) { cursor = nil }
                } else {
                    // Instant. Springing the entry made icons take ~0.4s to
                    // reach full size, which reads as lag; the Dock tracks the
                    // cursor exactly.
                    cursor = point
                }
            }
            .allowsHitTesting(false)
        }
        // Split to opposite ends: a pair of arrows huddled together at one
        // end says nothing about which way the content runs.
        .overlay(alignment: vertical ? .top : .leading) { overflowChevron(back: true, solved) }
        .overlay(alignment: vertical ? .bottom : .trailing) { overflowChevron(back: false, solved) }
    }

    private func row(_ solved: Solved) -> some View {
        Group {
            if vertical {
                VStack(spacing: 0) { slots(solved) }
            } else {
                HStack(spacing: 0) { slots(solved) }
            }
        }
        .padding(chrome.padding)
    }

    private func slots(_ solved: Solved) -> some View {
        let incoming = incomingSlot(solved)
        // Enumerated for the per-slot geometry, but identified by the item.
        return Group {
            ForEach(Array(solved.slots.enumerated()), id: \.element.id) { index, slot in
                switch slot {
                case .separator:
                    separator
                        .padding(vertical ? .top : .leading, solved.gaps[index])
                case .grip:
                    grip
                        .padding(vertical ? .top : .leading, solved.gaps[index])
                case .item(let entry):
                    tile(entry,
                         solved: solved,
                         scale: solved.scales[index],
                         shift: solved.offsets[index] + reorderShift(entry, solved)
                              + incomingShift(entry, solved, slot: incoming))
                        .padding(vertical ? .top : .leading, solved.gaps[index])
                        // The row parts for an icon on its way out of a group.
                        .animation(.snappy(duration: 0.24), value: incoming)
                        // Recorded outside body evaluation, so the drop knows
                        // which gap it was aiming at once the gesture ends.
                        .onChange(of: incoming) { _, new in lastIncoming = new }
                }
            }
            // Padded to match `gripExtent`, which budgets a gap before each.
            // Without them the rendered row was two gaps shorter than every
            // length formula assumed - the plate, the scroll limit and the
            // hover label all measure against `restLength`.
            addButton
                .padding(vertical ? .top : .leading, chrome.itemGap)
        }
    }

    // MARK: Live reordering

    /// How far an item slides to open a gap for the one being dragged.
    ///
    /// This is what makes a drag feel like the Dock rather than like moving a
    /// sticker: the row parts *while* you drag, so the drop position is
    /// visible before you let go.
    /// Where an icon being carried out of a group would land, as a slot index.
    ///
    /// The sheet lives in another window, so the only thing shared is the
    /// pointer - see DragOut. Converting it to a position along the shelf is
    /// enough to know which two tiles it falls between.
    private func incomingSlot(_ solved: Solved) -> Int? {
        guard DragOut.shared.isCarrying, let window = shelfWindow else { return nil }
        let point = DragOut.shared.location
        let frame = window.frame
        // Screen coordinates run up from the bottom; the shelf measures along
        // its own axis from its leading edge.
        let along = vertical ? (frame.maxY - point.y) : (point.x - frame.minX)
        guard along > 0, along < (vertical ? frame.height : frame.width) else { return nil }

        let movable = solved.entries.filter(\.isDraggable)
        let centers = restCenters(of: movable, solved)
        // The exact inverse of what the hover label does on its way out -
        // see `shelfInset`. Without the inset the gap opened a fixed distance
        // from where the pointer actually was.
        return ShelfMetrics.slot(atPanelPosition: Double(along), centres: centers,
                                 padding: chrome.padding, scroll: scroll,
                                 inset: shelfInset(solved))
    }

    /// How far a tile steps aside to open that gap.
    private func incomingShift(_ entry: Entry, _ solved: Solved, slot: Int?) -> CGFloat {
        guard let slot else { return 0 }
        let movable = solved.entries.filter(\.isDraggable)
        guard let index = movable.firstIndex(where: { $0.id == entry.id }), index >= slot
        else { return 0 }
        return iconGeometry.width + chrome.itemGap
    }

    private func reorderShift(_ entry: Entry, _ solved: Solved) -> CGFloat {
        guard let drag else { return 0 }
        let movable = solved.entries.filter(\.isDraggable)
        guard let index = movable.firstIndex(where: { $0.id == entry.id }) else { return 0 }

        if entry.id == drag.id { return dragTranslation }
        return DockMagnification.gapShift(for: index, from: drag.from, to: drag.destination,
                                          gapSize: longLength(movable[drag.from].item) + chrome.itemGap)
    }

    private func reorderGesture(_ entry: Entry, _ solved: Solved) -> some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .named("shelf"))
            .onChanged { value in
                guard entry.isDraggable else { return }
                let movable = solved.entries.filter(\.isDraggable)
                guard let from = movable.firstIndex(where: { $0.id == entry.id }) else { return }

                // Starting a drag is an implicit "I want to arrange these
                // myself", so take ownership of the mirrored Dock apps now
                // rather than at the end - otherwise a widget cannot be put
                // between two icons at all, because mirroring pins every app
                // after every widget.
                if drag == nil, app.isMirroringApps { app.adoptSystemApps() }

                let translation = vertical ? value.translation.height : value.translation.width
                let centers = restCenters(of: movable, solved)
                let destination = Geometry.reorderIndex(
                    centers: centers, from: from,
                    position: Double(centers[from] + Double(translation)),
                    direction: Double(translation)
                )
                // Resting over another tile means "combine", not "move past".
                let carried = Double(centers[from]) + Double(translation)
                let candidate = dropTarget(near: carried, from: from,
                                           movable: movable, centers: centers, solved: solved)
                armDwell(for: candidate)

                let held = drag?.groupTarget
                // While a drop is armed the row stops parting: the gap would
                // say "insert here" and the highlight would say "combine",
                // and only one of those can be true.
                let wanted = held == nil ? destination : from

                // Never animated: the tile must stick to the cursor.
                dragTranslation = translation

                // Only the row's response to it springs.
                if drag?.id != entry.id || drag?.destination != wanted
                    || drag?.groupTarget != held {
                    withAnimation(.snappy(duration: 0.18)) {
                        drag = DragState(id: entry.id, from: from,
                                         destination: wanted, groupTarget: held)
                    }
                }
            }
            .onEnded { _ in
                guard let current = drag else { return }
                dwell?.cancel()
                dwell = nil
                dwellOver = nil

                if let target = current.groupTarget,
                   let onto = solved.entries.first(where: { $0.id == target }) {
                    // A little overshoot, so the plate settles around the two
                    // icons the way an iOS folder closes rather than simply
                    // arriving. The target is already held at 1.14 by the
                    // drop highlight, so the spring reads as it relaxing.
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.68)) {
                        app.combine(entry.id, into: target, named: onto.label)
                        drag = nil
                    }
                    dragTranslation = 0
                    return
                }

                let movable = solved.entries.filter(\.isDraggable)
                var order = movable.map(\.id)
                if current.from != current.destination,
                   order.indices.contains(current.from),
                   order.indices.contains(current.destination) {
                    order.insert(order.remove(at: current.from), at: current.destination)
                }
                withAnimation(.snappy(duration: 0.22)) {
                    app.reorder(order)
                    drag = nil
                }
                dragTranslation = 0
            }
    }

    /// The tile the dragged one is sitting on top of, if it is far enough on.
    ///
    /// Half a tile is deliberately generous at the edges: dropping *between*
    /// two tiles must stay the easy gesture, so only the middle of a tile
    /// counts as landing on it.
    private func dropTarget(near carried: Double, from: Int, movable: [Entry],
                            centers: [Double], solved: Solved) -> UUID? {
        for (index, candidate) in movable.enumerated() where index != from {
            guard candidate.canReceiveDrop else { continue }
            let reach = Double(longLength(candidate.item)) * 0.35
            if abs(centers[index] - carried) <= reach { return candidate.id }
        }
        return nil
    }

    /// Starts, restarts or cancels the hold that arms a drop.
    private func armDwell(for candidate: UUID?) {
        guard candidate != dwellOver else { return }
        dwell?.cancel()
        dwellOver = candidate
        guard let candidate else {
            if drag?.groupTarget != nil {
                withAnimation(.snappy(duration: 0.18)) { drag?.groupTarget = nil }
            }
            return
        }
        dwell = Task { @MainActor in
            // Long enough that passing over a tile on the way somewhere else
            // does not arm it, short enough to feel deliberate rather than slow.
            try? await Task.sleep(for: .milliseconds(550))
            guard !Task.isCancelled, dwellOver == candidate, drag != nil else { return }
            withAnimation(.snappy(duration: 0.2)) { drag?.groupTarget = candidate }
        }
    }

    private func restCenters(of movable: [Entry], _ solved: Solved) -> [Double] {
        var centers: [Double] = []
        var cursor: CGFloat = 0
        for entry in movable {
            let length = longLength(entry.item)
            centers.append(Double(cursor + length / 2))
            cursor += length + chrome.itemGap
        }
        return centers
    }

    // MARK: Tiles

    private func tile(_ entry: Entry, solved: Solved,
                      scale magnification: CGFloat, shift: CGFloat) -> some View {
        let size = baseSize(entry.item)
        // Captured as plain values: the keyframe closures are @Sendable and
        // cannot reach back into main-actor view state.
        let bounceX: CGFloat = vertical ? (position == .left ? 1 : -1) : 0
        let bounceY: CGFloat = vertical ? 0 : -1
        let peak = bouncePeak

        return TileContent(item: entry.item,
                           scale: scale,
                           position: position,
                           isRunning: isRunning(entry.item),
                           now: app.now) { menu(for: entry) }
            .equatable()
            // Only widgets read this. An icon already answers the pointer by
            // magnifying, and a second affordance on top would be noise.
            .environment(\.widgetHovered, entry.item.isWidget && hoveredID == entry.id)
            // The frame grows along the shelf only. That is what Apple's Dock
            // does: the plate gets longer so neighbours are pushed aside, but
            // its thickness never changes and icons simply grow out of it.
            // Growing both axes inflated the whole shelf on hover; holding
            // both fixed forced every item to be nudged by hand, which slid
            // the entire row when the pointer crossed a wide widget.
            .frame(width: size.width, height: size.height)
            // Only non-widgets get a hit shape at all - see TileHitShape.
            .modifier(TileHitShape(filled: !entry.item.isWidget))
            // Armed as a drop target: iOS grows the tile under your finger and
            // puts a plate behind it, which is the whole signal that releasing
            // will combine rather than insert.
            .background {
                if drag?.groupTarget == entry.id {
                    RoundedRectangle(cornerRadius: size.height * 0.26, style: .continuous)
                        .fill(Color.primary.opacity(0.22))
                        .padding(-size.height * 0.06)
                }
            }
            .scaleEffect(drag?.groupTarget == entry.id ? 1.14 : 1)
            .scaleEffect(magnification, anchor: magnificationAnchor)
            .frame(width: vertical ? size.width : size.width * magnification,
                   height: vertical ? size.height * magnification : size.height)
            .offset(x: vertical ? 0 : shift, y: vertical ? shift : 0)
            .keyframeAnimator(initialValue: CGFloat.zero,
                              trigger: bounceTick[entry.id] ?? 0) { view, lift in
                view.offset(x: bounceX * lift, y: bounceY * lift)
            } keyframes: { _ in
                // One arc per tick. Each LinearKeyframe interpolates only
                // between its own endpoints, so there is no cross-keyframe
                // tangent to round the contact off or push the icon below
                // rest - see Bounce.
                KeyframeTrack {
                    LinearKeyframe(peak, duration: Bounce.arc / 2, timingCurve: Bounce.rise)
                    LinearKeyframe(0, duration: Bounce.arc / 2, timingCurve: Bounce.fall)
                }
            }
            .zIndex(drag?.id == entry.id ? 2 : 0)
            // Grows out of the plate and shrinks back into it, anchored on the
            // docked edge - the same anchor magnification uses, so a tile
            // arrives the way a magnified one grows rather than fading in from
            // nowhere. Without this an added or removed item simply popped.
            // A poofed tile leaves instantly: the poof *is* the disappearance,
            // and shrinking the icon underneath it plays two animations over
            // each other. Everything else grows out of the plate and shrinks
            // back into it.
            .transition(poofing.contains(entry.id)
                        ? .identity
                        : .scale(scale: 0.32, anchor: magnificationAnchor)
                            .combined(with: .opacity))
            // Widgets take it too now, but only those with somewhere to go -
            // a panel to show or an app to open: a tap gesture whose action is
            // a no-op still *consumes* the tap.
            .modifier(TapToOpen(enabled: entry.opens,
                                 label: entry.actionLabel) {
                // Anchored to the tile clicked, worked out now. The anchor
                // used to be whatever the last hover had left behind, and
                // after the shelf slid in or its tiles changed size that was
                // another tile's, so a panel opened beside the wrong one.
                if let index = solved.slots.firstIndex(where: {
                    if case .item(let other) = $0 { return other.id == entry.id }
                    return false
                }), let anchor = screenAnchor(target(at: index, solved)) {
                    hoverAnchor = anchor
                }
                open(entry)
            })
            .gesture(reorderGesture(entry, solved))
            // Collapsing children puts the label on the tile, but it also
            // hides a widget's own controls from assistive tech, so only do it
            // where the tile really is one button.
            .accessibilityElement(children: entry.item.isWidget ? .contain : .ignore)
            .accessibilityLabel(entry.label)
            .accessibilityAddTraits(entry.item.isWidget ? [] : .isButton)
    }

    /// Items grow away from the screen edge, never into it.
    private var magnificationAnchor: UnitPoint {
        switch position {
        case .bottom: .bottom
        case .left: .leading
        case .right: .trailing
        }
    }

    private func open(_ entry: Entry) {
        // The Dock drops its label the moment you click, and here it would
        // otherwise sit over whatever the click just opened.
        TooltipWindow.shared.hide()

        // Anything other than the open group or panel dismisses it: clicking
        // another tile is a decision to do something else.
        if entry.item.group?.id != GroupWindow.shared.openGroupID {
            GroupWindow.shared.close()
        }
        if entry.item.widget?.id != WidgetDetailWindow.shared.openWidgetID {
            WidgetDetailWindow.shared.close()
        }
        if let group = entry.item.group {
            GroupWindow.shared.toggle(
                group,
                anchor: hoverAnchor ?? .zero,
                edge: position,
                iconSide: iconGeometry.icon,
                open: { AppCatalog.shared.open($0) },
                remove: { item in
                    let landing = lastIncoming
                    withAnimation(.snappy(duration: 0.24)) {
                        app.removeFromGroup(item.id, group: group.id, at: landing)
                    }
                    lastIncoming = nil
                },
                rename: { name in
                    var updated = group
                    updated.name = name
                    app.replaceItem(group.id, with: .group(updated))
                })
            return
        }
        if let widget = entry.item.widget {
            // Controls inside the card win this click; only the card itself
            // reaches here. Verified with a hosting-view harness.
            //
            // A widget with more to say opens its own panel - the whole day's
            // events rather than the next one, every battery rather than the
            // Mac's. The rest open the app they are about.
            if WidgetDetail.exists(for: widget.kind) {
                WidgetDetailWindow.shared.toggle(
                    widget,
                    context: WidgetContext(position: position, now: app.now),
                    anchor: hoverAnchor ?? .zero,
                    edge: position,
                    host: shelfWindow?.frame ?? .zero)
                return
            }
            guard let target = WidgetCatalog.openTarget(widget.kind) else { return }
            AppCatalog.shared.open(target)
            return
        }
        // Only a cold launch bounces. Clicking a running app just brings it
        // forward, which is all AppCatalog.open does for it, and the Dock
        // stays still for that.
        // Bounce first so the click has an answer immediately, then stop the
        // moment the launch settles - whether it succeeded or never started.
        if !isRunning(entry.item) { bounce(entry) }
        AppCatalog.shared.open(entry.item) { _ in stopBounce(entry.id) }
    }

    /// Apple's Dock bounces until the app checks in: the same height every
    /// time, about one a second, never a decaying flourish that stops while
    /// the app is still starting.
    ///
    /// Driven by ticks rather than a repeating keyframe track, because
    /// `repeating: false` snaps the offset home mid-air - this way the arc in
    /// flight is always allowed to land.
    private func bounce(_ entry: Entry) {
        guard case .app = entry.item else { return }
        bounceTask[entry.id]?.cancel()
        bounceTask[entry.id] = Task { @MainActor in
            for _ in 0 ..< Int(Bounce.giveUp / Bounce.period) {
                bounceTick[entry.id, default: 0] += 1
                try? await Task.sleep(for: .seconds(Bounce.period))
                // Fed by NSWorkspace.didLaunchApplication - the Dock's own
                // stop signal. Some apps never post it, hence the bound.
                if Task.isCancelled || isRunning(entry.item) { return }
            }
        }
    }

    /// Ends a launch bounce. The arc in flight still lands: the keyframe
    /// track runs to completion on its own once triggered.
    private func stopBounce(_ id: UUID) {
        bounceTask[id]?.cancel()
        bounceTask[id] = nil
    }

    private func isRunning(_ item: DockItem) -> Bool {
        guard case .app(_, let bundleID, _) = item else { return false }
        return AppCatalog.shared.isRunning(bundleID: bundleID)
    }

    // MARK: Hover label

    /// What the label should say and where it should point, in shelf
    /// coordinates. Equatable so the window is only touched when it changes.
    private struct HoverTarget: Equatable {
        /// Nil for a widget, which shows its own content: a label naming it is
        /// noise. The rest of the target still applies - a widget needs an
        /// anchor for its detail panel just as an app tile needs one for its
        /// group.
        var text: String?
        var along: CGFloat
        var cross: CGFloat
        /// The icon's centre in shelf coordinates, for the removal poof.
        /// Carried here rather than written to state: `hoverTarget` is
        /// evaluated during body, where a state write is not allowed.
        var centre: CGPoint
        /// Which item this is, so a widget under the pointer can be told.
        var id: UUID
    }

    /// How far the shelf sits inside its own panel, along the long axis.
    ///
    /// The panel is `plateLength + longReserve` long and centres the shelf in
    /// it, so every conversion between a panel position and a position along
    /// the row needs this. It lives here because it is needed in both
    /// directions - the hover label converts outward, the drop target
    /// converts inward - and the two drifting apart is what put the gap the
    /// shelf opens somewhere other than under the pointer.
    ///
    /// An overflowing row is pinned to `plateLength` and does not grow by
    /// `totalExtra` at all.
    private func shelfInset(_ solved: Solved) -> CGFloat {
        ShelfMetrics.inset(plateLength: plateLength(solved),
                           longReserve: longReserve,
                           restLength: solved.restLength,
                           totalExtra: solved.totalExtra,
                           overflowing: isOverflowing(solved))
    }

    /// Where a slot's centre actually sits, measured from the plate's leading
    /// edge, with the shelf's growth taken into account.
    /// A slot's centre as a position in the panel.
    ///
    /// Goes through `ShelfMetrics.panelPosition` rather than spelling the sum
    /// out again: the same arithmetic written twice is how the outward and
    /// inward conversions came to disagree in the first place.
    ///
    /// Deliberately in *rendered* space (`viewCenters`) while `incomingSlot`
    /// works in rest space. A label points at the icon the user can see, which
    /// magnification has moved; a dropped icon lands in a slot, which exists
    /// at rest. They are inverses of each other only with magnification off,
    /// and that is correct rather than an oversight.
    private func plateCentre(of index: Int, _ solved: Solved) -> CGFloat {
        CGFloat(ShelfMetrics.panelPosition(slotCentre: Double(solved.viewCenters[index]),
                                           padding: chrome.padding,
                                           scroll: scroll,
                                           inset: 0))
    }

    private func hoverTarget(_ solved: Solved) -> HoverTarget? {
        guard drag == nil, let pointer else { return nil }
        guard let hit = solved.slots.indices.first(where: { index in
            guard case .item = solved.slots[index] else { return false }
            return abs(pointer - plateCentre(of: index, solved))
                <= solved.lengths[index] * solved.scales[index] / 2
        }) else { return nil }
        return target(at: hit, solved)
    }

    /// The hover target for one slot, whether or not the pointer is on it.
    private func target(at hit: Int, _ solved: Solved) -> HoverTarget? {
        guard case .item(let entry) = solved.slots[hit] else { return nil }

        let along = plateCentre(of: hit, solved) + shelfInset(solved)
        // Point at the far edge of the magnified tile, which is what the Dock
        // measures its label against. A widget's icon does not grow out of the
        // plate, so its own outer edge is the plate's - anything further out
        // and its panel floats away from the tile it belongs to.
        let growth = entry.item.isWidget ? 0 : iconGrowth
        let cross: CGFloat = switch position {
        case .bottom: crossHeadroom - growth
        case .left: solved.restCross + growth
        case .right: crossHeadroom - growth
        }
        // `cross` above points at the far edge of the magnified tile - where
        // a label belongs - which is most of a tile from the icon's middle.
        //
        // The middle has to be measured from the plate's own near edge, and
        // which side that is depends on the position: a left shelf is pinned
        // to the leading edge with its headroom beyond it, so there is no
        // headroom to skip past. `iconGeometry` also swaps axes - the cross
        // extent is `height` lying down and `width` on a side - and using the
        // wrong one put the removal poof out over the desktop.
        let crossCentre: CGFloat = switch position {
        case .bottom: crossHeadroom + chrome.padding + iconGeometry.height / 2
        case .left: chrome.padding + iconGeometry.width / 2
        case .right: crossHeadroom + chrome.padding + iconGeometry.width / 2
        }
        let centre = CGPoint(x: along, y: crossCentre)
        return HoverTarget(text: entry.item.isWidget ? nil : entry.label,
                           along: along, cross: cross, centre: centre, id: entry.id)
    }

    /// Where a target sits on screen. SwiftUI measures down from the top of
    /// the content; AppKit screen coordinates go up from the bottom.
    private func screenAnchor(_ target: HoverTarget?) -> CGPoint? {
        guard let target, let frame = shelfWindow?.frame else { return nil }
        return switch position {
        case .bottom: CGPoint(x: frame.minX + target.along, y: frame.maxY - target.cross)
        case .left, .right: CGPoint(x: frame.minX + target.cross, y: frame.maxY - target.along)
        }
    }

    private func applyHoverLabel(_ target: HoverTarget?) {
        guard let target, let window = shelfWindow else {
            TooltipWindow.shared.hide()
            return
        }
        let frame = window.frame
        guard let anchor = screenAnchor(target) else { return }
        // Kept so an opened group or widget panel can grow from the tile that
        // was clicked: you have to be hovering a tile to click it, so this is
        // the right anchor by the time `open` runs - which is why every tile
        // has to yield one. While widgets were excluded from `hoverTarget`
        // their panels opened from `.zero`, in the corner of the screen, or
        // from whichever app tile was hovered last.
        hoverAnchor = anchor
        hoverIconCentre = switch position {
        case .bottom: CGPoint(x: frame.minX + target.centre.x,
                              y: frame.maxY - target.centre.y)
        case .left, .right: CGPoint(x: frame.minX + target.centre.y,
                                    y: frame.maxY - target.centre.x)
        }
        if let text = target.text {
            TooltipWindow.shared.show(text, anchor: anchor, edge: position)
        } else {
            // Moving onto a widget has to take the previous tile's label with
            // it, the same way moving off the shelf does.
            TooltipWindow.shared.hide()
        }
    }

    // MARK: Overflow

    @ViewBuilder
    private func overflowChevron(back: Bool, _ solved: Solved) -> some View {
        if isOverflowing(solved) {
            chevron(back, solved).padding(3)
        }
    }

    private func chevron(_ back: Bool, _ solved: Solved) -> some View {
        let symbol = vertical ? (back ? "chevron.up" : "chevron.down")
                              : (back ? "chevron.left" : "chevron.right")
        let limit = scrollLimit(solved)
        let disabled = back ? scroll >= 0 : scroll <= -limit
        return Button {
            withAnimation(.easeOut(duration: 0.18)) {
                scroll = clampedScroll(scroll + (back ? 120 : -120), solved)
            }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 16, height: 16)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .opacity(disabled ? 0.25 : 0.7)
        .disabled(disabled)
        .accessibilityLabel(back ? "Scroll back" : "Scroll forward")
    }

    private func scrollLimit(_ s: Solved) -> CGFloat { max(0, s.restLength - maxLength) }

    private func clampedScroll(_ value: CGFloat, _ s: Solved) -> CGFloat {
        min(0, max(-scrollLimit(s), value))
    }

    // MARK: Chrome

    private var separator: some View {
        Group {
            if vertical {
                Rectangle().frame(width: 28 * Geometry.contentScale(scale), height: 1)
            } else {
                Rectangle().frame(width: 1, height: 28 * Geometry.contentScale(scale))
            }
        }
        .foregroundStyle(Color.primary.opacity(0.18))
        .padding(vertical ? .vertical : .horizontal, 3)
    }

    /// Visible way to reach the widget library - adding a widget is the whole
    /// point of the shelf, so it needs an affordance on the shelf itself.
    private var addButton: some View {
        let geo = iconGeometry
        let side = geo.icon * 0.62
        return Button {
            LibraryWindow.shared.show(app: app)
        } label: {
            Image(systemName: "plus")
                .font(.system(size: side * 0.52, weight: .semibold))
                .foregroundStyle(Color.primary.opacity(addHovered ? 0.85 : 0.45))
                .frame(width: side, height: side)
                .background {
                    RoundedRectangle(cornerRadius: side * 0.28, style: .continuous)
                        .fill(Color.primary.opacity(addHovered ? 0.14 : 0.07))
                }
                .frame(width: geo.width, height: geo.height)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.14)) { addHovered = inside }
        }
        .help("Add a widget")
        .accessibilityLabel("Add a widget")
    }

    private var grip: some View {
        let capsule = vertical
            ? CGSize(width: chrome.gripLong, height: chrome.gripShort)
            : CGSize(width: chrome.gripShort, height: chrome.gripLong)

        return Capsule()
            .fill(Color.primary.opacity(0.22))
            .frame(width: capsule.width, height: capsule.height)
            .frame(width: vertical ? chrome.gripCross : 24,
                   height: vertical ? 24 : chrome.gripCross)
            .contentShape(.rect)
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        // Applied as a step from the size it is *now*, not
                        // recomputed from where the drag began. Anchoring
                        // absolutely lets travel past a limit accumulate
                        // invisibly: overshoot the maximum and dragging back
                        // does nothing until the overshoot has been undone.
                        // From the current size, a clamp simply stops, and the
                        // first movement the other way is felt immediately.
                        let delta = Geometry.resizeDelta(from: value.startLocation,
                                                         to: value.location, position: position)
                        let step = delta - (lastResizeDelta ?? 0)
                        lastResizeDelta = delta
                        ShelfResize.isDragging = true
                        app.setScale(Geometry.resizedScale(scale, delta: step,
                                                           position: position,
                                                           hasWidgets: hasWidgets))
                    }
                    .onEnded { _ in
                        ShelfResize.isDragging = false
                        lastResizeDelta = nil
                    }
            )
            .accessibilityLabel("Dock size")
            .accessibilityValue("\(Int((scale * 100).rounded())) percent")
            .accessibilityAdjustableAction { direction in
                app.setScale(scale + (direction == .increment ? 0.05 : -0.05))
            }
    }

    // MARK: Menu

    @ViewBuilder
    /// Shaped like the real Dock's: pinning and file actions tucked into an
    /// Options submenu, then the open/quit action, then our own additions.
    ///
    /// Two of the Dock's own Options entries are missing on purpose. "Open at
    /// Login" writes to the background-task database and "Assign To" sets a
    /// Space, and both are private to Apple - a menu item that silently does
    /// nothing is worse than one that is not there.
    private func menu(for entry: Entry) -> some View {
        Menu("Options") {
            if entry.isRunningApp {
                Button("Keep in Dock") {
                    withAnimation(.snappy(duration: 0.2)) { app.addItem(entry.item) }
                }
            } else {
                Button("Remove from Dock", role: .destructive) { remove(entry) }
            }
            if let group = entry.item.group {
                Button("Rename Group…") { rename(group) }
                Menu("Tint") {
                    ForEach(GroupTint.allCases, id: \.self) { tint in
                        Button(tint.title) {
                            var updated = group
                            updated.tint = tint
                            app.replaceItem(group.id, with: .group(updated))
                        }
                    }
                }
                Button("Ungroup") {
                    withAnimation(.snappy(duration: 0.22)) { app.ungroup(group.id) }
                }
            }
            if entry.item.isWidget {
                Button("Widget Settings…") {
                    // This widget's settings, not whichever is first: the
                    // tab used to open on the first widget, which read as
                    // a near-empty pane for the one that was clicked.
                    SettingsWindow.shared.show(app: app, tab: "Widgets",
                                               widget: entry.item.widget?.id)
                }
            }
            if let widget = entry.item.widget,
               WidgetCatalog.entry(widget.kind)?.supportsCompact == true {
                Button(widget.expanded ? "Collapse" : "Expand") {
                    var updated = widget
                    updated.expanded.toggle()
                    withAnimation(.snappy(duration: 0.22)) { app.updateWidget(updated) }
                }
            }
            // setCity was written and never called from anywhere. It matters
            // more than most settings: macOS will not show an accessory app
            // the location prompt, so typing a city is how the weather widget
            // is made to work at all, and hunting for it in Settings is a poor
            // route to the only thing that fixes an empty tile.
            if let widget = entry.item.widget, widget.kind == .weather {
                Button("Set Location…") { setCity(widget) }
            }
            if entry.item.fileRef != nil {
                Button("Show in Finder") { AppCatalog.shared.reveal(entry.item) }
            }
        }
        // Top level, not tucked under Options: grouping is a primary action
        // here, and Options is where the Dock keeps its pin and file commands.
        // No "New Group" here any more: it could only ever make a group of
        // one, which the shelf now dissolves on sight. Groups are made by
        // dropping one icon onto another.
        // Top level, not nested inside Options. A Menu inside a Menu inside a
        // contextMenu is where SwiftUI's menus stop responding - the submenu
        // opens and its items do nothing.
        if let widget = entry.item.widget,
           let catalog = WidgetCatalog.entry(widget.kind), !catalog.variants.isEmpty {
            Divider()
            Menu("Style") {
                ForEach(catalog.variants.indices, id: \.self) { index in
                    let variant = catalog.variants[index]
                    Button(variant.title) {
                        var updated = widget
                        for (key, value) in variant.overrides { updated.config.set(key, value) }
                        withAnimation(.snappy(duration: 0.26)) { app.updateWidget(updated) }
                    }
                }
            }
        }
        if entry.canBeGrouped, !app.groups.isEmpty {
            Divider()
            Menu("Add to Group") {
                ForEach(app.groups) { target in
                    Button(target.name) {
                        withAnimation(.snappy(duration: 0.22)) {
                            // Same path as dropping it there by hand.
                            app.combine(entry.id, into: target.id, named: target.name)
                        }
                    }
                }
            }
        }
        if !entry.item.isWidget {
            Divider()
            if case .app(_, let bundleID, _) = entry.item,
               AppCatalog.shared.isRunning(bundleID: bundleID) {
                Button("Quit") { AppCatalog.shared.quit(bundleID: bundleID) }
            } else {
                Button("Open") { open(entry) }
            }
        }
        // Spacers were implemented end to end - drawn, sized, labelled, and
        // converted both ways to Apple's own spacer tiles - with no way for
        // anyone to make one. Here rather than in the library because a
        // spacer is about where it goes, so it is inserted next to the tile
        // that was clicked rather than appended to the end.
        Divider()
        Menu("Add Spacer") {
            Button("Small") { addSpacer(.small, after: entry) }
            Button("Regular") { addSpacer(.regular, after: entry) }
        }
        Divider()
        Button("Add Widget…") { LibraryWindow.shared.show(app: app) }
        Button("Dock Settings…") { SettingsWindow.shared.show(app: app) }
    }

    private func addSpacer(_ size: SpacerSize, after entry: Entry) {
        withAnimation(.snappy(duration: 0.24)) {
            app.insertItem(.spacer(id: UUID(), size: size), after: entry.id)
        }
    }

    /// Removes a tile the way the Dock does: the system poof, played where
    /// the icon is, and the row closes the gap behind it.
    ///
    /// `NSAnimationEffect.poof` is the actual animation macOS uses when
    /// something is dragged off the Dock - not an imitation of it - so this is
    /// the one part of the shelf that cannot drift from the real thing.
    private func remove(_ entry: Entry) {
        poofing.insert(entry.id)
        if let centre = hoverIconCentre {
            // The one deliberate deprecation warning in this project.
            //
            // `NSAnimationEffect` is deprecated and its suggested replacement
            // is a *cursor* - Apple withdrew the API without offering another
            // way to play this animation. It is the Dock's own poof rather
            // than an imitation of it, and it still renders on macOS 26
            // (verified: ~53k pixels of the screen change when it fires), so
            // the warning is worth more than a hand-drawn puff of smoke.
            NSAnimationEffect.poof.show(centeredAt: centre, size: .zero)
        }
        // The row still closes the gap smoothly; only the icon is instant.
        withAnimation(.snappy(duration: 0.24)) { app.removeItem(entry.id) }
        let id = entry.id
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(600))
            poofing.remove(id)
        }
    }

    /// Typing a city by hand, for when the location prompt never arrives or
    /// the answer was no. Empty clears it back to "wherever I am".
    private func setCity(_ widget: WidgetInstance) {
        let policy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        defer { NSApp.setActivationPolicy(policy) }

        let alert = NSAlert()
        alert.messageText = "Weather Location"
        alert.informativeText = "Leave empty to use your current location."
        alert.addButton(withTitle: "Set")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.stringValue = widget.config.string("city")
        field.placeholderString = "Current location"
        alert.accessoryView = field

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        var updated = widget
        updated.config.set("city", .string(field.stringValue.trimmingCharacters(in: .whitespaces)))
        app.updateWidget(updated)
    }

    /// An accessory agent is never frontmost, so a modal sheet needs the same
    /// brief promotion to a regular app that the automation prompt does.
    private func rename(_ group: DockGroup) {
        let policy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        defer { NSApp.setActivationPolicy(policy) }

        let alert = NSAlert()
        alert.messageText = "Rename Group"
        alert.informativeText = "This is the name shown when you hover the group."
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.stringValue = group.name
        alert.accessoryView = field

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        var updated = group
        updated.name = name
        app.replaceItem(group.id, with: .group(updated))
    }

    /// Settings lists the same items, so the naming lives on DockItem now.
    private func label(for item: DockItem) -> String { item.displayName }
}

/// The drawn part of a tile, isolated so SwiftUI can skip it.
///
/// Magnification changes only geometry, but a pointer move re-evaluates the
/// shelf's body - and without this the body of every widget (charts, canvases,
/// rings) re-ran on every mouse move.
/// The part of a tile that only changes when its *content* does.
///
/// The context menu lives in here rather than on the magnification chain
/// outside. SwiftUI builds a `contextMenu`'s content eagerly, so out there it
/// rebuilt every tile's whole menu on every pointer move - measured at roughly
/// half the cost of the per-move rebuild. In here the `Equatable` gate skips
/// it entirely when only the pointer moved.
private struct TileContent<Menu: View>: View, Equatable {
    var item: DockItem
    var scale: Double
    var position: DockPosition
    var isRunning: Bool
    var now: Date
    /// Deliberately absent from `==`: a closure cannot be compared, and its
    /// captures are either value-stable (the entry) or references that stay
    /// current (AppState).
    @ViewBuilder var menu: () -> Menu

    nonisolated static func == (a: TileContent, b: TileContent) -> Bool {
        // Frozen while a menu is open: rebuilding the tile would take the
        // menu down with it. See MenuTracking.
        if MenuTracking.isOpen { return true }
        guard a.scale == b.scale, a.position == b.position,
              a.isRunning == b.isRunning, a.item == b.item else { return false }
        // Only time-dependent tiles care about the tick; app icons must not
        // redraw once a second for nothing.
        return a.item.isWidget ? a.now == b.now : true
    }

    var body: some View {
        content.contextMenu { menu() }
    }

    @ViewBuilder
    private var content: some View {
        if let widget = item.widget {
            ScaledWidgetTile(instance: widget,
                             context: WidgetContext(position: position, now: now),
                             scale: scale)
        } else {
            DockItemView(item: item, scale: scale, position: position,
                         isRunning: isRunning, showRunningDot: true)
        }
    }
}

/// Adds a tap action only when it is wanted.
///
/// `.onTapGesture` cannot be conditionally applied inline without changing the
/// view's type, and attaching one with an empty closure is not equivalent -
/// it still swallows the gesture.
private struct TapToOpen: ViewModifier {
    var enabled: Bool
    /// What to call the action in assistive tech.
    var label: String
    var action: () -> Void

    func body(content: Content) -> some View {
        if enabled {
            content
                .onTapGesture(perform: action)
                // A tap gesture is not an action as far as VoiceOver is
                // concerned, and a widget tile is a *container* - it keeps its
                // children so their own controls stay reachable, which rules
                // out the button trait that carries an app tile's activation.
                // Without this a widget's panel is reachable by mouse only.
                .accessibilityAction(named: label, action)
        } else {
            content
        }
    }
}
