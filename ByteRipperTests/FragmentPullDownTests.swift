import XCTest
@testable import ByteRipper

/// `Design/FRAGMENT_PANELS_PLAN.md`: a fragment panel pulled down by its
/// header. Let go, it either springs back or carries on into its pill — and
/// which of the two is a rule that can be read without a mouse.
@MainActor
final class FragmentPullDownTests: XCTestCase {
    private let height: CGFloat = 500

    // MARK: - Letting go

    /// A flick downward puts the panel away however short the drag was: what
    /// decides is how it was let go.
    func testAFlickDownCollapsesWhateverTheDistance() {
        XCTAssertEqual(PullDown.outcome(travelled: 12, height: height,
                                        velocity: PullDown.dismissVelocity),
                       .collapse)
        XCTAssertEqual(PullDown.outcome(travelled: 0, height: height,
                                        velocity: PullDown.dismissVelocity * 3),
                       .collapse)
    }

    /// A look behind — pulled down and let go while barely moving — springs
    /// back.
    func testASlowLookBehindSpringsBack() {
        XCTAssertEqual(PullDown.outcome(travelled: height * 0.2, height: height, velocity: 40),
                       .springBack)
        XCTAssertEqual(PullDown.outcome(travelled: 0, height: height, velocity: 0), .springBack)
    }

    /// A slow pull that went far enough counts as putting it away, and the line
    /// is the fraction the rule names.
    func testASlowPullPastTheFractionCollapses() {
        let line = height * PullDown.dismissFraction
        XCTAssertEqual(PullDown.outcome(travelled: line, height: height, velocity: 0), .collapse)
        XCTAssertEqual(PullDown.outcome(travelled: line - 1, height: height, velocity: 0),
                       .springBack)
    }

    /// A pull taken back — let go while already travelling up — springs back
    /// even from far down. The last direction is the instruction.
    func testAPullTakenBackSpringsBackFromAnywhere() {
        XCTAssertEqual(PullDown.outcome(travelled: height * 0.9, height: height,
                                        velocity: -PullDown.dismissVelocity),
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
