import ByteRipperCore
import XCTest
@testable import ByteRipper

/// Edit ▸ Copy to Other Pane: the active pane's selected range, written over
/// the same addresses in the other pane without the clipboard — one undo step
/// in the receiving document, and a sentence for every case that cannot work.
@MainActor
final class CopyToOtherPaneTests: XCTestCase {
    private var urls: [URL] = []

    override func tearDown() {
        for url in urls {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
            try? FileManager.default.removeItem(at: url)
        }
        urls = []
        super.tearDown()
    }

    /// Two files in a comparison, File A active.
    private func makeComparison(_ a: [UInt8], _ b: [UInt8],
                                readOnlyB: Bool = false) throws -> MainViewController {
        let urlA = try tempFile(a)
        let urlB = try tempFile(b)
        urls += [urlA, urlB]
        if readOnlyB {
            try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: urlB.path)
        }
        let controller = MainViewController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 600),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        // ARC owns it: a window released on close as well is released twice.
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        try controller.windowModel.pane1.open(url: urlA)
        try controller.windowModel.pane2.open(url: urlB)
        controller.apply(mode: .comparison)
        window.layoutIfNeeded()
        // Closed before the files go: a watched file deleted under an open pane
        // raises the external-change prompt, which would block the test.
        addTeardownBlock { @MainActor in
            controller.windowModel.pane1.close()
            controller.windowModel.pane2.close()
            window.orderOut(nil)
        }
        return controller
    }

    private func bytes(_ pane: PaneViewModel) throws -> [UInt8] {
        try XCTUnwrap(pane.document?.read(at: 0, length: Int(pane.fileSize)))
    }

    private var menuItem: NSMenuItem {
        NSMenuItem(title: "", action: #selector(MainViewController.copyToOtherPane), keyEquivalent: "")
    }

    func testTheSelectionLandsAtTheSameAddressesAsOneUndoStep() throws {
        let controller = try makeComparison([UInt8](repeating: 0xAA, count: 64),
                                            [UInt8](repeating: 0x00, count: 64))
        let a = controller.windowModel.pane1
        let b = controller.windowModel.pane2
        a.select(range: 16..<24)

        controller.copyToOtherPane()

        var expected = [UInt8](repeating: 0x00, count: 64)
        expected.replaceSubrange(16..<24, with: [UInt8](repeating: 0xAA, count: 8))
        XCTAssertEqual(try bytes(b), expected, "only the selected range, at the same address")
        XCTAssertEqual(b.fileSize, 64, "overwrite only: the destination keeps its length")
        XCTAssertEqual(b.undoLabel, "Copy to Other Pane", "one named step in the receiving document")
        XCTAssertNil(a.undoLabel, "the source is not written")
        XCTAssertEqual(b.hexSelection().start, 16, "the copy is selected where it landed")
        XCTAssertEqual(b.hexSelection().end, 24)

        _ = try b.undo()
        XCTAssertEqual(try bytes(b), [UInt8](repeating: 0x00, count: 64), "one ⌘Z takes it all back")
    }

    func testItGoesFromTheActivePaneWhicheverThatIs() throws {
        let controller = try makeComparison([UInt8](repeating: 0x00, count: 16),
                                            [UInt8](repeating: 0xBB, count: 16))
        controller.activatePaneForTesting(1)
        controller.windowModel.pane2.select(range: 0..<4)

        controller.copyToOtherPane()

        XCTAssertEqual(Array(try bytes(controller.windowModel.pane1).prefix(6)),
                       [0xBB, 0xBB, 0xBB, 0xBB, 0, 0])
    }

    func testARangePastTheEndOfTheOtherFileIsRefused() throws {
        let controller = try makeComparison([UInt8](repeating: 0xAA, count: 64),
                                            [UInt8](repeating: 0x00, count: 32))
        let b = controller.windowModel.pane2
        controller.windowModel.pane1.select(range: 24..<40)

        controller.copyToOtherPane()
        XCTAssertEqual(controller.lastAlertTitle, "Copy to Other Pane", "the refusal says so")
        XCTAssertEqual(try bytes(b), [UInt8](repeating: 0x00, count: 32), "nothing written")
        XCTAssertEqual(b.fileSize, 32, "and the destination did not grow")
    }

    func testAReadOnlyDestinationIsRefused() throws {
        let controller = try makeComparison([UInt8](repeating: 0xAA, count: 16),
                                            [UInt8](repeating: 0x00, count: 16), readOnlyB: true)
        let b = controller.windowModel.pane2
        XCTAssertTrue(b.status.isReadOnly, "precondition")
        controller.windowModel.pane1.select(range: 0..<8)

        controller.copyToOtherPane()
        XCTAssertEqual(controller.lastAlertTitle, "Copy to Other Pane")
        XCTAssertEqual(try bytes(b), [UInt8](repeating: 0x00, count: 16))
    }

    func testTheCommandNeedsTwoFilesAndASelection() throws {
        let controller = try makeComparison([UInt8](repeating: 0xAA, count: 16),
                                            [UInt8](repeating: 0x00, count: 16))
        controller.windowModel.pane1.moveCaret(to: 4)
        XCTAssertFalse(controller.validateMenuItem(menuItem), "no selection, nothing to copy")

        controller.windowModel.pane1.select(range: 0..<8)
        XCTAssertTrue(controller.validateMenuItem(menuItem))

        controller.closePane(at: 1)
        XCTAssertEqual(controller.mode, .singleFile)
        controller.windowModel.pane1.select(range: 0..<8)
        XCTAssertFalse(controller.validateMenuItem(menuItem), "one file: there is no other pane")
    }

    func testTheEditMenuOffersItOnOptionCommandC() throws {
        let item = try XCTUnwrap(MainMenu.makeEditMenu().items.first {
            $0.action == #selector(MainViewController.copyToOtherPane)
        })
        XCTAssertEqual(item.keyEquivalent, "c")
        XCTAssertEqual(item.keyEquivalentModifierMask, [.command, .option])
    }

    // MARK: - The right-click menu over a selection

    private func contextItem(_ controller: MainViewController, _ pane: PaneViewModel,
                             at offset: UInt64) -> NSMenuItem? {
        controller.makeOffsetMenu(for: pane, offset: offset).items.first {
            $0.action == #selector(MainViewController.copyPaneSelectionToOtherPane(_:))
        }
    }

    /// Offered over the selection, beside Copy, and nowhere else.
    func testTheSelectionsMenuOffersItBesideCopy() throws {
        let controller = try makeComparison([UInt8](repeating: 0xAA, count: 64),
                                            [UInt8](repeating: 0x00, count: 64))
        let a = controller.windowModel.pane1
        a.select(range: 16..<32)

        let titles = controller.makeOffsetMenu(for: a, offset: 20).items.map(\.title)
        XCTAssertEqual(Array(titles.prefix(2)), ["Copy", "Copy to Other Pane"])
        XCTAssertNil(contextItem(controller, a, at: 40), "outside the selection: not offered")
    }

    /// The right-clicked pane is the source, whichever pane is active.
    func testTheRightClickedPaneIsTheSourceEvenWhenInactive() throws {
        let controller = try makeComparison([UInt8](repeating: 0x00, count: 32),
                                            [UInt8](repeating: 0xBB, count: 32))
        let a = controller.windowModel.pane1
        let b = controller.windowModel.pane2
        XCTAssertEqual(controller.windowModel.activePaneIndex, 0, "precondition: File A is active")
        b.select(range: 8..<12)

        let item = try XCTUnwrap(contextItem(controller, b, at: 9))
        XCTAssertTrue(controller.validateMenuItem(item))
        NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item)

        XCTAssertEqual(Array(try bytes(a)[6..<14]), [0, 0, 0xBB, 0xBB, 0xBB, 0xBB, 0, 0],
                       "File B's selection went into File A")
        XCTAssertEqual(a.undoLabel, "Copy to Other Pane")
    }

    /// With one file there is no other pane, so the menu does not offer it.
    func testASingleFilesMenuDoesNotOfferIt() throws {
        let controller = try makeComparison([UInt8](repeating: 0xAA, count: 16),
                                            [UInt8](repeating: 0x00, count: 16))
        controller.closePane(at: 1)
        let a = controller.windowModel.pane1
        a.select(range: 0..<8)
        XCTAssertNil(contextItem(controller, a, at: 2))
    }
}
