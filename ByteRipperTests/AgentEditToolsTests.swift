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
        for name in ["write", "copy_to_other_pane", "update_in_parent", "uefi_fix_checksum", "fit_fix_checksum"] {
            let tool = try XCTUnwrap(tools[name], name)
            XCTAssertEqual(tool.annotations, .edit, name)
            XCTAssertNotNil(tool.inputSchema["properties"]?["document"], name)
        }
    }

    // MARK: - update_in_parent

    /// A part edited and put back: the parent gets the bytes as one undo step;
    /// asked again, there is nothing new to put back.
    func testAPartGoesBackIntoItsParent() async throws {
        let parent = try open([UInt8](repeating: 0, count: 0x1000))
        service.editsAllowed = true
        let part = try await client.answer("open_part", ["offset": "0x800", "length": "0x100"])
        let id = try XCTUnwrap(part["document"])
        _ = try await client.answer("write", ["document": id, "offset": "0x10", "bytes": "DEADBEEF", "label": "t"])
        let updated = try await client.answer("update_in_parent", ["document": id])
        XCTAssertEqual(updated["updated"], true)
        XCTAssertEqual(updated["parent"], "d1")
        XCTAssertEqual(updated["saved"], false)
        XCTAssertEqual(try bytes(parent, 0x810..<0x814), [0xDE, 0xAD, 0xBE, 0xEF])
        XCTAssertTrue(parent.status.isDirty)

        let again = try await client.answer("update_in_parent", ["document": id])
        XCTAssertEqual(again["updated"], false, "nothing new")
    }

    /// A decompressed body goes back compressed: the file then holds the
    /// change only inside the section, and the section reads it.
    func testADecompressedPartGoesBackCompressed() async throws {
        let parent = try open(try CompressedTestImage.make(holding: "SECRET-MODEL-GH51G"))
        service.editsAllowed = true
        let found = try await client.answer("uefi_find", ["type": "Section", "limit": 50])
        let section = try XCTUnwrap(found["matches"]?.arrayValue?.first { $0["subtype"] == "Compressed section" }?["id"])
        let part = try await client.answer("open_part", ["node": section, "part": "decompressed"])
        let id = try XCTUnwrap(part["document"])
        let at = try await client.answer("find_bytes", ["document": id, "text": "GH51G"])
        let start = try XCTUnwrap(at["matches"]?.arrayValue?.first?["start"])
        _ = try await client.answer("write", ["document": id, "offset": start, "bytes": "58593939 5A", "label": "t"])

        let updated = try await client.answer("update_in_parent", ["document": id])
        XCTAssertEqual(updated["updated"], true, "\(updated)")
        XCTAssertTrue(parent.status.isDirty)
        let inFile = try await client.answer("find_bytes", ["document": "d1", "text": "XY99Z"])
        XCTAssertEqual(inFile["total"], 0, "the file holds it compressed")
        let inSection = try await client.answer("find_bytes", ["document": "d1", "node": section, "text": "XY99Z"])
        XCTAssertEqual(inSection["total"], 1, "the section decompresses to the change")
    }

    /// Bytes changed in the parent since the part was opened are not
    /// overwritten unless the call says so.
    func testAChangedSourceIsOverwrittenOnlyWhenAsked() async throws {
        let parent = try open([UInt8](repeating: 0, count: 0x1000))
        service.editsAllowed = true
        let part = try await client.answer("open_part", ["offset": "0x800", "length": "0x100"])
        let id = try XCTUnwrap(part["document"])
        _ = try await client.answer("write", ["document": "d1", "offset": "0x880", "bytes": "11", "label": "t"])
        _ = try await client.answer("write", ["document": id, "offset": "0x0", "bytes": "22", "label": "t"])

        let refused = try await client.call("update_in_parent", ["document": id])
        XCTAssertTrue(refused.isError)
        XCTAssertTrue(refused.answer.stringValue?.contains("overwrite_changed_source") == true, "\(refused.answer)")
        XCTAssertEqual(try bytes(parent, 0x800..<0x801), [0x00], "nothing written")

        let updated = try await client.answer("update_in_parent", ["document": id, "overwrite_changed_source": true])
        XCTAssertEqual(updated["updated"], true)
        XCTAssertEqual(try bytes(parent, 0x800..<0x801), [0x22])
        XCTAssertEqual(try bytes(parent, 0x880..<0x881), [0x00], "the part's bytes, over the parent's change")
    }

    /// What has no parent, may not be changed, or cannot be put back is
    /// refused, and nothing is written.
    func testWhatCannotGoBackIsRefused() async throws {
        let parent = try open([UInt8](repeating: 0, count: 0x1000))
        let notPart = try await client.call("update_in_parent", ["document": "d1"])
        XCTAssertTrue(notPart.answer.stringValue?.contains("is not a part") == true, "\(notPart.answer)")

        let part = try await client.answer("open_part", ["offset": "0x800", "length": "0x100"])
        let id = try XCTUnwrap(part["document"])
        let switchedOff = try await client.call("update_in_parent", ["document": id])
        XCTAssertTrue(switchedOff.answer.stringValue?.contains("Editing is switched off") == true)

        service.editsAllowed = true
        _ = try await client.answer("write", ["document": id, "offset": "0x0", "bytes": "22", "label": "t"])
        parent.close()
        let closed = try await client.call("update_in_parent", ["document": id])
        XCTAssertTrue(closed.isError, "\(closed.answer)")
        XCTAssertTrue(closed.answer.stringValue?.contains("is no longer open") == true, "\(closed.answer)")
    }

    /// A read-only parent cannot take the part back.
    func testAReadOnlyParentIsRefused() async throws {
        try open([UInt8](repeating: 0, count: 0x1000), readOnly: true)
        service.editsAllowed = true
        let part = try await client.answer("open_part", ["offset": "0x800", "length": "0x100"])
        let id = try XCTUnwrap(part["document"])
        _ = try await client.answer("write", ["document": id, "offset": "0x0", "bytes": "22", "label": "t"])
        let refused = try await client.call("update_in_parent", ["document": id])
        XCTAssertTrue(refused.isError)
        XCTAssertTrue(refused.answer.stringValue?.contains("Nothing was written") == true, "\(refused.answer)")
    }

    /// Two files side by side in one tab, A first; B read-only when asked.
    private func openPair(_ a: [UInt8], _ b: [UInt8], bReadOnly: Bool = false) throws -> (PaneViewModel, PaneViewModel) {
        let first = try open(a)
        let url = try write(b, "back.bin")
        if bReadOnly {
            try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: url.path)
        }
        let controller = try XCTUnwrap(self.controller)
        try controller.windowModel.pane2.open(url: url)
        controller.apply(mode: .comparison)
        return (first, controller.windowModel.pane2)
    }

    private func id(of pane: PaneViewModel) throws -> String {
        try XCTUnwrap(service.desk.places().first { $0.pane === pane }?.id)
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

    // MARK: - copy_to_other_pane

    /// The bytes go over the same addresses in the other file, as ⌥⌘C does:
    /// one undo step there, the source untouched, the count of bytes that
    /// actually changed in the answer.
    func testACopyToTheOtherPaneIsOneUndoStepThere() async throws {
        let (a, b) = try openPair([1, 2, 3, 4, 5, 6], [1, 9, 3, 9, 9, 6])
        service.editsAllowed = true
        let answer = try await client.answer("copy_to_other_pane",
                                             ["document": .string(try id(of: a)), "offset": 1, "length": "0x4"])
        XCTAssertEqual(try bytes(b, 0..<6), [1, 2, 3, 4, 5, 6])
        XCTAssertEqual(try bytes(a, 0..<6), [1, 2, 3, 4, 5, 6], "the source is only read")
        XCTAssertEqual(answer["changed"], 3)
        XCTAssertEqual(answer["to"], .string(try id(of: b)))
        XCTAssertEqual(answer["end"], "0x5")
        XCTAssertEqual(answer["undo"], "Agent: Copy to Other Pane")
        XCTAssertEqual(b.undoLabel, "Agent: Copy to Other Pane")
        XCTAssertFalse(a.status.isDirty)
        XCTAssertTrue(try b.undo())
        XCTAssertEqual(try bytes(b, 0..<6), [1, 9, 3, 9, 9, 6])

        // And back, B into A, under the agent's own words.
        _ = try await client.answer("copy_to_other_pane", ["document": .string(try id(of: b)), "offset": 0,
                                                           "length": 2, "label": "Take B's header"])
        XCTAssertEqual(try bytes(a, 0..<2), [1, 9])
        XCTAssertEqual(a.undoLabel, "Agent: Take B's header")
    }

    /// The answer says where in the firmware the copied range lies, as
    /// `diff` and `find_bytes` do.
    func testACopyNamesThePartOfTheFirmwareItCovers() async throws {
        let image = try CompressedTestImage.make(holding: "MODEL")
        let (_, b) = try openPair(image, [UInt8](repeating: 0xFF, count: image.count))
        service.editsAllowed = true
        let answer = try await client.answer("copy_to_other_pane", ["offset": 0, "length": .int(Int64(image.count))])
        XCTAssertEqual(try bytes(b, 0..<UInt64(image.count)), image)
        XCTAssertNotNil(answer["where"]?.arrayValue?.first?["name"], "\(answer)")
    }

    func testACopyOverIdenticalBytesWritesNothing() async throws {
        let (_, b) = try openPair([1, 2, 3], [1, 2, 3])
        service.editsAllowed = true
        let answer = try await client.answer("copy_to_other_pane", ["offset": 0, "length": 3])
        XCTAssertEqual(answer["changed"], 0)
        XCTAssertEqual(answer["undo"], .null)
        XCTAssertFalse(b.status.isDirty, "no undo step for nothing")
    }

    func testACopyIsRefusedWhereTheMenuRefusesIt() async throws {
        let (a, b) = try openPair([1, 2, 3, 4, 5, 6], [0, 0, 0, 0])
        let off = try await client.call("copy_to_other_pane", ["offset": 0, "length": 2])
        XCTAssertTrue(off.answer.stringValue?.hasPrefix("Editing is switched off.") == true, "\(off.answer)")
        service.editsAllowed = true
        let past = try await client.call("copy_to_other_pane",
                                         ["document": .string(try id(of: a)), "offset": 2, "length": 4])
        XCTAssertTrue(past.isError)
        XCTAssertTrue(past.answer.stringValue?.contains("past the end of") == true, "\(past.answer)")
        XCTAssertEqual(try bytes(b, 0..<4), [0, 0, 0, 0], "a copy never grows the file")
    }

    func testACopyNeedsASecondFileThatCanBeWritten() async throws {
        try open([1, 2, 3])
        service.editsAllowed = true
        let alone = try await client.call("copy_to_other_pane", ["offset": 0, "length": 1])
        XCTAssertTrue(alone.answer.stringValue?.contains("alone in its tab") == true, "\(alone.answer)")

        let (a, b) = try openPair([1, 2, 3], [0, 0, 0], bReadOnly: true)
        let readOnly = try await client.call("copy_to_other_pane",
                                             ["document": .string(try id(of: a)), "offset": 0, "length": 1])
        XCTAssertTrue(readOnly.answer.stringValue?.contains("read-only") == true, "\(readOnly.answer)")
        XCTAssertEqual(try bytes(b, 0..<3), [0, 0, 0])
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

    /// Every checksum checked at once, and every wrong one put right at once.
    func testEveryWrongChecksumIsListedAndFixedAtOnce() async throws {
        let good = UEFITestImage.make()
        var corrupt = good
        corrupt[0x32] ^= 0xFF          // the volume's header checksum
        corrupt[0x48 + 0x10] ^= 0x01   // the driver's header checksum
        let pane = try open(corrupt)

        let checked = try await client.answer("uefi_checksums")
        XCTAssertEqual(checked["checked"], 2, "\(checked)")
        XCTAssertEqual(checked["wrong"], 2)
        XCTAssertEqual(checked["fixable"], 2)
        let nodes = try XCTUnwrap(checked["nodes"]?.arrayValue)
        let volume = try XCTUnwrap(nodes.first?["checksums"]?.arrayValue?.first)
        XCTAssertEqual(volume["field"], "volume")
        XCTAssertEqual(volume["at"], "0x32")
        XCTAssertEqual(volume["should_be"], .string(String(format: "%02X %02X", good[0x32], good[0x33])))
        XCTAssertEqual(nodes.last?["checksums"]?.arrayValue?.first?["field"], "fileHeader")

        service.editsAllowed = true
        let fixed = try await client.answer("uefi_fix_checksum", ["all": true])
        XCTAssertEqual(fixed["fixed"]?.arrayValue?.count, 2, "\(fixed)")
        XCTAssertEqual(fixed["skipped_compressed"], 0)
        // Only the checksums move: the volume's back to what it was, the
        // driver's to what its header sums to (the fixture leaves it 0).
        let after = try bytes(pane, 0..<UInt64(good.count))
        XCTAssertEqual(after.indices.filter { after[$0] != corrupt[$0] }, [0x32, 0x33, 0x58].filter { after[$0] != corrupt[$0] })
        XCTAssertEqual(Array(after[0x32..<0x34]), Array(good[0x32..<0x34]))
        XCTAssertEqual(pane.undoLabel, "Agent: Fix Checksum", "one undo step for all of them")

        let clean = try await client.answer("uefi_checksums")
        XCTAssertEqual(clean["wrong"], 0)
        let nothing = try await client.call("uefi_fix_checksum", ["all": true])
        XCTAssertEqual(nothing.answer, "Every checksum checks out; nothing to write.")
        let neither = try await client.call("uefi_fix_checksum")
        XCTAssertTrue(neither.isError)
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
