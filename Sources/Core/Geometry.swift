import Foundation

/// Layout maths for the Docket shelf.
///
/// These formulas are the load-bearing part of the whole product: every tile
/// size, gap, corner radius and drag gesture derives from them. They are
/// deliberately written as free functions so they stay trivially testable and
/// have no dependency on AppKit.
public enum Geometry {

    // MARK: Scale

    public static let scaleRange: ClosedRange<Double> = 0.25...1.5
    public static let defaultScale: Double = 0.35

    /// Widget content grows at double rate below 50%, half rate above.
    ///
    /// The two branches meet at `s == 0.5` (both give `1.0`), so the curve is
    /// continuous. Below 50% the shelf is small enough that linear scaling
    /// would make widget text unreadable, hence the steeper slope.
    public static func contentScale(_ s: Double) -> Double {
        s < 0.5 ? 2 * s : 0.75 + 0.5 * s
    }

    // MARK: Icon geometry (native points)

    public struct IconGeometry: Equatable, Sendable {
        public var width, height, icon, dot, dotOffset, dotBottom, factor: Double
    }

    /// - Parameter hasWidgets: shelves holding only app icons scale linearly;
    ///   once a widget is present everything follows `contentScale` so icons
    ///   and tiles stay in proportion.
    public static func iconGeometry(scale: Double, vertical: Bool, hasWidgets: Bool = true) -> IconGeometry {
        let f = hasWidgets ? contentScale(scale) : scale
        return IconGeometry(
            width: (vertical ? 62 : 50) * f,
            height: (vertical ? 50 : 62) * f,
            icon: 48 * f,
            dot: 4 * f,
            dotOffset: 28 * f,
            dotBottom: 24 * f,
            factor: f
        )
    }

    /// Cross-axis extent of a widget tile: 62pt tall on a bottom shelf,
    /// 76pt wide on a side shelf.
    public static func widgetCross(_ position: DockPosition) -> Double {
        position == .bottom ? 62 : 76
    }

    // MARK: Chrome

    public struct Chrome: Equatable, Sendable {
        public var padding, radius, itemGap, adjacentGap: Double
        public var gripLong, gripShort, gripCross: Double
    }

    public static func chrome(scale: Double) -> Chrome {
        let inverse = 1 / min(1, scale)
        return Chrome(
            padding: (8 + 2 * inverse) * scale,
            radius: 22 / clamp(scale, 0.5, 1) * scale,
            itemGap: 4 * scale * inverse,
            // Widgets sit flush against their neighbours; the negative gap
            // closes the hairline the tile's own inset would otherwise leave.
            adjacentGap: -scale * inverse,
            gripLong: 28 * scale.squareRoot(),
            gripShort: 4 * scale.squareRoot(),
            // Grips stop shrinking below 50% or they become untargetable.
            gripCross: max(52 * scale, 28)
        )
    }

    // MARK: Drag resize

    /// Inverse of the tile-extent function: given a drag delta in points,
    /// returns the scale that makes the shelf exactly that much bigger.
    ///
    /// The two branches mirror `contentScale`'s two branches - collapsing this
    /// into a single linear map is the obvious "simplification" and it makes
    /// the grip feel wrong below 50%, which is exactly where users drag.
    public static func resizedScale(_ scale: Double, delta: Double,
                                    position: DockPosition, hasWidgets: Bool = true) -> Double {
        guard hasWidgets else {
            return clamp(scale + delta / (position == .bottom ? 86 : 112), scaleRange)
        }
        let cross = widgetCross(position)
        let extent = cross * contentScale(scale) + 24 * scale + delta
        let s = extent < cross + 12
            ? extent / (2 * cross + 24)
            : (extent - 0.75 * cross) / (0.5 * cross + 24)
        return clamp(s, scaleRange)
    }

    /// Sign of the drag delta differs per edge: dragging *away* from the
    /// screen edge always grows the shelf.
    public static func resizeDelta(from start: CGPoint, to point: CGPoint, position: DockPosition) -> Double {
        switch position {
        case .bottom: return start.y - point.y
        case .right: return start.x - point.x
        case .left: return point.x - start.x
        }
    }

    // MARK: Magnification

    /// Raised-cosine falloff: 1.0 at the pointer, 0 at `radius`, with zero
    /// slope at both ends so there is no visible seam where it cuts off.
    public static func influence(distance: Double, radius: Double) -> Double {
        distance >= radius ? 0 : (1 + cos(.pi * distance / radius)) / 2
    }

    public static let magnificationRadius: Double = 110
    public static let magnificationPeak: Double = 0.35
    /// Widget tiles are large already; the app-icon peak looks cartoonish on them.
    public static let widgetMagnificationPeak: Double = 0.20

    /// Critically-ish damped spring, integrated explicitly.
    /// - Parameter seconds: caller must clamp to <= 0.032 so a dropped frame
    ///   cannot blow the integrator up.
    public static func springStep(value: Double, velocity: Double,
                                  target: Double, seconds: Double) -> (value: Double, velocity: Double) {
        let nextVelocity = velocity + (420 * (target - value) - 41 * velocity) * seconds
        return (value + nextVelocity * seconds, nextVelocity)
    }

    public static let maxStep: Double = 0.032

    // MARK: Reorder

    /// Index an item dragged to `position` should occupy, given the current
    /// item centres. Walks only in the direction of travel so an item cannot
    /// jump past a neighbour it has not actually crossed.
    public static func reorderIndex(centers: [Double], from: Int, position: Double, direction: Double) -> Int {
        var to = from
        if direction > 0 { while to < centers.count - 1 && position >= centers[to + 1] { to += 1 } }
        if direction < 0 { while to > 0 && position <= centers[to - 1] { to -= 1 } }
        return to
    }

    // MARK: Helpers

    public static func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double {
        min(max(v, lo), hi)
    }

    public static func clamp(_ v: Double, _ range: ClosedRange<Double>) -> Double {
        min(max(v, range.lowerBound), range.upperBound)
    }
}

// MARK: - Displays

public extension Geometry {
    /// Whether another display continues past `screen`'s `edge`.
    ///
    /// Pure, over frames in AppKit's global space, so every arrangement can
    /// be tested without the displays: a laptop below a monitor, a monitor
    /// to either side, the primary display anywhere. A point of slack covers
    /// arrangements that do not quite meet, and the two must overlap along
    /// the edge; a display that only touches a corner does not count.
    static func sharesEdge(_ screen: CGRect, _ edge: DockPosition, with others: [CGRect]) -> Bool {
        others.contains { o in
            guard o != screen else { return false }
            switch edge {
            case .bottom:
                return abs(o.maxY - screen.minY) < 2 && o.maxX > screen.minX && o.minX < screen.maxX
            case .left:
                return abs(o.maxX - screen.minX) < 2 && o.maxY > screen.minY && o.minY < screen.maxY
            case .right:
                return abs(o.minX - screen.maxX) < 2 && o.maxY > screen.minY && o.minY < screen.maxY
            }
        }
    }
}
