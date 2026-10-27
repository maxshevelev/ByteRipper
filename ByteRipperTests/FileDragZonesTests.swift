import XCTest
@testable import ByteRipper

/// While a file is over the window every zone it can go to is up and unlit,
/// and only the one under the pointer is lit (§4.3). AppKit tells only the
/// destination under the pointer, so it is the window that keeps the rest up.
@MainActor
final class FileDragZonesTests: XCTestCase {
    private func makeWindow(_ controller: MainViewController) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 900, height: 600))
        window.layoutIfNeeded()
        return window
    }

    private func close(_ controller: MainViewController, _ urls: URL...) {
        controller.windowModel.pane1.close()
        controller.windowModel.pane2.close()
        for url in urls { try? FileManager.default.removeItem(at: url) }
    }

    /// The middle of `view`, in window coordinates.
    private func middle(of view: NSView) -> NSPoint {
        view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
    }

    private func bands(_ view: PaneDropBandsView) -> [DropTargetView] {
        [view.bandForTesting(.insertAtStart), view.bandForTesting(.replace),
         view.bandForTesting(.appendAtEnd)]
    }

    private func shown(_ zones: [DropTargetView]) -> Bool { zones.allSatisfy { !$0.isHidden } }
    private func lit(_ zones: [DropTargetView]) -> [Bool] { zones.map(\.isHighlightedForTesting) }

    func testAFileOverOnePaneShowsTheOtherPanesZonesUnlit() throws {
        let url1 = try tempFile([UInt8](repeating: 1, count: 0x100))
        let url2 = try tempFile([UInt8](repeating: 2, count: 0x100))
        let controller = MainViewController()
        let window = makeWindow(controller)
        defer { close(controller, url1, url2) }
        try controller.windowModel.pane1.open(url: url1)
        try controller.windowModel.pane2.open(url: url2)
        controller.apply(mode: .comparison)
        window.layoutIfNeeded()
        let (left, right) = try XCTUnwrap(controller.comparisonBandsForTesting)

        let drag = FakeDraggingInfo(fileURLs: [url1], at: middle(of: left))
        _ = left.draggingEntered(drag)

        XCTAssertTrue(shown(bands(left)), "the pane under the pointer")
        XCTAssertEqual(lit(bands(left)), [false, true, false], "its middle band is lit")
        XCTAssertTrue(shown(bands(right)), "the other pane's zones are up too")
        XCTAssertEqual(lit(bands(right)), [false, false, false], "and unlit")

        // On to the other pane: an exit and an entry in the same step.
        left.draggingExited(drag)
        drag.draggingLocation = middle(of: right)
        _ = right.draggingEntered(drag)
        XCTAssertTrue(shown(bands(left)), "the pane left behind stays up")
        XCTAssertEqual(lit(bands(left)), [false, false, false], "unlit")
        XCTAssertEqual(lit(bands(right)), [false, true, false])

        right.performDragOperation(FakeDraggingInfo(fileURLs: [], at: middle(of: right)))
        XCTAssertFalse(bands(left).contains { !$0.isHidden }, "a drop takes every zone down")
        XCTAssertFalse(bands(right).contains { !$0.isHidden })
    }

    func testTheZonesGoOnceTheFileHasLeftTheWindow() throws {
        let url1 = try tempFile([UInt8](repeating: 1, count: 0x100))
        let url2 = try tempFile([UInt8](repeating: 2, count: 0x100))
        let controller = MainViewController()
        let window = makeWindow(controller)
        defer { close(controller, url1, url2) }
        try controller.windowModel.pane1.open(url: url1)
        try controller.windowModel.pane2.open(url: url2)
        controller.apply(mode: .comparison)
        window.layoutIfNeeded()
        let (left, right) = try XCTUnwrap(controller.comparisonBandsForTesting)

        let drag = FakeDraggingInfo(fileURLs: [url1], at: middle(of: left))
        _ = left.draggingEntered(drag)
        left.draggingExited(drag)
        XCTAssertTrue(shown(bands(right)), "not at once: the file may be on its way to another zone")

        XCTAssertTrue(pumpUntil(2) { bands(left).allSatisfy(\.isHidden) && bands(right).allSatisfy(\.isHidden) },
                      "nothing took the drag up again, so the file has left the window")
    }

    func testSingleFileModeShowsBothHalvesAndLightsTheOneUnderThePointer() throws {
        let url = try tempFile([UInt8](repeating: 1, count: 0x100))
        let controller = MainViewController()
        let window = makeWindow(controller)
        defer { close(controller, url) }
        try controller.windowModel.pane1.open(url: url)
        controller.apply(mode: .singleFile)
        window.layoutIfNeeded()
        let dropView = try XCTUnwrap(findView(SingleFileDropView.self, in: controller.view))
        let second = dropView.secondHalfForTesting.targetForTesting
        let thisFile = bands(dropView.thisFileBands)

        let drag = FakeDraggingInfo(fileURLs: [url], at: middle(of: dropView.thisFileBands))
        _ = dropView.draggingEntered(drag)
        XCTAssertTrue(shown(thisFile))
        XCTAssertEqual(lit(thisFile), [false, true, false])
        XCTAssertFalse(second.isHidden, "Open for Comparison is up while the pointer is over the bands")
        XCTAssertFalse(second.isHighlightedForTesting)

        drag.draggingLocation = middle(of: dropView.secondHalfForTesting)
        _ = dropView.draggingUpdated(drag)
        XCTAssertTrue(shown(thisFile), "the bands stay up over the other half")
        XCTAssertEqual(lit(thisFile), [false, false, false])
        XCTAssertTrue(second.isHighlightedForTesting)
        XCTAssertEqual(second.titleForTesting, "Open for Comparison")

        dropView.draggingEnded(drag)
        XCTAssertTrue(thisFile.allSatisfy(\.isHidden))
        XCTAssertTrue(second.isHidden)
    }

    /// A pane drag puts up the zones of every pane at once, from its start: each
    /// band that would take the pane, unlit, and none that would refuse it.
    func testAPaneDragShowsEveryPanesZonesAndNoneThatRefuse() throws {
        let url1 = try tempFile([UInt8](repeating: 1, count: 0x100))
        let url2 = try tempFile([UInt8](repeating: 2, count: 0x100))
        let controller = MainViewController()
        let window = makeWindow(controller)
        defer { close(controller, url1, url2) }
        try controller.windowModel.pane1.open(url: url1)
        try controller.windowModel.pane2.open(url: url2)
        controller.apply(mode: .comparison)
        window.layoutIfNeeded()
        let (left, right) = try XCTUnwrap(controller.comparisonBandsForTesting)
        let dragged = controller.windowModel.pane1.dragID

        controller.showPaneDropZones(dragged)

        let own = bands(left)
        XCTAssertFalse(own[0].isHidden, "its own slot joins at the start")
        XCTAssertTrue(own[1].isHidden, "the middle of its own slot refuses, and is not shown")
        XCTAssertFalse(own[2].isHidden, "and joins at the end")
        XCTAssertTrue(shown(bands(right)), "the other pane's zones are up before the pointer gets there")
        XCTAssertEqual(lit(own + bands(right)), Array(repeating: false, count: 6), "all unlit")

        // Over the refused band: still nothing there, and the rest stay.
        let drag = FakeDraggingInfo(paneID: dragged, copying: false, at: middle(of: left))
        XCTAssertEqual(left.draggingEntered(drag), [])
        XCTAssertTrue(own[1].isHidden)
        XCTAssertTrue(shown(bands(right)))
        left.draggingExited(drag)
        XCTAssertFalse(own[0].isHidden, "leaving the pane unlights its bands rather than taking them down")

        controller.showPaneDropZones(nil)
        XCTAssertTrue((own + bands(right)).allSatisfy(\.isHidden), "the drag over, every zone goes")
    }

    private func findView<T: NSView>(_ type: T.Type, in root: NSView) -> T? {
        if let match = root as? T { return match }
        for sub in root.subviews { if let found = findView(type, in: sub) { return found } }
        return nil
    }
}
