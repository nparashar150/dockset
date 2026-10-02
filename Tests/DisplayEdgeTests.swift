import CoreGraphics
import XCTest

/// Every arrangement the shelf has to survive, in AppKit's global space
/// (origin at the primary display's bottom-left, y upward).
final class DisplayEdgeTests: XCTestCase {
    private let monitor = CGRect(x: 0, y: 0, width: 2560, height: 1440)

    func testLaptopBelowAMonitorSharesItsBottomOnly() {
        // The arrangement that broke: a MacBook under the monitor.
        let laptop = CGRect(x: 461, y: -1169, width: 1800, height: 1169)
        let all = [monitor, laptop]
        XCTAssertTrue(Geometry.sharesEdge(monitor, .bottom, with: all))
        XCTAssertFalse(Geometry.sharesEdge(monitor, .left, with: all))
        XCTAssertFalse(Geometry.sharesEdge(monitor, .right, with: all))
        // The laptop's own bottom is free, so a shelf there slides away.
        XCTAssertFalse(Geometry.sharesEdge(laptop, .bottom, with: all))
    }

    func testSideBySideSharesTheInnerEdges() {
        let right = CGRect(x: 2560, y: 100, width: 1800, height: 1169)
        let all = [monitor, right]
        XCTAssertTrue(Geometry.sharesEdge(monitor, .right, with: all))
        XCTAssertTrue(Geometry.sharesEdge(right, .left, with: all))
        XCTAssertFalse(Geometry.sharesEdge(monitor, .left, with: all))
        XCTAssertFalse(Geometry.sharesEdge(monitor, .bottom, with: all))
        XCTAssertFalse(Geometry.sharesEdge(right, .right, with: all))
    }

    func testPrimaryOnTheRightWithTheOtherToItsLeft() {
        // The primary display is wherever the menu bar is, so the other one
        // sits at negative x.
        let left = CGRect(x: -1800, y: 0, width: 1800, height: 1169)
        let all = [monitor, left]
        XCTAssertTrue(Geometry.sharesEdge(monitor, .left, with: all))
        XCTAssertTrue(Geometry.sharesEdge(left, .right, with: all))
        XCTAssertFalse(Geometry.sharesEdge(left, .left, with: all))
    }

    func testMonitorAboveTheLaptopLeavesTheMonitorBottomShared() {
        // Primary laptop at the origin, monitor above it.
        let laptop = CGRect(x: 0, y: 0, width: 1800, height: 1169)
        let above = CGRect(x: -380, y: 1169, width: 2560, height: 1440)
        let all = [laptop, above]
        XCTAssertTrue(Geometry.sharesEdge(above, .bottom, with: all))
        XCTAssertFalse(Geometry.sharesEdge(laptop, .bottom, with: all))
    }

    func testOnlyTouchingACornerIsNotSharing() {
        let diagonal = CGRect(x: 2560, y: -1169, width: 1800, height: 1169)
        let all = [monitor, diagonal]
        XCTAssertFalse(Geometry.sharesEdge(monitor, .bottom, with: all))
        XCTAssertFalse(Geometry.sharesEdge(monitor, .right, with: all))
    }

    func testOneDisplayHasNothingPastAnyEdge() {
        for edge in DockPosition.allCases {
            XCTAssertFalse(Geometry.sharesEdge(monitor, edge, with: [monitor]))
        }
    }
}
