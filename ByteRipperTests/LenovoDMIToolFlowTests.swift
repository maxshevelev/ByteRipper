import XCTest
import LenovoDMITool
import LenovoDMIToolUI
import ToolModuleKit
@testable import ByteRipper

/// An image with a Lenovo identity store in it, laid out as the real dumps lay
/// theirs out — the log, then two blocks XORed with one key — with made-up
/// values.
private enum LenovoTestImage {
    static let key: UInt8 = 0x77
    static let namespace: [UInt8] = [
        0x55, 0x57, 0x0E, 0xC2, 0x69, 0x11, 0x56, 0x4C,
        0xA4, 0x8A, 0x98, 0x24, 0xAB, 0x43
    ]
    /// Where the log starts; the blocks follow at +0x2000 and +0x3000.
    static let area = 0x1000
    /// Block 2's serial number value, in the file.
    static let serialInBlock2 = 0x4000 + 0x10 + 0x18

    static func block(generation: UInt32) -> [UInt8] {
        var body = namespace + [0x00, 0x04] + le32(8) + [0, 0, 0, 0] + Array("PF0TEST1".utf8)
        body += [UInt8](repeating: 0, count: 0x1000 - 16 - body.count)
        body = body.map { $0 ^ key }
        let sum = body.reduce(UInt16(0)) { $0 &+ UInt16($1) }
        return Array("LENV".utf8) + le32(generation) + le32(1)
            + [0, key, UInt8(sum & 0xFF), UInt8(sum >> 8)] + body
    }

    static func make() -> [UInt8] {
        let log = Array("LDBG".utf8) + le32(0x20) + [UInt8](repeating: 0, count: 24)
            + [UInt8](repeating: key, count: 0x2000 - 0x20)
        return [UInt8](repeating: 0xFF, count: area) + log
            + block(generation: 4) + block(generation: 5)
            + [UInt8](repeating: 0xFF, count: 0x1000)
    }

    static func le32(_ value: UInt32) -> [UInt8] { (0..<4).map { UInt8((value >> (8 * $0)) & 0xFF) } }
}

/// The Lenovo DMI tool-module in the app: a real image, the zones it
/// publishes, and a re-read after an edit in the dump.
@MainActor
final class LenovoDMIToolFlowTests: XCTestCase {
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
        controller.tools.activate(LenovoDMIToolModule.identifier, animated: false)
        window.layoutIfNeeded()
        try waitForParse()
        return controller
    }

    /// Waits on the session's own seam rather than on the clock.
    private func waitForParse() throws {
        let session = try session()
        let parsed = expectation(description: "the Lenovo DMI reading lands")
        session.onDisplay = { _ in parsed.fulfill() }
        wait(for: [parsed], timeout: 5)
        session.onDisplay = nil
        window?.layoutIfNeeded()
    }

    private func session() throws -> LenovoDMIToolSession {
        try XCTUnwrap(controller?.tools.session as? LenovoDMIToolSession)
    }

    private func outline() throws -> NSOutlineView {
        let panel = try XCTUnwrap(controller?.tools.panel)
        return try XCTUnwrap(descendants(of: panel, NSOutlineView.self).first)
    }

    func testTheAppShipsIt() {
        XCTAssertTrue(ToolRegistry.builtIn.contains { $0.identifier == LenovoDMIToolModule.identifier },
                      "the registry ships the Lenovo DMI tool")
    }

    func testThePanelListsTheLogAndBothBlocks() throws {
        _ = try open(LenovoTestImage.make())
        let display = try session().display
        XCTAssertEqual(display.summary, "LENV block 2 is live: generation 5.")
        XCTAssertEqual(try outline().numberOfRows, 3)
        XCTAssertEqual(display.rows[2].children.first?.value, "PF0TEST1")
    }

    func testTheThreePartsAreMarkedInTheDump() throws {
        let controller = try open(LenovoTestImage.make())
        let zones = controller.windowModel.pane1.zones.zones
        XCTAssertEqual(zones.map(\.id), ["a0.log", "a0.lenv1", "a0.lenv2"])
        XCTAssertEqual(zones.map(\.range), [0x1000..<0x3000, 0x3000..<0x4000, 0x4000..<0x5000])
    }

    /// Picking an entry opens its block in the dump and puts the entry in
    /// focus; the outline in the panel follows.
    func testPickingAnEntryFocusesItInTheDump() throws {
        let controller = try open(LenovoTestImage.make())
        try session().select("a0.lenv2.0")
        window?.layoutIfNeeded()

        let pane = controller.windowModel.pane1
        XCTAssertEqual(pane.zones.focus, "a0.lenv2.0")
        XCTAssertEqual(pane.zones.zones.first { $0.id == "a0.lenv2.0" }?.range, 0x4010..<0x4030)
        let outline = try outline()
        XCTAssertEqual(outline.numberOfRows, 4, "block 2 is opened")
        XCTAssertEqual(outline.selectedRow, 3)
    }

    /// A byte typed into the encrypted value is read again at once: the value
    /// changes, and so does the verdict on the checksum.
    func testAnEditInTheDumpIsReadAgain() throws {
        let controller = try open(LenovoTestImage.make())
        try session().select("a0.lenv2.0")
        let pane = controller.windowModel.pane1
        // `P` is 0x50; stored XOR 0x77 it is 0x27. Typing 0x26 makes it `Q`.
        pane.moveCaret(to: UInt64(LenovoTestImage.serialInBlock2))
        pane.typeHexNibble(0x2)
        pane.typeHexNibble(0x6)
        try waitForParse()

        let display = try session().display
        XCTAssertEqual(display.rows[2].children.first?.value, "QF0TEST1")
        XCTAssertTrue(display.rows[2].isProblem, "the checksum no longer adds up")
        XCTAssertEqual(pane.zones.focus, "a0.lenv2.0", "the row in focus survives the re-read")
    }

    func testAnImageWithoutAStoreSaysSo() throws {
        let controller = try open([UInt8](repeating: 0xFF, count: 0x8000))
        XCTAssertEqual(try session().display.summary, "No Lenovo DMI store in this image.")
        XCTAssertTrue(controller.windowModel.pane1.zones.zones.isEmpty)
    }
}
