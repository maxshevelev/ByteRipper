import ByteRipperCore
import XCTest
@testable import ByteRipper

/// §7.2 / §7.6: the confirmations that guard the edits which shift a file can be
/// switched off — from Settings ▸ General, or from the "Do not ask again"
/// checkbox on the alerts themselves, which is the same switch.
///
/// The commands are driven for real here. Under XCTest an alert answers Cancel
/// (`presentModal`), so "the edit happened" is itself the proof that no alert was
/// shown, and "nothing happened" the proof that one was.
@MainActor
final class EditingSettingsTests: XCTestCase {
    override func setUp() {
        super.setUp()
        EditingSettings.resetToDefaults()
    }

    override func tearDown() {
        EditingSettings.resetToDefaults()
        super.tearDown()
    }

    // MARK: - The stored value

    func testWarningsAreOnUntilSwitchedOff() {
        XCTAssertTrue(EditingSettings.warnsBeforeShiftingEdits,
                      "a fresh install asks: shifting a dump's offsets is the edit that ruins it")

        EditingSettings.set(warnsBeforeShiftingEdits: false)
        XCTAssertFalse(EditingSettings.warnsBeforeShiftingEdits,
                       "and false must survive being read back — not read as unset")

        EditingSettings.set(warnsBeforeShiftingEdits: true)
        XCTAssertTrue(EditingSettings.warnsBeforeShiftingEdits)
    }

    /// The Settings tab shows the stored value and writes the user's choice.
    func testTheEditingTabReflectsAndWritesTheSetting() {
        let controller = EditingSettingsViewController()
        _ = controller.view                      // loadView
        XCTAssertTrue(controller.warnsBeforeShiftingEdits)

        EditingSettings.set(warnsBeforeShiftingEdits: false)
        controller.refresh()
        XCTAssertFalse(controller.warnsBeforeShiftingEdits,
                       "an alert's checkbox turned it off; the tab must agree")
    }

    /// The checkbox on the alert is the same switch as the tab's.
    func testAnAlertsSuppressionCheckboxSwitchesTheWarningsOff() {
        let alert = NSAlert()
        alert.showsSuppressionButton = true
        XCTAssertNotNil(alert.suppressionButton)

        MainViewController.applySuppression(of: alert)
        XCTAssertTrue(EditingSettings.warnsBeforeShiftingEdits,
                      "an untouched checkbox changes nothing")

        alert.suppressionButton?.state = .on
        MainViewController.applySuppression(of: alert)
        XCTAssertFalse(EditingSettings.warnsBeforeShiftingEdits)
    }

    // MARK: - The undo history's bounds

    /// Large by default — dumps are large — with no bound on steps, and every
    /// choice handed to the histories at once.
    func testTheUndoBoundsDefaultLargeAndReachEveryHistory() {
        XCTAssertEqual(EditingSettings.undoHistoryMiB, 4096)
        XCTAssertEqual(EditingSettings.undoSteps, 0)
        XCTAssertEqual(UndoLimits.current, UndoLimits(bytes: 4 << 30, transactions: nil))

        EditingSettings.set(undoHistoryMiB: 512)
        EditingSettings.set(undoSteps: 10_000)
        XCTAssertEqual(UndoLimits.current, UndoLimits(bytes: 512 << 20, transactions: 10_000))
    }

    /// The tab shows the stored bounds and writes the user's choice.
    func testTheEditingTabReflectsAndWritesTheUndoBounds() {
        let controller = EditingSettingsViewController()
        _ = controller.view
        XCTAssertEqual(controller.historySizeShownMiB, 4096)
        XCTAssertEqual(controller.historyStepsShown, 0)

        controller.chooseHistorySize(mib: 16384)
        controller.chooseHistorySteps(100_000)
        XCTAssertEqual(EditingSettings.undoHistoryMiB, 16384)
        XCTAssertEqual(EditingSettings.undoSteps, 100_000)
        XCTAssertEqual(UndoLimits.current.transactions, 100_000)
    }

    /// A step the bounds dropped takes its cuts' snapshot with it: undoing all
    /// that is left puts the cuts where the dropped edit left them.
    func testTheCutsFollowTheStepsTheBoundsKeep() throws {
        let (controller, pane, url) = try makeController([UInt8](0..<32))
        defer { controller.windowModel.pane1.close(); try? FileManager.default.removeItem(at: url) }
        EditingSettings.set(warnsBeforeShiftingEdits: false)
        let doc = try XCTUnwrap(pane.document)
        doc.undoHistory.limits = UndoLimits(bytes: nil, transactions: 2)
        pane.segmentStore.addCut(at: 16)

        try pane.deleteBytes(in: 0..<4)                          // dropped later: the cut at 12
        XCTAssertEqual(pane.segmentStore.segments.map(\.range), [0..<12, 12..<28])
        try pane.deleteBytes(in: 0..<2)                          // the cut at 10
        try pane.deleteBytes(in: 0..<2)                          // the cut at 8
        XCTAssertEqual(doc.undoHistory.undoDepth, 2)

        XCTAssertTrue(try pane.undo())
        XCTAssertTrue(try pane.undo())
        XCTAssertFalse(try pane.undo())
        XCTAssertEqual(pane.segmentStore.segments.map(\.range), [0..<12, 12..<28])
        XCTAssertTrue(try pane.redo())
        XCTAssertEqual(pane.segmentStore.segments.map(\.range), [0..<10, 10..<26])
    }

    // MARK: - What the commands do with it

    private func makeController(_ bytes: [UInt8]) throws -> (MainViewController, PaneViewModel, URL) {
        let url = try tempFile(bytes)
        let controller = MainViewController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentViewController = controller
        window.layoutIfNeeded()
        try controller.windowModel.pane1.open(url: url)
        controller.apply(mode: .singleFile)
        window.layoutIfNeeded()
        return (controller, controller.windowModel.pane1, url)
    }

    /// Delete Bytes asks while the warnings are on — and under test the answer
    /// is Cancel, so the file is untouched. With them off it deletes.
    func testDeleteBytesAsksUntilTheWarningsAreOff() throws {
        let (controller, pane, url) = try makeController([0x11, 0x22, 0x33, 0x44])
        defer { try? FileManager.default.removeItem(at: url) }
        pane.select(range: 1..<3)

        controller.deleteBytes()
        XCTAssertEqual(pane.fileSize, 4, "the confirmation was cancelled, so nothing went")

        EditingSettings.set(warnsBeforeShiftingEdits: false)
        controller.deleteBytes()
        XCTAssertEqual(pane.fileSize, 2, "no confirmation, straight to the delete")
        XCTAssertEqual(pane.hexByteStates(in: 0..<2).map(\.byte), [0x11, 0x44])
    }

    /// The same for the first insert-mode keystroke in a file.
    func testInsertModeTypingAsksUntilTheWarningsAreOff() throws {
        let (controller, pane, url) = try makeController([0x11, 0x22])
        defer { try? FileManager.default.removeItem(at: url) }
        controller.toggleInsertMode(nil)          // also wires the warning
        XCTAssertTrue(pane.isInsertMode)
        pane.moveCaret(to: 0)

        pane.typeASCII(0x41)
        XCTAssertEqual(pane.fileSize, 2, "cancelled: the keystroke was swallowed")

        EditingSettings.set(warnsBeforeShiftingEdits: false)
        pane.typeASCII(0x41)
        XCTAssertEqual(pane.fileSize, 3, "no confirmation, the byte lands")
        XCTAssertEqual(pane.hexByteStates(in: 0..<3).map(\.byte), [0x41, 0x11, 0x22])
    }

    /// Paste Insert, the third of the §7.2 confirmations.
    func testPasteInsertAsksUntilTheWarningsAreOff() throws {
        let (controller, pane, url) = try makeController([0x11, 0x22])
        defer { try? FileManager.default.removeItem(at: url) }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(Data([0xAA, 0xBB]), forType: .init("dev.maxik.ByteRipper.bytes"))
        pasteboard.setString("AA BB", forType: .string)
        pane.moveCaret(to: 1)

        controller.pasteInsert()
        XCTAssertEqual(pane.fileSize, 2, "cancelled")

        EditingSettings.set(warnsBeforeShiftingEdits: false)
        controller.pasteInsert()
        XCTAssertEqual(pane.fileSize, 4, "no confirmation, the bytes go in")
    }
}
