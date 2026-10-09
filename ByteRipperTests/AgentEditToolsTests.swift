import AgentKit
import XCTest
@testable import ByteRipper

/// An agent's changes to a file (`Design/AGENT_PLAN.md`, stage 7): refused
/// until the person allows edits, then each one undo step named after what
/// the agent said it is — a write, or a checksum a module puts right — and
/// never to a file opened read-only or opened by path with no tab.
@MainActor
final class AgentEditToolsTests: XCTestCase {
    private var controller: MainViewController?
    private var window: NSWindow?
    private var service: AgentService!
    private var client: AgentTestClient!
    private var defaultsName = ""
    private var defaults: UserDefaults!
    private var folder: URL!

    override func setUp() {
        super.setUp()
        (defaultsName, defaults) = isolatedDefaults(for: self)
        let desk = AgentDesk(controllers: { [weak self] in self?.controller.map { [$0] } ?? [] },
                             keyController: { [weak self] in self?.controller })
        service = AgentService(desk: desk, defaults: defaults,
                               socketPath: "/tmp/br-\(UUID().uuidString.prefix(8)).sock")
        client = AgentTestClient(service)
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("agent-edits-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        service.stop()
        controller?.windowModel.pane1.close()
        window?.orderOut(nil)
        window = nil
        controller = nil
        if let folder {
            for file in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] {
                try? FileManager.default.setAttributes([.posixPermissions: 0o644],
                                                       ofItemAtPath: folder.appendingPathComponent(file).path)
            }
            try? FileManager.default.removeItem(at: folder)
        }
        discardIsolatedDefaults(defaultsName, defaults)
        super.tearDown()
    }

    @discardableResult
    private func open(_ bytes: [UInt8], readOnly: Bool = false) throws -> PaneViewModel {
        let controller = MainViewController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 900, height: 600))
        window.makeKeyAndOrderFront(nil)
        self.controller = controller
        self.window = window
        let url = try write(bytes, "front.bin")
        if readOnly {
            try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: url.path)
        }
        try controller.windowModel.pane1.open(url: url)
        controller.apply(mode: .singleFile)
        return controller.windowModel.pane1
    }

    @discardableResult
    private func write(_ bytes: [UInt8], _ name: String) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try Data(bytes).write(to: url)
        return url
    }

    private func bytes(_ pane: PaneViewModel, _ range: Range<UInt64>) throws -> [UInt8] {
        try XCTUnwrap(pane.byteStorage).read(at: range.lowerBound, length: Int(range.count))
    }

    // MARK: - The list

    func testTheEditToolsAreListedAsEdits() throws {
        let tools = Dictionary(uniqueKeysWithValues: service.server.tools.map { ($0.name, $0) })
        for name in ["write", "uefi_fix_checksum", "fit_fix_checksum"] {
            let tool = try XCTUnwrap(tools[name], name)
            XCTAssertEqual(tool.annotations, .edit, name)
            XCTAssertNotNil(tool.inputSchema["properties"]?["document"], name)
        }
    }

    // MARK: - The switch

    func testAWriteIsRefusedUntilThePersonAllowsEdits() async throws {
        let pane = try open([0, 0, 0, 0])
        XCTAssertFalse(service.editsAllowed, "off after an install")
        let refused = try await client.call("write", ["offset": 1, "bytes": "FF", "label": "Patch"])
        XCTAssertTrue(refused.isError)
        XCTAssertTrue(refused.answer.stringValue?.hasPrefix("Editing is switched off.") == true, "\(refused.answer)")
        XCTAssertEqual(try bytes(pane, 0..<4), [0, 0, 0, 0])
    }

    func testTheSettingsSwitchAllowsEdits() {
        let settings = AgentSettingsViewController()
        settings.service = service
        _ = settings.view
        XCTAssertFalse(settings.editsAllowedShown)
        settings.toggleEditsForTesting()
        XCTAssertTrue(service.editsAllowed)
        XCTAssertTrue(defaults.bool(forKey: AgentService.editsKey))
        XCTAssertFalse(service.isEnabled, "the service's own switch is apart")
    }

    // MARK: - write

    func testAWriteIsOneUndoStepNamedByItsLabel() async throws {
        let pane = try open([0x10, 0x11, 0x12, 0x13, 0x14])
        service.editsAllowed = true
        let answer = try await client.answer("write", ["offset": "0x1", "bytes": "de ad", "label": "Patch the flag"])
        XCTAssertEqual(try bytes(pane, 0..<5), [0x10, 0xDE, 0xAD, 0x13, 0x14])
        XCTAssertEqual(answer["undo"], "Agent: Patch the flag")
        XCTAssertEqual(answer["saved"], false)
        XCTAssertEqual(answer["written"]?.arrayValue?.first?["before"], "11 12")
        XCTAssertEqual(answer["written"]?.arrayValue?.first?["end"], "0x3")
        XCTAssertEqual(pane.undoLabel, "Agent: Patch the flag")
        XCTAssertTrue(pane.status.isDirty, "unsaved, like a hand edit")

        XCTAssertTrue(try pane.undo())
        XCTAssertEqual(try bytes(pane, 0..<5), [0x10, 0x11, 0x12, 0x13, 0x14])
    }

    func testExpectWritesOnlyOverTheBytesNamed() async throws {
        let pane = try open([1, 2, 3, 4])
        service.editsAllowed = true
        let refused = try await client.call("write", ["offset": 0, "bytes": "AA", "label": "X", "expect": "09"])
        XCTAssertEqual(refused.answer, "Nothing written: the bytes at 0x0 are 01, not 09.")
        XCTAssertEqual(try bytes(pane, 0..<4), [1, 2, 3, 4])
        _ = try await client.answer("write", ["offset": 0, "bytes": "AA", "label": "X", "expect": "0x01"])
        XCTAssertEqual(try bytes(pane, 0..<1), [0xAA])
    }

    func testWritesThatWouldResizeOrAreNotHexAreRefused() async throws {
        let pane = try open([1, 2, 3, 4])
        service.editsAllowed = true
        let past = try await client.call("write", ["offset": 3, "bytes": "AA BB", "label": "X"])
        XCTAssertTrue(past.answer.stringValue?.contains("Writes overwrite; they do not grow the file.") == true,
                      "\(past.answer)")
        let odd = try await client.call("write", ["offset": 0, "bytes": "ABC", "label": "X"])
        XCTAssertEqual(odd.answer, "`bytes` is not hex bytes. Give pairs of hex digits, e.g. \"DE AD BE EF\".")
        let unnamed = try await client.call("write", ["offset": 0, "bytes": "AA", "label": "  "])
        XCTAssertEqual(unnamed.answer, "`label` is empty; say what the change is.")
        XCTAssertEqual(try bytes(pane, 0..<4), [1, 2, 3, 4])
        XCTAssertNil(pane.undoLabel)
    }

    func testAFileOpenedReadOnlyIsNeverChanged() async throws {
        let pane = try open([1, 2, 3, 4], readOnly: true)
        XCTAssertTrue(pane.status.isReadOnly)
        service.editsAllowed = true
        let refused = try await client.call("write", ["offset": 0, "bytes": "AA", "label": "X"])
        XCTAssertEqual(refused.answer, "d1 is open read-only; nothing in it can be changed.")
    }

    func testABackgroundDumpIsNeverChanged() async throws {
        try open([0])
        service.editsAllowed = true
        let url = try write([1, 2], "other.bin")
        let opened = try await client.answer("open_dump", ["path": .string(url.path)])
        let id = try XCTUnwrap(opened["document"]?.stringValue)
        let refused = try await client.call("write", ["document": .string(id), "offset": 0, "bytes": "AA", "label": "X"])
        XCTAssertEqual(refused.answer, .string("\(id) is open in the background, not on screen. Call `show` to open it in a tab first."))
        XCTAssertEqual(try Data(contentsOf: url), Data([1, 2]))
    }

    // MARK: - Checksums

    func testAVolumeChecksumIsPutRightAsOneUndoStep() async throws {
        let good = UEFITestImage.make()
        var corrupt = good
        corrupt[0x32] ^= 0xFF
        let pane = try open(corrupt)

        let refused = try await client.call("uefi_fix_checksum", ["node": "0"])
        XCTAssertTrue(refused.answer.stringValue?.hasPrefix("Editing is switched off.") == true, "\(refused.answer)")

        service.editsAllowed = true
        let fixed = try await client.answer("uefi_fix_checksum", ["node": "0"])
        XCTAssertEqual(try bytes(pane, 0x32..<0x34), Array(good[0x32..<0x34]))
        XCTAssertEqual(fixed["undo"], "Agent: Fix Checksum")
        XCTAssertEqual(pane.undoLabel, "Agent: Fix Checksum")

        let again = try await client.call("uefi_fix_checksum", ["node": "0"])
        XCTAssertEqual(again.answer, "The checksums of 0 already check out; nothing to write.")
    }

    func testTheFITChecksumIsPutRight() async throws {
        let pane = try open(FITTestImage.make(checksum: 0x42))
        service.editsAllowed = true
        let before = try await client.answer("fit_table")
        let should = try XCTUnwrap(before["table"]?["checksum_should_be"]?.stringValue)
        let start = try XCTUnwrap(before["table"]?["start"]?.stringValue)

        let fixed = try await client.answer("fit_fix_checksum")
        XCTAssertEqual(fixed["undo"], "Agent: Fix FIT Checksum")
        let after = try await client.answer("fit_table")
        XCTAssertEqual(after["table"]?["checksum"]?.stringValue, should)
        XCTAssertEqual(after["problems"]?.arrayValue?.contains { $0["severity"] == "error" }, false, "\(after)")
        let offset = try XCTUnwrap(UInt64(start.dropFirst(2), radix: 16)) + 0x0F
        XCTAssertEqual(try bytes(pane, offset..<(offset + 1)).first, UInt8(should.dropFirst(2), radix: 16))

        let again = try await client.call("fit_fix_checksum")
        XCTAssertEqual(again.answer, "The FIT checksum is already correct; nothing to write.")
    }
}
