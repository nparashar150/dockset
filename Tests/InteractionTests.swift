import AppKit
import SwiftUI
import XCTest

/// Tests that deliver real `NSEvent`s to a window.
///
/// The shelf's worst defects were all "a click or a keystroke never arrived",
/// and none of them were visible in the layout maths: an empty content shape
/// removed every widget's controls from hit testing, a borderless panel could
/// not take a keystroke, and a non-key window swallowed the first press. None
/// of it could be caught by asserting on values.
///
/// Synthetic input through the OS is blocked for this process, but an
/// `NSEvent` sent straight to a window reaches SwiftUI's gesture recognisers
/// and AppKit's responders - which is what makes these testable at all.
@MainActor
final class InteractionTests: XCTestCase {

    // MARK: Harness

    /// Hosts `view` in a panel, runs `body`, and tears the window down.
    private func inPanel<V: View>(_ view: V,
                                  size: CGSize = CGSize(width: 200, height: 120),
                                  keyable: Bool = false,
                                  firstMouse: Bool = false,
                                  _ body: (NSPanel) -> Void) {
        let frame = NSRect(origin: .zero, size: size)
        let panel: NSPanel = keyable
            ? KeyablePanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                           backing: .buffered, defer: false)
            : NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                      backing: .buffered, defer: false)
        let hosting: NSView = firstMouse
            ? FirstMouseHostingView(rootView: view)
            : NSHostingView(rootView: view)
        hosting.frame = frame
        panel.contentView = hosting
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.orderFrontRegardless()
        hosting.layoutSubtreeIfNeeded()
        settle(0.3)
        body(panel)
        panel.orderOut(nil)
    }

    private func settle(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func send(_ type: NSEvent.EventType, at point: NSPoint, to panel: NSPanel) {
        guard let event = NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: panel.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1) else { return }
        panel.sendEvent(event)
        settle(0.1)
    }

    private func click(at point: NSPoint, in panel: NSPanel) {
        send(.leftMouseDown, at: point, to: panel)
        send(.leftMouseUp, at: point, to: panel)
        settle(0.2)
    }

    private func drag(from start: NSPoint, to end: NSPoint, in panel: NSPanel) {
        send(.leftMouseDown, at: start, to: panel)
        for step in 1...10 {
            let t = CGFloat(step) / 10
            send(.leftMouseDragged,
                 at: NSPoint(x: start.x + (end.x - start.x) * t,
                             y: start.y + (end.y - start.y) * t),
                 to: panel)
        }
        send(.leftMouseUp, at: end, to: panel)
        settle(0.2)
    }

    // MARK: Hit testing

    /// A counter a test view can bump from a gesture.
    private final class Tally {
        var inner = 0
        var outer = 0
    }

    private struct NestedTargets: View {
        let tally: Tally
        var filled: Bool
        var body: some View {
            ZStack {
                Color.gray
                Color.blue.frame(width: 40, height: 40)
                    .contentShape(.rect)
                    .onTapGesture { tally.inner += 1 }
            }
            .frame(width: 200, height: 120)
            .modifier(TileHitShape(filled: filled))
            .onTapGesture { tally.outer += 1 }
        }
    }

    /// A widget's own controls must receive their own clicks.
    ///
    /// The shelf gave widget tiles an *empty* content shape, on the theory
    /// that it cleared only the tile's hit region and left descendants
    /// hittable. It does not: an empty content shape takes the whole subtree
    /// out of hit testing, so every control inside every widget was dead.
    func testAnInteriorControlReceivesItsOwnClick() {
        let tally = Tally()
        inPanel(NestedTargets(tally: tally, filled: false)) { panel in
            click(at: NSPoint(x: 100, y: 60), in: panel)
        }
        XCTAssertEqual(tally.inner, 1)
    }

    /// And a tile that wants its whole area clickable still gets it.
    func testAFilledHitShapeStillReceivesClicks() {
        let tally = Tally()
        inPanel(NestedTargets(tally: tally, filled: true)) { panel in
            click(at: NSPoint(x: 100, y: 60), in: panel)
        }
        XCTAssertEqual(tally.inner, 1)
    }

    /// The interior wins over the tile's own action, which is what lets a
    /// widget carry both a control and a whole-card tap.
    func testTheInteriorWinsOverTheCardsOwnAction() {
        let tally = Tally()
        inPanel(NestedTargets(tally: tally, filled: false)) { panel in
            click(at: NSPoint(x: 100, y: 60), in: panel)
        }
        XCTAssertEqual(tally.inner, 1)
        XCTAssertEqual(tally.outer, 0, "the card must not also fire")
    }

    /// Away from the control, the card's own action is what runs - a widget
    /// with somewhere to go opens it, rather than swallowing the click.
    func testTheCardActsWhenClickedAwayFromItsControls() {
        let tally = Tally()
        inPanel(NestedTargets(tally: tally, filled: false)) { panel in
            click(at: NSPoint(x: 20, y: 60), in: panel)
        }
        XCTAssertEqual(tally.inner, 0)
        XCTAssertEqual(tally.outer, 1)
    }

    // MARK: Whole-card taps

    /// A card whose descendant claims every point of it.
    ///
    /// `wholeCard` is the defect's exact shape: a `Group` carrying
    /// `.frame(maxWidth: .infinity, maxHeight: .infinity)` with a content
    /// shape and a tap on top of it, which is how eleven widget tiles used to
    /// attach their own action.
    private struct WholeCardTap: View {
        let tally: Tally
        var wholeCard: Bool
        var body: some View {
            ZStack {
                Color.gray
                if wholeCard {
                    Color.blue.opacity(0.2)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(.rect)
                        .onTapGesture { tally.inner += 1 }
                }
            }
            .frame(width: 200, height: 120)
            .modifier(TileHitShape(filled: false))
            .onTapGesture { tally.outer += 1 }
        }
    }

    /// The five points a hand actually aims at: the middle, and each corner.
    private static let cardPoints = [NSPoint(x: 100, y: 60),
                                     NSPoint(x: 5, y: 5), NSPoint(x: 195, y: 5),
                                     NSPoint(x: 5, y: 115), NSPoint(x: 195, y: 115)]

    /// A descendant tap that covers the whole card leaves the card's own
    /// action dead *everywhere*, not merely over a control.
    ///
    /// This is the one that hid: the earlier tests only ever clicked the
    /// middle of a small interior target, so "the interior wins" read as a
    /// feature. Stretch that interior to the card's bounds and there is no
    /// remaining pixel for the shelf's own tap - every click on a widget was
    /// inert, and the only visible symptom was a panel that never opened.
    func testAWholeCardTapLeavesTheCardsActionDeadEverywhere() {
        let tally = Tally()
        let points = Self.cardPoints
        inPanel(WholeCardTap(tally: tally, wholeCard: true)) { panel in
            for point in points { click(at: point, in: panel) }
        }
        XCTAssertEqual(tally.inner, points.count)
        XCTAssertEqual(tally.outer, 0, """
            A tile with a detail panel must not put a tap on its whole card: \
            a descendant tap beats the shelf's, so the panel can never open \
            from anywhere on the tile. Whole-card actions belong on a small \
            control that occupies only the element they are about.
            """)
    }

    /// With the whole-card tap gone the same five points all reach the card,
    /// which is what makes a widget's panel openable at all.
    func testACardWithoutAWholeCardTapIsClickableEverywhere() {
        let tally = Tally()
        let points = Self.cardPoints
        inPanel(WholeCardTap(tally: tally, wholeCard: false)) { panel in
            for point in points { click(at: point, in: panel) }
        }
        XCTAssertEqual(tally.outer, points.count, "every point on the card must open the panel")
        XCTAssertEqual(tally.inner, 0)
    }

    /// A control whose gate sits inside its action versus on its gesture.
    private struct GatedControl: View {
        let tally: Tally
        var gateOnGesture: Bool
        var wanted: Bool

        var body: some View {
            ZStack {
                Color.gray
                control
            }
            .frame(width: 200, height: 120)
            .modifier(TileHitShape(filled: true))
            .onTapGesture { tally.outer += 1 }
        }

        @ViewBuilder private var control: some View {
            if gateOnGesture {
                if wanted {
                    glyph.onTapGesture { tally.inner += 1 }
                } else {
                    glyph
                }
            } else {
                glyph.onTapGesture { if wanted { tally.inner += 1 } }
            }
        }

        private var glyph: some View {
            Color.blue.frame(width: 40, height: 40).contentShape(.rect)
        }
    }

    /// A tap whose action returns early still eats the click.
    ///
    /// This was the stock tile with one symbol in its rotation: the action
    /// guarded `count > 1` and did nothing, so the click neither advanced
    /// anything nor reached the card. Nothing at all happened, which reads as
    /// a dead app rather than a gate doing its job.
    func testAnEarlyReturningControlStillSwallowsTheClick() {
        let tally = Tally()
        inPanel(GatedControl(tally: tally, gateOnGesture: false, wanted: false)) { panel in
            click(at: NSPoint(x: 100, y: 60), in: panel)
        }
        XCTAssertEqual(tally.inner, 0)
        XCTAssertEqual(tally.outer, 0, """
            A guard inside a tap's action cannot decline the click. Gate the \
            gesture - attach it only when it is wanted, the way TapToOpen \
            does - so an unwanted control leaves the card's tap alone.
            """)
    }

    /// Gating the gesture instead of the action hands the click back.
    func testAGateOnTheGestureLeavesTheClickToTheCard() {
        let tally = Tally()
        inPanel(GatedControl(tally: tally, gateOnGesture: true, wanted: false)) { panel in
            click(at: NSPoint(x: 100, y: 60), in: panel)
        }
        XCTAssertEqual(tally.inner, 0)
        XCTAssertEqual(tally.outer, 1, "with no gesture attached the card must still act")
    }

    /// And when it is wanted it behaves like any other interior control.
    func testAWantedGatedControlTakesTheClick() {
        let tally = Tally()
        inPanel(GatedControl(tally: tally, gateOnGesture: true, wanted: true)) { panel in
            click(at: NSPoint(x: 100, y: 60), in: panel)
        }
        XCTAssertEqual(tally.inner, 1)
        XCTAssertEqual(tally.outer, 0)
    }

    // MARK: Key status

    /// Keystrokes only reach the key window, so a panel that can never be key
    /// shows a caret that accepts nothing. That is what stopped a group from
    /// being renamed in place.
    func testABorderlessPanelCannotBecomeKey() {
        inPanel(Color.clear, keyable: false) { panel in
            panel.makeKey()
            XCTAssertFalse(panel.isKeyWindow)
        }
    }

    func testAKeyablePanelBecomesKey() {
        inPanel(Color.clear, keyable: true) { panel in
            panel.makeKey()
            XCTAssertTrue(panel.isKeyWindow)
        }
    }

    /// The app has no Edit menu, so the panel itself has to turn Command-A
    /// and friends into the actions a focused field answers.
    func testEditShortcutsReachTheFocusedField() {
        let panel = KeyablePanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 40),
                                 styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered, defer: false)
        let field = NSTextField(string: "hello there")
        field.frame = NSRect(x: 0, y: 0, width: 200, height: 24)
        panel.contentView?.addSubview(field)
        panel.orderFrontRegardless()
        panel.makeKey()
        XCTAssertTrue(panel.makeFirstResponder(field))
        let editor = try! XCTUnwrap(panel.fieldEditor(false, for: field) as? NSTextView)
        editor.setSelectedRange(NSRange(location: 0, length: 0))

        func key(_ character: String, _ flags: NSEvent.ModifierFlags = .command) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                             timestamp: 0, windowNumber: panel.windowNumber, context: nil,
                             characters: character, charactersIgnoringModifiers: character,
                             isARepeat: false, keyCode: 0)!
        }
        XCTAssertTrue(panel.performKeyEquivalent(with: key("a")))
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: 11))
        // Not an edit shortcut: left for the rest of the app.
        XCTAssertNil(KeyablePanel.editAction(for: key("a", [.command, .option])))
        XCTAssertEqual(KeyablePanel.editAction(for: key("z", [.command, .shift])), Selector(("redo:")))
        panel.orderOut(nil)
    }

    /// The first click into a window that is not key is consumed as the click
    /// that focuses it. Without this the opening press of every drag out of a
    /// group was swallowed.
    func testTheHostingViewTakesTheFirstMouse() {
        inPanel(Color.clear, firstMouse: true) { panel in
            XCTAssertEqual(panel.contentView?.acceptsFirstMouse(for: nil), true)
        }
    }

    func testAPlainHostingViewRefusesTheFirstMouse() {
        inPanel(Color.clear, firstMouse: false) { panel in
            XCTAssertEqual(panel.contentView?.acceptsFirstMouse(for: nil), false)
        }
    }

    // MARK: Dragging out of a group

    private struct DragOutTarget: View {
        let tally: Tally
        var sheet: CGSize
        @State private var offset: CGSize = .zero
        var body: some View {
            ZStack {
                Color.gray
                Color.blue.frame(width: 40, height: 40)
                    .offset(offset)
                    .contentShape(.rect)
                    .gesture(
                        DragGesture(minimumDistance: 8, coordinateSpace: .named("sheet"))
                            .onChanged { offset = $0.translation }
                            .onEnded { value in
                                if GroupDrag.leavesSheet(value.location, sheet: sheet) {
                                    tally.outer += 1
                                } else {
                                    tally.inner += 1
                                }
                                offset = .zero
                            })
            }
            .frame(width: sheet.width, height: sheet.height)
            .coordinateSpace(name: "sheet")
        }
    }

    /// Dragging an icon past the sheet's edge takes it out of the group.
    func testDraggingPastTheSheetEdgeLeavesTheGroupForReal() {
        let tally = Tally()
        let sheet = CGSize(width: 200, height: 120)
        inPanel(DragOutTarget(tally: tally, sheet: sheet), size: sheet, firstMouse: true) { panel in
            drag(from: NSPoint(x: 100, y: 60), to: NSPoint(x: 100, y: 300), in: panel)
        }
        XCTAssertEqual(tally.outer, 1, "released outside, so it should leave")
        XCTAssertEqual(tally.inner, 0)
    }

    /// Nudging it within the sheet changes nothing, so it springs home.
    func testDraggingWithinTheSheetKeepsTheIconForReal() {
        let tally = Tally()
        let sheet = CGSize(width: 200, height: 120)
        inPanel(DragOutTarget(tally: tally, sheet: sheet), size: sheet, firstMouse: true) { panel in
            drag(from: NSPoint(x: 100, y: 60), to: NSPoint(x: 130, y: 70), in: panel)
        }
        XCTAssertEqual(tally.inner, 1, "released inside, so it should return")
        XCTAssertEqual(tally.outer, 0)
    }

    // MARK: Notifications from other processes

    /// A distributed notification does not reach the ordinary centre.
    ///
    /// The shelf followed Apple's Dock by observing `com.apple.dock.prefchanged`
    /// on `NotificationCenter.default`. The Dock is another process, so it
    /// posts that distributed, and the observer could never fire. Nothing
    /// re-placed or re-hid the shelf when the Dock's settings changed, and
    /// "Match the macOS Dock" only matched it at launch.
    ///
    /// The shape of the bug is what makes it worth a test: the code reads
    /// correctly, registers without error, and is simply never called.
    func testADistributedNotificationSkipsTheOrdinaryCentre() {
        let name = Notification.Name("docket.tests.distributed")
        let local = expectation(description: "local centre")
        local.isInverted = true
        let distributed = expectation(description: "distributed centre")

        let a = NotificationCenter.default.addObserver(
            forName: name, object: nil, queue: .main) { _ in local.fulfill() }
        let b = DistributedNotificationCenter.default().addObserver(
            forName: name, object: nil, queue: .main) { _ in distributed.fulfill() }
        defer {
            NotificationCenter.default.removeObserver(a)
            DistributedNotificationCenter.default().removeObserver(b)
        }

        DistributedNotificationCenter.default()
            .postNotificationName(name, object: nil, deliverImmediately: true)

        wait(for: [distributed, local], timeout: 2)
    }
}
