import XCTest
@testable import ByteRipper

/// `Design/FRAGMENT_PANELS_PLAN.md`: a fragment panel pulled down by its
/// header. Let go, it either springs back or carries on into its pill — and
/// which of the two is a rule that can be read without a mouse.
@MainActor
final class FragmentPullDownTests: XCTestCase {
    private let height: CGFloat = 500

    // MARK: - Letting go near the top: a look

    private func look(_ direction: PullDown.Direction, flick: Bool = false) -> PullDown.Movement {
        PullDown.Movement(direction: direction,
                          distance: flick ? PullDown.flickDistance : 3,
                          speed: flick ? PullDown.flickSpeed : 120)
    }

    /// Pulled a little and let go, the panel goes back — whatever the hand was
    /// doing. A tug to see what is underneath should cost nothing.
    func testALookNearTheTopAlwaysSpringsBack() {
        let short = height * PullDown.commitFraction - 1
        for direction in [PullDown.Direction.down, .up, .none] {
            XCTAssertEqual(PullDown.outcome(travelled: short, height: height,
                                            movement: look(direction)),
                           .springBack, "\(direction) near the top")
        }
    }

    /// Except a flick: a decisive swipe still puts the panel away without
    /// having to carry it all the way down.
    func testAFlickDownFromTheTopStillCollapses() {
        let short = height * PullDown.commitFraction - 1
        XCTAssertEqual(PullDown.outcome(travelled: short, height: height,
                                        movement: look(.down, flick: true)),
                       .collapse)
        XCTAssertEqual(PullDown.outcome(travelled: short, height: height,
                                        movement: look(.up, flick: true)),
                       .springBack, "a flick the other way is not a dismissal")
    }

    /// A fast tremble is not a flick: the movement carrying the speed has to be
    /// a real shove.
    func testAFastTrembleIsNotAFlick() {
        let jitter = PullDown.Movement(direction: .down,
                                       distance: PullDown.flickDistance - 1,
                                       speed: PullDown.flickSpeed * 4)
        XCTAssertFalse(jitter.isFlick)
        XCTAssertEqual(PullDown.outcome(travelled: 10, height: height, movement: jitter),
                       .springBack)
    }

    // MARK: - Letting go past the commit line: an instruction

    /// Nudged up from down there, the panel comes back — from anywhere, at any
    /// speed, after any pause. This is the one the hand found.
    func testANudgeUpPastTheLineSpringsBack() {
        for travelled in [height * PullDown.commitFraction, height * 0.7, height * 0.98] {
            XCTAssertEqual(PullDown.outcome(travelled: travelled, height: height,
                                            movement: look(.up)),
                           .springBack, "at \(travelled)")
        }
    }

    /// Nudged down from down there, it carries on down.
    func testANudgeDownPastTheLineCollapses() {
        XCTAssertEqual(PullDown.outcome(travelled: height * 0.6, height: height,
                                        movement: look(.down)),
                       .collapse)
        XCTAssertEqual(PullDown.outcome(travelled: height * 0.6, height: height,
                                        movement: look(.none)),
                       .collapse, "carried there and simply let go, it stays down")
    }

    /// A movement is a movement of at least the threshold; a tremble is not one
    /// and leaves the direction where it was.
    func testATrembleIsNotAMovement() {
        XCTAssertNil(PullDown.Direction.of(offset: PullDown.movementThreshold - 0.5))
        XCTAssertNil(PullDown.Direction.of(offset: -PullDown.movementThreshold + 0.5))
        XCTAssertEqual(PullDown.Direction.of(offset: -PullDown.movementThreshold), .down)
        XCTAssertEqual(PullDown.Direction.of(offset: PullDown.movementThreshold), .up)
    }

    // MARK: - How fast the hand was going

    private func samples(_ points: [(y: CGFloat, t: TimeInterval)]) -> [PullDown.Sample] {
        points.map { PullDown.Sample(y: $0.y, time: $0.t) }
    }

    /// A fling that slows in its last frames is still a fling. Recorded in the
    /// app: 270 points in 150 ms, the last movement 4 points at 170 a second —
    /// which, measured over the last movement alone, was read as a drag and
    /// the panel sprang back.
    func testAFlingThatSlowsAtTheEndIsStillAFlick() {
        let fling = samples([(869.3, 0.0000), (837.1, 0.0112), (792.7, 0.0338), (740.6, 0.0449),
                             (687.7, 0.0675), (637.1, 0.0788), (605.6, 0.1013), (602.0, 0.1125),
                             (598.3, 0.1350), (597.3, 0.1462), (597.3, 0.1574)])
        let recent = PullDown.recentTravel(fling, direction: .down)
        let movement = PullDown.Movement(direction: .down, distance: recent.distance,
                                         speed: recent.speed)
        XCTAssertTrue(movement.isFlick, "\(recent)")
        XCTAssertEqual(PullDown.outcome(travelled: 287, height: 867, movement: movement),
                       .collapse)
    }

    /// A fling followed by a pause is not one: the panel has stopped, so there
    /// is nothing to carry on.
    func testAFlingThenAPauseIsNotAFlick() {
        let window = PullDown.flickWindow
        let paused = samples([(800, 0), (600, 0.08), (600, 0.08 + window + 0.05)])
        XCTAssertEqual(PullDown.recentTravel(paused, direction: .down).distance, 0)
    }

    /// Only travel in the direction asked about counts: down and back up
    /// inside the window has not flung the panel down.
    func testTravelTheOtherWayDoesNotCount() {
        let back = samples([(600, 0), (540, 0.03), (620, 0.06)])
        XCTAssertEqual(PullDown.recentTravel(back, direction: .down).distance, 0)
        XCTAssertEqual(PullDown.recentTravel(back, direction: .up).distance, 20, accuracy: 0.001)
        XCTAssertEqual(PullDown.recentTravel(back, direction: .none).distance, 0)
    }

    /// The fold that carries a throw on starts at speed — never slower than its
    /// own average, which is what an ease-in start was, and what showed as a
    /// pause between the hand and the animation.
    func testAThrownFoldStartsAtSpeed() {
        var start: [Float] = [0, 0]
        for speed: CGFloat in [0, 1200, 100_000] {
            FragmentPanels.throwTiming(speed: speed, travel: 800, duration: 0.2)
                .getControlPoint(at: 1, values: &start)
            XCTAssertGreaterThanOrEqual(start[1] / start[0], 1, "at \(speed) pt/s")
            XCTAssertLessThan(start[1], 1, "and does not overshoot its end at \(speed) pt/s")
        }
    }

    // MARK: - Where it sits while pulled

    /// Downward it follows the hand exactly.
    func testItFollowsTheHandDownward() {
        XCTAssertEqual(PullDown.position(restingY: 0, offset: -120), -120)
        XCTAssertEqual(PullDown.position(restingY: 40, offset: -10), 30)
    }

    /// Upward it gives a little and stops: it is already at the top, and there
    /// is nothing above to reveal.
    func testItResistsUpward() {
        let small = PullDown.position(restingY: 0, offset: 40)
        XCTAssertEqual(small, 40 * PullDown.upwardResistance, accuracy: 0.001)
        XCTAssertLessThan(small, 40, "a pull up is answered, not obeyed")
        XCTAssertEqual(PullDown.position(restingY: 0, offset: 10_000), PullDown.upwardLimit,
                       "and it never rises past its limit")
    }

    // MARK: - The panel under the hand

    private func makePanel() throws -> (MainViewController, NSWindow, FragmentDock.PanelID) {
        let controller = MainViewController()
        let window = makeTestWindow(width: 900, height: 600)
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 900, height: 600))
        window.layoutIfNeeded()
        let id = try XCTUnwrap(controller.openFragment([UInt8](repeating: 0, count: 0x100),
                                                       named: "part", animated: false))
        window.layoutIfNeeded()
        return (controller, window, id)
    }

    /// The panel follows the pull — and a layout pass in the middle of it does
    /// not take it back. It did: every mouse move set the frame and the layout
    /// that followed put it at rest again, so the panel shook instead of
    /// moving, and only a flick — which is decided by speed, not distance —
    /// ever worked.
    func testALayoutPassDoesNotTakeThePulledPanelBack() throws {
        let (controller, window, id) = try makePanel()
        defer { controller.fragments.close(id, animated: false) }
        let panel = try XCTUnwrap(controller.fragments.panelView(id))
        let resting = panel.frame.origin.y

        controller.fragments.pullPanel(id, by: -120)
        XCTAssertEqual(panel.frame.origin.y, resting - 120, "it follows the hand")

        window.layoutIfNeeded()
        try XCTUnwrap(panel.superview).layoutSubtreeIfNeeded()

        XCTAssertEqual(panel.frame.origin.y, resting - 120,
                       "and stays where the hand has it")
        controller.fragments.endPull(id, movement: look(.none))
    }

    /// Pulled down to the floor and nudged back up, the panel is still up —
    /// however far it had been dragged first.
    func testANudgeBackUpLeavesThePanelUp() throws {
        let (controller, _, id) = try makePanel()
        defer { controller.fragments.close(id, animated: false) }

        controller.fragments.pullPanel(id, by: -400)
        controller.fragments.endPull(id, movement: look(.up))

        XCTAssertEqual(controller.fragments.expanded, id,
                       "nudged back up, it comes back up")
    }

    /// Flicked, it goes into its pill — and the pill is still there.
    func testAFlickPutsThePanelInItsPill() throws {
        let (controller, _, id) = try makePanel()
        defer { controller.fragments.close(id, animated: false) }

        controller.fragments.pullPanel(id, by: -30)
        controller.fragments.endPull(id, movement: look(.down, flick: true))

        XCTAssertNil(controller.fragments.expanded, "it went down")
        XCTAssertEqual(controller.fragments.count, 1, "folded, not closed")
    }

    // MARK: - The handle

    /// The header tells the two drags apart by the direction the press has
    /// taken by the time it counts as a drag: down moves the panel, sideways
    /// carries the pane off to a tab.
    func testTheHeaderTellsAPullFromATearOff() throws {
        let header = PaneHeaderView(frame: NSRect(x: 0, y: 0, width: 300, height: 28))
        let window = makeTestWindow(width: 400, height: 200)
        window.contentView?.addSubview(header)
        var pulled = 0
        var carried = 0
        header.onDownwardDragThresholdPassed = { _ in pulled += 1 }
        header.onDragThresholdPassed = { _ in carried += 1 }

        header.mouseDown(with: try press(at: NSPoint(x: 100, y: 100), in: window))
        header.mouseDragged(with: try press(at: NSPoint(x: 102, y: 60), in: window, type: .leftMouseDragged))
        XCTAssertEqual(pulled, 1, "down, and more down than sideways")
        XCTAssertEqual(carried, 0)

        header.mouseDown(with: try press(at: NSPoint(x: 100, y: 100), in: window))
        header.mouseDragged(with: try press(at: NSPoint(x: 160, y: 96), in: window, type: .leftMouseDragged))
        XCTAssertEqual(carried, 1, "sideways is still the pane leaving")
        XCTAssertEqual(pulled, 1)

        header.mouseDown(with: try press(at: NSPoint(x: 100, y: 100), in: window))
        header.mouseDragged(with: try press(at: NSPoint(x: 104, y: 140), in: window, type: .leftMouseDragged))
        XCTAssertEqual(carried, 2, "and so is upward: there is no pull up")
    }

    /// The tool panel's header is a handle too, so a panel opened with a tool
    /// can be pulled down by either strip.
    func testTheToolPanelsHeaderIsAlsoAHandle() throws {
        let handle = PullDownHandleView(frame: NSRect(x: 0, y: 0, width: 300, height: 28))
        let window = makeTestWindow(width: 400, height: 200)
        window.contentView?.addSubview(handle)
        var pulled = 0
        handle.onPulledDown = { _ in pulled += 1 }

        handle.mouseDown(with: try press(at: NSPoint(x: 100, y: 100), in: window))
        handle.mouseDragged(with: try press(at: NSPoint(x: 101, y: 60), in: window,
                                            type: .leftMouseDragged))
        XCTAssertEqual(pulled, 1, "down is a pull")

        handle.mouseDown(with: try press(at: NSPoint(x: 100, y: 100), in: window))
        handle.mouseDragged(with: try press(at: NSPoint(x: 160, y: 98), in: window,
                                            type: .leftMouseDragged))
        XCTAssertEqual(pulled, 1, "sideways over this header means nothing")

        handle.mouseDown(with: try press(at: NSPoint(x: 100, y: 100), in: window))
        handle.mouseDragged(with: try press(at: NSPoint(x: 100, y: 140), in: window,
                                            type: .leftMouseDragged))
        XCTAssertEqual(pulled, 1, "and neither does up")
    }

    /// A panel with a tool open wires that header to the same gesture; the
    /// tab's own tool panel has nothing to pull and is left alone.
    func testOnlyAPanelsToolHeaderPulls() throws {
        let (controller, _, id) = try makePanel()
        defer { controller.fragments.close(id, animated: false) }
        let surface = try XCTUnwrap(controller.fragments.surface(id))

        XCTAssertNotNil(surface.tools.panel.onHeaderPulledDown)
        XCTAssertNil(controller.tools.panel.onHeaderPulledDown,
                     "the tab's own tool panel is not a handle")
    }

    private func press(at point: NSPoint, in window: NSWindow,
                       type: NSEvent.EventType = .leftMouseDown) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                         timestamp: ProcessInfo.processInfo.systemUptime,
                                         windowNumber: window.windowNumber, context: nil,
                                         eventNumber: 0, clickCount: 1, pressure: 1))
    }
}
