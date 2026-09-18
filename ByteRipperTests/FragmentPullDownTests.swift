import XCTest
@testable import ByteRipper

/// `Design/FRAGMENT_PANELS_PLAN.md`: a fragment panel pulled down by its
/// header. Let go, it either springs back or carries on into its pill — and
/// which of the two is a rule that can be read without a mouse.
@MainActor
final class FragmentPullDownTests: XCTestCase {
    private let height: CGFloat = 500

    // MARK: - Letting go

    /// Nudged down and let go, the panel carries on down — whatever distance
    /// the pull had covered. The action continues the movement.
    func testANudgeDownCollapsesWhateverTheDistance() {
        XCTAssertEqual(PullDown.outcome(travelled: 0, height: height, direction: .down), .collapse)
        XCTAssertEqual(PullDown.outcome(travelled: 12, height: height, direction: .down), .collapse)
    }

    /// Nudged up, it goes back up — from the very bottom, and after any pause.
    /// This is the one the hand found: a panel dragged to the floor and pushed
    /// gently back used to freeze and then collapse.
    func testANudgeUpSpringsBackFromAnywhere() {
        XCTAssertEqual(PullDown.outcome(travelled: height * 0.95, height: height, direction: .up),
                       .springBack)
        XCTAssertEqual(PullDown.outcome(travelled: height * 0.5, height: height, direction: .up),
                       .springBack)
    }

    /// A movement is a movement of at least the threshold; a tremble is not one
    /// and leaves the direction where it was.
    func testATrembleIsNotAMovement() {
        XCTAssertNil(PullDown.Direction.of(offset: PullDown.movementThreshold - 0.5))
        XCTAssertNil(PullDown.Direction.of(offset: -PullDown.movementThreshold + 0.5))
        XCTAssertEqual(PullDown.Direction.of(offset: -PullDown.movementThreshold), .down)
        XCTAssertEqual(PullDown.Direction.of(offset: PullDown.movementThreshold), .up)
    }

    /// Only a pull that never went anywhere is decided by how far it went.
    func testAPullWithNoDirectionIsDecidedByDistance() {
        let line = height * PullDown.dismissFraction
        XCTAssertEqual(PullDown.outcome(travelled: line, height: height, direction: .none),
                       .collapse)
        XCTAssertEqual(PullDown.outcome(travelled: line - 1, height: height, direction: .none),
                       .springBack)
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
        controller.fragments.endPull(id, direction: .none)
    }

    /// Pulled down to the floor and nudged back up, the panel is still up —
    /// however far it had been dragged first.
    func testANudgeBackUpLeavesThePanelUp() throws {
        let (controller, _, id) = try makePanel()
        defer { controller.fragments.close(id, animated: false) }

        controller.fragments.pullPanel(id, by: -400)
        controller.fragments.endPull(id, direction: .up)

        XCTAssertEqual(controller.fragments.expanded, id,
                       "nudged back up, it comes back up")
    }

    /// Flicked, it goes into its pill — and the pill is still there.
    func testAFlickPutsThePanelInItsPill() throws {
        let (controller, _, id) = try makePanel()
        defer { controller.fragments.close(id, animated: false) }

        controller.fragments.pullPanel(id, by: -30)
        controller.fragments.endPull(id, direction: .down)

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

    private func press(at point: NSPoint, in window: NSWindow,
                       type: NSEvent.EventType = .leftMouseDown) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                         timestamp: ProcessInfo.processInfo.systemUptime,
                                         windowNumber: window.windowNumber, context: nil,
                                         eventNumber: 0, clickCount: 1, pressure: 1))
    }
}
