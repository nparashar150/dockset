import AppKit
import SwiftUI

/// Magnification maths for the shelf.
///
/// This began as a custom `Layout`, which was the wrong tool: a tile carries an
/// explicit `.frame(width:height:)` so it is *rigid*, and a rigid subview
/// ignores the size a layout proposes. The layout dutifully computed magnified
/// sizes and every icon rendered at its resting size anyway.
///
/// Doing it in the view instead is both simpler and correct: each tile is
/// framed at `natural × scale` so an ordinary stack pushes its neighbours
/// aside, and the content is scaled to match.
enum DockMagnification {

    /// Rest-space centre of every item along the shelf's long axis.
    static func restCenters(lengths: [CGFloat], gap: CGFloat) -> [CGFloat] {
        var centers: [CGFloat] = []
        var cursor: CGFloat = 0
        for length in lengths {
            centers.append(cursor + length / 2)
            cursor += length + gap
        }
        return centers
    }

    static func scales(pointer: CGFloat?, centers: [CGFloat],
                       peaks: [Double], radius: Double) -> [CGFloat] {
        guard let pointer else { return Array(repeating: 1, count: centers.count) }
        return centers.enumerated().map { index, center in
            let influence = Geometry.influence(distance: abs(Double(pointer - center)), radius: radius)
            return 1 + CGFloat(influence * peaks[index])
        }
    }
}

/// Clips along the shelf's long axis only, so a magnified icon can still grow
/// out of the plate while the row scrolls underneath it.
struct LongAxisClip: Shape {
    var vertical: Bool
    var headroom: CGFloat

    func path(in rect: CGRect) -> Path {
        Path(vertical ? rect.insetBy(dx: -headroom, dy: 0)
                      : rect.insetBy(dx: 0, dy: -headroom))
    }
}

extension DockMagnification {

    /// How far an item slides to open a gap for the one being dragged over it.
    ///
    /// This is what makes a drag feel like the Dock rather than like moving a
    /// sticker: the row parts *while* you drag, so the drop position is
    /// visible before you let go. Items between the item's original slot and
    /// its prospective one shift by one slot's worth; everything else stays.
    static func gapShift(for index: Int, from: Int, to: Int, gapSize: CGFloat) -> CGFloat {
        if from < to, index > from, index <= to { return -gapSize }
        if from > to, index >= to, index < from { return gapSize }
        return 0
    }
}

/// The launch bounce, as gravity rather than as a spline.
///
/// `CubicKeyframe` cannot express this: SwiftUI fits one C¹ curve through the
/// whole track, taking each knot's tangent from its neighbours. That gave a
/// start tangent of zero, so the icon *crept* off the shelf, and a non-zero
/// tangent at the floor, so the arc sailed smoothly through it - rounding off
/// the contact and sinking the icon below its resting place on the way. A
/// thrown ball does the opposite: it leaves at full speed, is motionless only
/// at the apex, and reverses instantly on contact.
///
/// `rise` is y = 2x − x² (constant deceleration) and `fall` is y = x² (free
/// fall), each degree-elevated to the cubic Bezier `UnitCurve` takes.
enum Bounce {
    static let rise = UnitCurve.bezier(startControlPoint: UnitPoint(x: 1.0 / 3, y: 2.0 / 3),
                                       endControlPoint: UnitPoint(x: 2.0 / 3, y: 1))
    static let fall = UnitCurve.bezier(startControlPoint: UnitPoint(x: 1.0 / 3, y: 0),
                                       endControlPoint: UnitPoint(x: 2.0 / 3, y: 1.0 / 3))

    /// Fraction of an icon the tile rises.
    ///
    /// Reasoned, not measured: the Dock here is auto-hidden and will not
    /// reveal for a capture without being restarted, so this is not grounded
    /// the way the removal poof is. The previous 0.55 over 0.40s read as a
    /// small, quick twitch - a launching icon rises most of its own height
    /// and the arc fills most of the second between bounces.
    static let peak: CGFloat = 0.85
    /// One arc, up and back down.
    static let arc: TimeInterval = 0.58
    /// Bounce to bounce. The gap is left to the driver rather than made a
    /// third keyframe, so timer jitter lands in the pause instead of cutting
    /// an arc short.
    static let period: TimeInterval = 1.0
    /// Apps that never report finishing launch.
    static let giveUp: TimeInterval = 20
}

/// Gives a tile an explicit hit shape - but only when it has no interior.
///
/// A widget owns its own controls (play/pause, transport, Connect) and those
/// must receive their own clicks. The previous attempt at that applied an
/// *empty* `contentShape` to a widget tile, on the theory that it clears only
/// the tile's own hit region and leaves descendants hittable. It does not: an
/// empty content shape removes the whole subtree from hit testing, so every
/// control inside every widget was unreachable.
///
/// Verified with a hosting-view harness that delivers a real NSEvent - child
/// taps land with no content shape and with a filled one, and never with an
/// empty one.
public struct TileHitShape: ViewModifier {
    public var filled: Bool

    public init(filled: Bool) { self.filled = filled }

    @ViewBuilder
    public func body(content: Content) -> some View {
        if filled { content.contentShape(Rectangle()) } else { content }
    }
}

/// Whether a dragged icon has been pulled out of an opened group.
///
/// A cross-window drag session would be the general answer, but the only
/// destination that means anything here is "not in this group any more", so
/// leaving the sheet's bounds *is* the whole gesture.
public enum GroupDrag {
    public static func leavesSheet(_ point: CGPoint, sheet: CGSize) -> Bool {
        // An unmeasured sheet must never register a drop: reporting "outside"
        // for a zero size would throw the icon out on the first drag event.
        guard sheet.width > 1, sheet.height > 1 else { return false }
        return point.x < 0 || point.y < 0 || point.x > sheet.width || point.y > sheet.height
    }
}

/// Whether the user is dragging the size grip right now.
///
/// A discrete size change - a widget added, a style switched - should glide.
/// A drag should not: the grip reports a new size on every event, and easing
/// each one over 0.22s stacks dozens of overlapping window animations, so the
/// shelf rubber-bands along behind the pointer instead of tracking it.
///
/// Read from the panel controller, written by the grip. A plain flag rather
/// than observable state: nothing should re-render because of it.
public enum ShelfResize {
    nonisolated(unsafe) public static var isDragging = false
}

/// Whether one of the shelf's menus is open.
///
/// SwiftUI dismisses a context menu when the view hosting it is rebuilt, and
/// a widget tile rebuilds every second because it tracks the clock. The menu
/// therefore died about a second after opening - right as the pointer reached
/// a submenu - which reads as a menu that refuses to be used.
///
/// Read from `TileContent`'s `nonisolated` equality, so it is a plain flag
/// rather than observable state. Written only on the main thread, when menu
/// tracking starts and stops.
public enum MenuTracking {
    nonisolated(unsafe) public static var isOpen = false
}

/// Conversions between a position in the shelf's panel and a slot in its row.
///
/// Extracted because getting these wrong was the single most common defect in
/// this shelf, and always invisibly: the hover label pointed at the wrong
/// icon, the drop gap opened away from the pointer, a dragged icon trailed
/// the cursor. Each was the same class of mistake made in a different place,
/// and none of it was reachable by a test while it lived inside the view.
public enum ShelfMetrics {

    /// How far the shelf sits inside its own panel, along the long axis.
    ///
    /// The panel is `plateLength + longReserve` long and centres the shelf in
    /// it. An overflowing row is pinned to `plateLength` and does not grow by
    /// `totalExtra` at all - the case that made the label drift as the pointer
    /// moved, since `totalExtra` tracks magnification.
    public static func inset(plateLength: CGFloat, longReserve: CGFloat,
                             restLength: CGFloat, totalExtra: CGFloat,
                             overflowing: Bool) -> CGFloat {
        let shelfLong = overflowing ? plateLength : restLength + totalExtra
        return (plateLength + longReserve - shelfLong) / 2
    }

    /// Where a slot's centre sits in the panel.
    public static func panelPosition(slotCentre: Double, padding: CGFloat,
                                     scroll: CGFloat, inset: CGFloat) -> Double {
        slotCentre + Double(padding) + Double(scroll) + Double(inset)
    }

    /// Which slot a panel position falls into, as an insertion index.
    ///
    /// The exact inverse of `panelPosition`, and deliberately written as its
    /// inverse: the two drifting apart is what put the drop gap in the wrong
    /// place while the hover label was correct.
    public static func slot(atPanelPosition position: Double, centres: [Double],
                            padding: CGFloat, scroll: CGFloat, inset: CGFloat) -> Int {
        let along = position - Double(padding) - Double(scroll) - Double(inset)
        return centres.firstIndex { along < $0 } ?? centres.count
    }
}

extension GroupDrag {
    /// How far to offset a dragged icon so its centre sits under the pointer.
    ///
    /// Offsetting by the drag's *translation* instead leaves the icon wherever
    /// on itself the press landed - grab it near an edge and it trails the
    /// pointer by that much for the whole gesture.
    public static func offset(cursor: CGPoint, centre: CGPoint) -> CGSize {
        CGSize(width: cursor.x - centre.x, height: cursor.y - centre.y)
    }
}

/// A borderless panel that can still take the keyboard.
///
/// `NSWindow` refuses key status to a borderless window, and keystrokes only
/// reach the key window - so a text field inside one shows a caret that
/// accepts nothing. That is what stopped a group being renamed. It lives here,
/// rather than beside the one window that needs it, because the rule is not
/// obvious and the codebase has now hit it twice.
public extension CGSize {
    /// The extent across the shelf's short axis, whichever edge it is on.
    func thickness(on edge: DockPosition) -> CGFloat {
        edge.isVertical ? width : height
    }
}

/// Sizing for the strip Apple's Dock reserves on the shelf's behalf.
///
/// See `DockStrut`: the Dock is the only thing that can reserve screen space,
/// so the shelf asks it for a strip of the right thickness and then sits on
/// top of it.
public enum DockStrutMetrics {
    /// What macOS accepts for `com.apple.dock tilesize`.
    public static let tileRange: ClosedRange<Double> = 16 ... 128

    /// Measured once: a tile size of 38 produced a 58 point strip.
    ///
    /// One point is not a curve, which is why nothing relies on this being
    /// exactly right. `DockStrut.claim` measures the strip that actually came
    /// back and the shelf sizes itself from that, so an error here costs a few
    /// points of strip rather than a wrong layout.
    public static let padding: Double = 20

    /// The tile size whose reserved strip should land closest to `strip`.
    ///
    /// Clamped, because a shelf can want more than the largest tile reserves.
    /// It gets the largest and overhangs: covering part of a window beats
    /// covering all of it, and both beat refusing to enter the mode.
    public static func tileSize(forStrip strip: CGFloat) -> Double {
        min(max(Double(strip) - padding, tileRange.lowerBound), tileRange.upperBound)
    }

    /// Height the shelf may draw at, given the strip actually reserved.
    ///
    /// Never larger than the strip. The shelf is the thing that has to give:
    /// drawing past the reservation is exactly the defect this mode exists to
    /// fix, so a shelf that wants more is simply not granted it.
    public static func shelfThickness(wanting wanted: CGFloat,
                                      reserved: CGFloat) -> CGFloat {
        guard reserved > 0 else { return wanted }
        return min(wanted, reserved)
    }
}

public final class KeyablePanel: NSPanel {
    public override var canBecomeKey: Bool { true }

    /// Called when the panel should give up, however that was asked for.
    public var onCancel: (() -> Void)?

    /// Escape closes it. Handled here rather than as a SwiftUI keyboard
    /// shortcut so it still fires while a text field inside is first
    /// responder - a note being written is exactly when you want a way out
    /// that is not aiming for a button.
    public override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    /// And Command-W, for the same reason and by the same route: a shortcut
    /// declared in SwiftUI loses to the focused field, this does not.
    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers == "w" {
            onCancel?()
            return true
        }
        if let action = Self.editAction(for: event),
           NSApp.sendAction(action, to: nil, from: self) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// Select All, Copy, Cut, Paste, Undo and Redo.
    ///
    /// An app with no menu bar of its own has no Edit menu, and the Edit
    /// menu is where these shortcuts live: without it a focused field took
    /// typing but ignored Command-A and Command-V. Sent down the responder
    /// chain, so whichever field has focus answers, and anything that does
    /// not handle the action lets the key through.
    static func editAction(for event: NSEvent) -> Selector? {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = event.charactersIgnoringModifiers?.lowercased()
        switch (flags, key) {
        case ([.command], "a"): return #selector(NSText.selectAll(_:))
        case ([.command], "c"): return #selector(NSText.copy(_:))
        case ([.command], "x"): return #selector(NSText.cut(_:))
        case ([.command], "v"): return #selector(NSText.paste(_:))
        case ([.command], "z"): return Selector(("undo:"))
        case ([.command, .shift], "z"): return Selector(("redo:"))
        default: return nil
        }
    }
}

/// Hosting view that takes the first click.
///
/// A click into a window that is not key is consumed as the click that
/// focuses it, so the first press on a panel that never became key was always
/// swallowed - which is why an icon could not be dragged out of a group.
public final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
