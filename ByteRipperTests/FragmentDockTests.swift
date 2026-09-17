import XCTest
@testable import ByteRipper

/// `Design/FRAGMENT_PANELS_PLAN.md`: the dock's model — the order the pills sit
/// in, the one-panel-up invariant, and the transition every mutation hands back
/// for the animation to run. Pure: no window, no surface, no document.
final class FragmentDockTests: XCTestCase {
    /// The first panel opened rises with nothing to fold before it.
    func testOpeningIntoAnEmptyDockRaisesTheNewPanel() {
        var dock = FragmentDock()
        let (id, transition) = dock.open()
        XCTAssertEqual(dock.expanded, id)
        XCTAssertEqual(dock.panels, [id])
        XCTAssertNil(transition.folding, "there was nothing up to fold")
        XCTAssertEqual(transition.raising, id)
        XCTAssertNil(transition.removed)
    }

    /// Opening a second panel folds the first and raises the second in one
    /// transition, rather than two that have to be sequenced by the caller.
    func testOpeningASecondPanelFoldsTheFirstInTheSameTransition() {
        var dock = FragmentDock()
        let first = dock.open().id
        let (second, transition) = dock.open()
        XCTAssertEqual(transition, FragmentDock.Transition(folding: first, raising: second))
        XCTAssertEqual(dock.expanded, second)
    }

    /// The pills sit in the order the panels were opened, and stay there.
    func testPanelsKeepTheOrderTheyWereOpenedIn() {
        var dock = FragmentDock()
        let opened = (0..<4).map { _ in dock.open().id }
        XCTAssertEqual(dock.panels, opened)
        _ = dock.expand(opened[0])
        _ = dock.collapse()
        XCTAssertEqual(dock.panels, opened, "raising and folding never reorder the dock")
    }

    /// Every panel is its own, including two opened on what may well be the
    /// same part: the dock does not deduplicate.
    func testEveryOpenMakesADistinctPanel() {
        var dock = FragmentDock()
        let ids = (0..<5).map { _ in dock.open().id }
        XCTAssertEqual(Set(ids).count, 5)
        XCTAssertEqual(dock.count, 5)
    }

    /// Raising a folded panel folds the one that was up.
    func testExpandingAFoldedPanelSwapsTheTwo() {
        var dock = FragmentDock()
        let first = dock.open().id
        let second = dock.open().id
        let transition = dock.expand(first)
        XCTAssertEqual(transition, FragmentDock.Transition(folding: second, raising: first))
        XCTAssertEqual(dock.expanded, first)
    }

    /// Clicking the pill of the panel already on screen moves nothing — no
    /// fold, no raise, and above all not a fold of the panel being asked for.
    func testExpandingThePanelThatIsUpChangesNothing() {
        var dock = FragmentDock()
        let id = dock.open().id
        XCTAssertEqual(dock.expand(id), .none)
        XCTAssertEqual(dock.expanded, id)
    }

    /// A panel this dock does not hold — one already torn off into a tab, say —
    /// cannot be raised, and asking does not disturb what is up.
    func testExpandingAPanelTheDockDoesNotHoldChangesNothing() {
        var dock = FragmentDock()
        let mine = dock.open().id
        var other = FragmentDock()
        let stranger = other.open().id
        XCTAssertEqual(dock.expand(stranger), .none)
        XCTAssertEqual(dock.expanded, mine)
        XCTAssertEqual(dock.count, 1)
    }

    /// Folding leaves the stage clear: nothing is raised in its place.
    func testCollapsingFoldsTheOneThatIsUpAndRaisesNothing() {
        var dock = FragmentDock()
        let first = dock.open().id
        let second = dock.open().id
        let transition = dock.collapse()
        XCTAssertEqual(transition, FragmentDock.Transition(folding: second))
        XCTAssertNil(dock.expanded)
        XCTAssertEqual(dock.panels, [first, second], "folding keeps both pills")
    }

    /// Folding a clear stage is not an event.
    func testCollapsingAClearStageChangesNothing() {
        var dock = FragmentDock()
        XCTAssertEqual(dock.collapse(), .none)
        _ = dock.open()
        _ = dock.collapse()
        XCTAssertEqual(dock.collapse(), .none)
    }

    /// Removing the panel that is up folds it and clears the stage — the file
    /// it was covering comes back, rather than the next pill.
    func testRemovingTheExpandedPanelFoldsItAndRaisesNothing() {
        var dock = FragmentDock()
        let first = dock.open().id
        let second = dock.open().id
        let transition = dock.remove(second)
        XCTAssertEqual(transition, FragmentDock.Transition(folding: second, removed: second))
        XCTAssertNil(dock.expanded)
        XCTAssertEqual(dock.panels, [first])
    }

    /// Removing a folded panel takes its pill and leaves the stage alone.
    func testRemovingAFoldedPanelLeavesTheStageAlone() {
        var dock = FragmentDock()
        let first = dock.open().id
        let second = dock.open().id
        let transition = dock.remove(first)
        XCTAssertEqual(transition, FragmentDock.Transition(removed: first))
        XCTAssertEqual(dock.expanded, second, "the panel on screen did not move")
        XCTAssertEqual(dock.panels, [second])
    }

    /// The rest keep their order when one is taken out of the middle.
    func testRemovingKeepsTheOrderOfTheRest() {
        var dock = FragmentDock()
        let ids = (0..<4).map { _ in dock.open().id }
        _ = dock.remove(ids[1])
        XCTAssertEqual(dock.panels, [ids[0], ids[2], ids[3]])
    }

    /// Removing something the dock does not hold — a panel removed twice, a
    /// pill clicked as its tear-off lands — changes nothing.
    func testRemovingAPanelTheDockDoesNotHoldChangesNothing() {
        var dock = FragmentDock()
        let id = dock.open().id
        XCTAssertEqual(dock.remove(id), FragmentDock.Transition(folding: id, removed: id))
        XCTAssertEqual(dock.remove(id), .none)
        XCTAssertTrue(dock.isEmpty)
    }

    /// The invariant, over a run of every mutation the dock has: at most one
    /// panel is up, and the one that is up is always one the dock holds.
    func testAtMostOnePanelIsEverUp() {
        var dock = FragmentDock()
        var opened: [FragmentDock.PanelID] = []
        func check(_ step: String) {
            if let up = dock.expanded {
                XCTAssertTrue(dock.panels.contains(up), "after \(step): the panel up is not in the dock")
            }
        }
        for step in 0..<12 {
            switch step % 4 {
            case 0:
                opened.append(dock.open().id)
            case 1:
                if let first = opened.first { _ = dock.expand(first) }
            case 2:
                _ = dock.collapse()
            default:
                if let last = opened.popLast() { _ = dock.remove(last) }
            }
            check("step \(step)")
        }
        XCTAssertEqual(dock.count, opened.count)
    }
}
