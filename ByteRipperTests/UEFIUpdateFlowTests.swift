import XCTest
import ToolModuleKit
import UEFIImage
import UEFITool
@testable import UEFIToolUI
@testable import ByteRipper

/// Compare with PFAT Update File end to end in the app: a dump with a BIOS region,
/// an AMI BIOS Guard update built byte by byte for it, the sheet that lists the
/// update's parts, and the one undo step Write lands (`UEFIUpdateComparison`).
///
/// The context menu cannot be simulated, and neither can the open panel, so
/// what is driven is the seam the menu item reaches once a file is picked —
/// `compareWithUpdate(_:inRegion:)` — and the sheet's own controls.
@MainActor
final class UEFIUpdateFlowTests: XCTestCase {
    private var files: [URL] = []
    private var controller: MainViewController?
    private var window: NSWindow?
    private var defaultsName: String?

    override func setUp() {
        super.setUp()
        let isolated = isolatedDefaults(for: self)
        defaultsName = isolated.name
        ToolController.defaults = isolated.store
        ToolController.changeDelay = 0
    }

    override func tearDown() {
        // A sheet puts its window on screen, and a window left there after its
        // pane is closed is laid out again during a later test, over a tree
        // that is no longer there. So the sheet goes, and the window with it.
        if let window {
            if let sheet = try? session().updateSheet { sheet.presentingViewController?.dismiss(sheet) }
            _ = pumpUntil(2) { window.attachedSheet == nil }
            window.orderOut(nil)
        }
        controller?.windowModel.pane1.close()
        for file in files { try? FileManager.default.removeItem(at: file) }
        if let defaultsName { discardIsolatedDefaults(defaultsName, ToolController.defaults) }
        ToolController.defaults = .standard
        ToolController.changeDelay = 0.15
        controller = nil
        window = nil
        files = []
        super.tearDown()
    }

    private func open(_ bytes: [UInt8]) throws -> MainViewController {
        let url = try tempFile(bytes)
        files.append(url)
        let controller = MainViewController()
        self.controller = controller
        let window = makeTestWindow(width: 1200, height: 700)
        self.window = window
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 1200, height: 700))
        try controller.windowModel.pane1.open(url: url)
        controller.apply(mode: .singleFile)
        window.layoutIfNeeded()
        controller.tools.activate(UEFIToolModule.identifier, animated: false)
        window.layoutIfNeeded()
        let session = try session()
        let parsed = expectation(description: "the UEFI parse lands")
        session.onDisplay = { _ in parsed.fulfill() }
        wait(for: [parsed], timeout: 5)
        session.onDisplay = nil
        return controller
    }

    private func session() throws -> UEFIToolSession {
        try XCTUnwrap(controller?.tools.session as? UEFIToolSession)
    }

    /// The BIOS region of `UEFITestImage.intelImage()`: the second half.
    private let region: Range<UInt64> = 0x1000..<0x2000

    /// An update whose region is `content`, cut into the parts an ASUS file
    /// has: code, NVRAM, and the boot block.
    private func updateFile(_ content: [UInt8]) -> [UInt8] {
        let parts: [(key: String, name: String, range: Range<Int>)] = [
            ("/P", "FV_MAIN", 0..<0x800), ("/N", "NVRAM", 0x800..<0xC00), ("/B", "FV_BB", 0xC00..<0x1000)
        ]
        var text = "AMI_BIOS_GUARD_FLASH_CONFIGURATIONSII00010002\r\n"
        for part in parts { text += "1 \(part.key) 1 ;\(part.name)\r\n" }
        var bytes: [UInt8] = []
        func u16(_ value: UInt16) { bytes += [UInt8(value & 0xFF), UInt8(value >> 8)] }
        func u32(_ value: UInt32) { bytes += (0..<4).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) } }
        u32(UInt32(0x11 + text.utf8.count))
        u32(0)
        bytes += Array("_AMIPFAT".utf8) + [0x63] + Array(text.utf8)
        for part in parts {
            u16(2); u16(0)
            bytes += Array("RAPTORLAKE".utf8) + [UInt8](repeating: 0, count: 6)
            u32(0x0D)
            u16(2); u16(0)
            u32(8)
            u32(UInt32(part.range.count))
            u32(0); u32(0); u32(0)
            bytes += [UInt8](repeating: 0xFF, count: 8)
            bytes += content[part.range]
            u32(1); u32(1)
            bytes += [UInt8](repeating: 0xA5, count: 0x204)
        }
        return bytes
    }

    /// The dump's own BIOS region with the code and NVRAM parts changed: what
    /// a vendor's newer update looks like against this board.
    private func newerRegion(of image: [UInt8]) -> [UInt8] {
        var content = Array(image[Int(region.lowerBound)..<Int(region.upperBound)])
        content[0x7F0] ^= 0xFF
        content[0x900] ^= 0xFF
        return content
    }

    private func compare(_ image: [UInt8], _ content: [UInt8]) throws -> UEFIUpdateViewController {
        let session = try session()
        session.compareWithUpdate(ToolFile(name: "TEST.306", bytes: updateFile(content)), inRegion: region)
        let shown = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in MainActor.assumeIsolated { session.updateSheet != nil } },
            object: nil
        )
        wait(for: [shown], timeout: 5)
        return try XCTUnwrap(session.updateSheet as? UEFIUpdateViewController)
    }

    private func button(_ title: String, in sheet: NSViewController) throws -> NSButton {
        try XCTUnwrap(descendants(of: sheet.view, NSButton.self).first { $0.title == title }, title)
    }

    func testTheBIOSRegionRowOffersTheComparison() throws {
        _ = try open(UEFITestImage.intelImage())
        let tree = try XCTUnwrap(controller?.windowModel.pane1.uefiState.tree)
        let regions = tree.image().roots.flatMap(\.flattened).filter(UEFIPresenter.isBIOSRegion)
        XCTAssertEqual(regions.map(\.range), [region])
    }

    func testTheSheetListsThePartsWithTheCodeThatDiffersTicked() throws {
        let image = UEFITestImage.intelImage()
        _ = try open(image)
        let sheet = try compare(image, newerRegion(of: image))

        XCTAssertEqual(sheet.table.numberOfRows, 3)
        XCTAssertEqual(sheet.chosen, [0], "the code that differs, not the NVRAM, not the identical boot block")
        let texts = shownTexts(sheet.view)
        XCTAssertTrue(texts.contains("1 bytes differ"), "\(texts)")
        XCTAssertTrue(texts.contains("Board data; 1 bytes differ"), "\(texts)")
        XCTAssertTrue(texts.contains("Identical"), "\(texts)")
        XCTAssertTrue(texts.contains { $0.hasPrefix("1 of 3 parts identical. To write: 1 parts, 1 bytes.") }, "\(texts)")
    }

    func testWriteLandsTheTickedPartsAsOneUndoStep() throws {
        let image = UEFITestImage.intelImage()
        let controller = try open(image)
        let newer = newerRegion(of: image)
        let sheet = try compare(image, newer)

        try button("Write", in: sheet).performClick(nil)

        XCTAssertNil(try session().updateSheet, "Write closes the sheet")
        let storage = try XCTUnwrap(controller.windowModel.pane1.byteStorage)
        XCTAssertEqual(try storage.read(at: 0x17F0, length: 1), [newer[0x7F0]], "the code is the update's")
        XCTAssertEqual(try storage.read(at: 0x1900, length: 1), [image[0x1900]], "the board's NVRAM is kept")
        XCTAssertEqual(controller.lastAlertTitle, "Written from the update file")

        let item = NSMenuItem(title: "Undo", action: #selector(MainViewController.undoEdit), keyEquivalent: "z")
        _ = controller.validateMenuItem(item)
        XCTAssertEqual(item.title, "Undo Write from Update File")
    }

    func testTickingNVRAMWritesItToo() throws {
        let image = UEFITestImage.intelImage()
        let controller = try open(image)
        let newer = newerRegion(of: image)
        let sheet = try compare(image, newer)

        sheet.setChosen(1, true)
        try button("Write", in: sheet).performClick(nil)

        let storage = try XCTUnwrap(controller.windowModel.pane1.byteStorage)
        XCTAssertEqual(try storage.read(at: 0x1900, length: 1), [newer[0x900]])
    }

    func testCancelWritesNothing() throws {
        let image = UEFITestImage.intelImage()
        let controller = try open(image)
        let sheet = try compare(image, newerRegion(of: image))

        try button("Cancel", in: sheet).performClick(nil)

        XCTAssertNil(try session().updateSheet)
        let storage = try XCTUnwrap(controller.windowModel.pane1.byteStorage)
        XCTAssertEqual(try storage.read(at: 0x17F0, length: 1), [image[0x17F0]])
    }

    func testAnUpdateForAnotherBoardIsRefusedWithTheReason() throws {
        let image = UEFITestImage.intelImage()
        let controller = try open(image)
        let session = try session()
        let short = Array(image[0x1000..<0x1C00]) + [UInt8](repeating: 0xFF, count: 0x400)
        var file = updateFile(short)
        // Drop the last part: a region of 0xC00 bytes against a dump's 0x1000.
        let text = Array("1 /B 1 ;FV_BB\r\n".utf8)
        let at = try XCTUnwrap(file.firstRange(of: text))
        file.replaceSubrange(at, with: [UInt8](repeating: 0x20, count: text.count))

        session.compareWithUpdate(ToolFile(name: "OTHER.306", bytes: file), inRegion: region)
        let refused = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in MainActor.assumeIsolated { controller.lastAlertTitle != nil } },
            object: nil
        )
        wait(for: [refused], timeout: 5)

        XCTAssertNil(session.updateSheet)
        XCTAssertEqual(controller.lastAlertTitle, "Could not compare with the update file")
        XCTAssertEqual(controller.lastAlertOutcome, .problem)
    }

    // MARK: - The update file itself

    /// Opening the update file shows the update at the top; opening its row
    /// shows the entries of its table, and an entry its volume.
    func testAnUpdateFileOpensOntoItsEntriesAndTheirVolumes() throws {
        let image = UEFITestImage.intelImage()
        let controller = try open(updateFile(Array(image[0x1000..<0x2000])))
        let tree = try XCTUnwrap(controller.windowModel.pane1.uefiState.tree)
        let outline = try XCTUnwrap(descendants(of: try XCTUnwrap(controller.tools.panel), NSOutlineView.self).first)
        func node(_ row: Int) -> UEFINode? {
            (outline.item(atRow: row) as? UEFITreeRow).flatMap { tree.node($0.id) }
        }
        func expand(_ row: Int) throws {
            let id = try XCTUnwrap((outline.item(atRow: row) as? UEFITreeRow)?.id)
            let opened = expectation(description: "the branch is read")
            tree.expand(id) { _ in opened.fulfill() }
            wait(for: [opened], timeout: 5)
            outline.expandItem(outline.item(atRow: row))
            window?.layoutIfNeeded()
        }

        XCTAssertEqual(node(0)?.kind, .biosGuardUpdate)
        XCTAssertEqual(node(0)?.name, "AMI BIOS Guard update")
        try expand(0)
        XCTAssertEqual((1..<outline.numberOfRows).compactMap { node($0)?.name }.prefix(3),
                       ["FV_MAIN", "NVRAM", "FV_BB"])
        try expand(1)
        XCTAssertEqual(node(2)?.kind, .volume, "FV_MAIN holds the test image's volume")
        XCTAssertEqual(node(2)?.space, .decompressed(chain: [0]))
    }
}
