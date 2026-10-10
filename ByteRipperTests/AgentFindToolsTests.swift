import AgentKit
import FirmwareCompression
import UEFIImage
import XCTest
@testable import ByteRipper

/// Searching a document's bytes — a node's too, inside a compressed section —
/// reading a node's bytes, and opening a stretch of a document as a part
/// (`Design/AGENT_PLAN.md`, search and extract).
@MainActor
final class AgentFindToolsTests: XCTestCase {
    private var controller: MainViewController?
    private var copies: MainViewController?
    private var windows: [NSWindow] = []
    private var service: AgentService!
    private var client: AgentTestClient!
    private var defaultsName = ""
    private var defaults: UserDefaults!
    private var folder: URL!

    override func setUp() {
        super.setUp()
        (defaultsName, defaults) = isolatedDefaults(for: self)
        let desk = AgentDesk(controllers: { [weak self] in [self?.controller, self?.copies].compactMap { $0 } },
                             keyController: { [weak self] in self?.controller })
        service = AgentService(desk: desk, defaults: defaults,
                               socketPath: "/tmp/br-\(UUID().uuidString.prefix(8)).sock")
        service.diffTools.tabForCopies = { [weak self] _ in self?.window().0 }
        client = AgentTestClient(service)
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("agent-find-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        service.stop()
        for controller in [controller, copies].compactMap({ $0 }) {
            controller.windowModel.pane1.close()
            controller.windowModel.pane2.close()
        }
        windows.forEach { $0.orderOut(nil) }
        windows = []
        controller = nil
        copies = nil
        try? FileManager.default.removeItem(at: folder)
        discardIsolatedDefaults(defaultsName, defaults)
        super.tearDown()
    }

    /// A window with a tab of its own; the first is the test's, a second the
    /// one `compare` puts copies in.
    @discardableResult
    private func window() -> (MainViewController, NSWindow) {
        let controller = MainViewController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 900, height: 600))
        window.makeKeyAndOrderFront(nil)
        windows.append(window)
        if self.controller == nil { self.controller = controller } else { copies = controller }
        return (controller, window)
    }

    @discardableResult
    private func open(_ bytes: [UInt8]) throws -> MainViewController {
        let (controller, _) = window()
        let url = folder.appendingPathComponent("front.bin")
        try Data(bytes).write(to: url)
        try controller.windowModel.pane1.open(url: url)
        controller.apply(mode: .singleFile)
        return controller
    }

    private func starts(_ answer: JSONValue) -> [String] {
        (answer["matches"]?.arrayValue ?? []).compactMap { $0["start"]?.stringValue }
    }

    // MARK: - find_bytes

    func testTextIsFoundAsASCIIAndAsUTF16AndBytesWithHoles() async throws {
        var bytes = [UInt8](repeating: 0, count: 0x400)
        bytes.replaceSubrange(0x10..<0x14, with: Array("Acer".utf8))
        bytes.replaceSubrange(0x41..<0x49, with: [0x41, 0, 0x43, 0, 0x45, 0, 0x52, 0])   // "ACER" at an odd address
        bytes.replaceSubrange(0x200..<0x204, with: [0x24, 0x44, 0x4D, 0x49])
        try open(bytes)

        let both = try await client.answer("find_bytes", ["text": "acer", "ignore_case": true, "context": 4])
        XCTAssertEqual(both["total"], 2)
        XCTAssertEqual(starts(both), ["0x10", "0x41"])
        XCTAssertEqual(both["matches"]?.arrayValue?.map { $0["encoding"] }, ["ascii", "utf16le"])
        XCTAssertEqual(both["matches"]?.arrayValue?.first?["preview"]?["hex"], "00 00 00 00 41 63 65 72 00 00 00 00")
        XCTAssertEqual(both["matches"]?.arrayValue?.first?["preview"]?["before"], 4)
        XCTAssertEqual(both["next"], .null)

        let exact = try await client.answer("find_bytes", ["text": "acer"])
        XCTAssertEqual(exact["total"], 0, "case matters unless asked")
        let utf16 = try await client.answer("find_bytes", ["text": "ACER", "encoding": "utf16le"])
        XCTAssertEqual(starts(utf16), ["0x41"])
        let holes = try await client.answer("find_bytes", ["hex": "24 ?? 4D 49"])
        XCTAssertEqual(starts(holes), ["0x200"])
        let ranged = try await client.answer("find_bytes", ["text": "Acer", "encoding": "ascii", "offset": "0x11"])
        XCTAssertEqual(ranged["total"], 0)
    }

    /// A pattern that occurs everywhere: an exact total, and pages under the
    /// bound that add up to it — overlapping matches only when asked.
    func testManyMatchesComeInPagesWithAnExactTotal() async throws {
        try open([UInt8](repeating: 0xFF, count: 0x2000))
        let plain = try await client.answer("find_bytes", ["hex": "FF FF", "limit": 1000])
        XCTAssertEqual(plain["total"], 0x1000)
        XCTAssertEqual(plain["truncated"], "size")
        XCTAssertLessThanOrEqual(plain.encoded().count, 24 << 10)
        let overlapping = try await client.answer("find_bytes", ["hex": "FF FF", "overlapping": true, "limit": 1])
        XCTAssertEqual(overlapping["total"], 0x1FFF)

        var seen = 0
        var after: JSONValue?
        repeat {
            var arguments: [String: JSONValue] = ["hex": "FF FF", "limit": 1000]
            if let after { arguments["after"] = after }
            let page = try await client.answer("find_bytes", .object(arguments))
            seen += page["matches"]?.arrayValue?.count ?? 0
            after = page["next"] == .null ? nil : page["next"]
        } while after != nil
        XCTAssertEqual(seen, 0x1000)
    }

    func testAPatternThatCannotBeSearchedIsRefused() async throws {
        try open([1, 2, 3, 4])
        let neither = try await client.call("find_bytes")
        XCTAssertEqual(neither.answer, "Give `text` or `hex`, one of them.")
        let odd = try await client.call("find_bytes", ["hex": "ABC"])
        XCTAssertTrue(odd.answer.stringValue?.hasPrefix("`hex` is not a byte pattern.") == true)
        let holes = try await client.call("find_bytes", ["hex": "?? ??"])
        XCTAssertTrue(holes.isError)
        let long = try await client.call("find_bytes", ["text": "longer than the file"])
        XCTAssertEqual(long.answer, "The pattern is longer than the range searched.")
        let past = try await client.call("find_bytes", ["hex": "01", "end": "0x10"])
        XCTAssertTrue(past.answer.stringValue?.hasPrefix("The range 0x0–0x10 is not inside d1") == true, "\(past.answer)")
    }

    // MARK: - Inside a compressed section

    /// Text only the decompressed bytes hold: not found in the file, found in
    /// the section — and in the node inside it — at offsets inside, and read
    /// there by `uefi_node_data`.
    func testACompressedSectionIsSearchedInWhatItDecompressesTo() async throws {
        try open(try CompressedTestImage.make(holding: "SECRET-MODEL-GH51G"))
        let inFile = try await client.answer("find_bytes", ["text": "GH51G"])
        XCTAssertEqual(inFile["total"], 0, "the file holds it compressed")

        let tree = try await client.answer("uefi_find", ["type": "Section", "limit": 50])
        let section = try XCTUnwrap(tree["matches"]?.arrayValue?.first { $0["subtype"] == "Compressed section" }?["id"]?.stringValue,
                                    "\(tree)")
        let found = try await client.answer("find_bytes", ["node": .string(section), "text": "GH51G"])
        XCTAssertEqual(found["decompressed"], true)
        XCTAssertEqual(found["total"], 1)
        let match = try XCTUnwrap(found["matches"]?.arrayValue?.first)
        XCTAssertNil(match["start"], "no file address")
        let at = try XCTUnwrap(match["node_start"]?.stringValue)
        XCTAssertEqual(match["where"]?.arrayValue?.first?["name"], "Raw")
        XCTAssertNotNil(found["source"]?["start"])

        let read = try await client.answer("uefi_node_data", ["node": .string(section), "part": "decompressed",
                                                             "offset": .string(at), "length": 5, "format": "ascii"])
        XCTAssertEqual(read["text"], "GH51G")
        XCTAssertEqual(read["in_compressed"], true)
    }

    /// A node of the file reads as `read` reads the same bytes.
    func testANodeOfTheFileReadsAsReadDoes() async throws {
        try open(UEFITestImage.make())
        let node = try await client.answer("uefi_node_data", ["node": "0", "part": "all", "length": 32])
        XCTAssertEqual(node["file_start"], "0x0")
        XCTAssertEqual(node["in_compressed"], false)
        let read = try await client.answer("read", ["offset": 0, "length": 32])
        XCTAssertEqual(node["rows"], read["rows"])
        let header = try await client.call("uefi_node_data", ["node": "0", "part": "decompressed"])
        XCTAssertTrue(header.answer.stringValue?.contains("is not a compressed section") == true, "\(header.answer)")
    }

    // MARK: - open_part

    /// Two stretches at different addresses opened as parts compare from zero.
    func testTwoStretchesOpenedAsPartsCompareFromZero() async throws {
        var bytes = [UInt8](repeating: 0, count: 0x1000)
        for index in 0..<0x40 {
            bytes[0x100 + index] = UInt8(index)
            bytes[0x800 + index] = UInt8(index)
        }
        bytes[0x800 + 0x10] = 0xEE
        bytes[0x800 + 0x11] = 0xEE
        try open(bytes)
        let first = try await client.answer("open_part", ["offset": "0x100", "length": "0x40", "name": "One"])
        // The part has the focus now; the parent is named.
        let second = try await client.answer("open_part", ["document": "d1", "offset": "0x800", "length": "0x40"])
        XCTAssertEqual(first["parent"], "d1")
        XCTAssertEqual(first["name"], "One")
        XCTAssertEqual(first["source"]?["start"], "0x100")
        let one = try XCTUnwrap(first["document"]?.stringValue)
        let two = try XCTUnwrap(second["document"]?.stringValue)

        let documents = try await client.answer("documents")
        XCTAssertEqual(documents["documents"]?.arrayValue?.first { $0["id"]?.stringValue == one }?["slot"], "part")
        let read = try await client.answer("read", ["document": .string(one), "offset": 0, "length": 4, "format": "u8"])
        XCTAssertEqual(read["values"], ["0x00", "0x01", "0x02", "0x03"])

        let diff = try await client.answer("diff", ["document": .string(one), "against": .string(two), "structure": "none"])
        XCTAssertEqual(diff["totals"]?["differing_bytes"], 2)
        XCTAssertEqual(diff["runs"]?.arrayValue?.first?["start"], "0x10")

        let pair = try await client.answer("compare", ["document": .string(one), "against": .string(two)])
        XCTAssertNotNil(pair["copies"], "a part has no file to open beside another: copies")
        let walked = try await client.answer("reveal_diff", ["document": pair["a"] ?? .null])
        XCTAssertEqual(walked["start"], "0x10")
    }

    /// Asking again for a part that is open raises its panel, and answers with
    /// it: no copy beside it. Another way of opening the same bytes is another
    /// part.
    func testAskingAgainForAnOpenPartReusesItsPanel() async throws {
        let controller = try open(LenovoTestImage.make())
        let at = try await client.answer("uefi_at", ["offset": .string(String(format: "0x%X", LenovoTestImage.serialInBlock2))])
        let entry = try XCTUnwrap(at["chain"]?.arrayValue?.last?["id"]?.stringValue, "\(at)")
        let first = try await client.answer("open_part", ["node": .string(entry), "part": "decoded"])
        XCTAssertNil(first["reused"])
        let again = try await client.answer("open_part", ["document": "d1", "node": .string(entry), "part": "decoded"])
        XCTAssertEqual(again["reused"], true)
        XCTAssertEqual(again["document"], first["document"])
        XCTAssertEqual(controller.fragments.panelsLinked(to: controller.windowModel.pane1).count, 1, "one panel, not two")

        let raw = try await client.answer("open_part", ["document": "d1", "node": .string(entry)])
        XCTAssertNil(raw["reused"], "the encoded bytes are another part")
        XCTAssertNotEqual(raw["document"], first["document"])
        XCTAssertEqual(controller.fragments.panelsLinked(to: controller.windowModel.pane1).count, 2)

        let stretch = try await client.answer("open_part", ["document": "d1", "offset": "0x800", "length": "0x100"])
        let sameStretch = try await client.answer("open_part", ["document": "d1", "offset": "0x800", "length": "0x100"])
        XCTAssertEqual(sameStretch["reused"], true)
        XCTAssertEqual(sameStretch["document"], stretch["document"])
        XCTAssertEqual(controller.fragments.panelsLinked(to: controller.windowModel.pane1).count, 3)
    }

    /// A node of a LENV block stored encoded says so; with the block open
    /// decoded, the parent's node names the part's and the part's names the
    /// parent's. A call that names the parent while the focus is on the part
    /// says that too.
    func testANodeNamesItsDecodedCounterpartAndTheOtherWayRound() async throws {
        try open(LenovoTestImage.make())
        let offset = String(format: "0x%X", LenovoTestImage.serialInBlock2)
        let before = try await client.answer("uefi_at", ["offset": .string(offset)])
        let entry = try XCTUnwrap(before["chain"]?.arrayValue?.last)
        XCTAssertEqual(entry["encoded"], "XOR 77", "\(entry)")
        XCTAssertNil(entry["counterpart"], "nothing is open yet")

        let opened = try await client.answer("open_part", ["node": entry["id"] ?? .null, "part": "decoded"])
        let part = try XCTUnwrap(opened["document"]?.stringValue)
        XCTAssertEqual(opened["tool_panel"], .null)
        XCTAssertTrue(opened["next"]?.stringValue?.contains("open_panel") == true, "\(opened)")

        // The focus is on the part now; the call names the parent.
        let after = try await client.answer("uefi_at", ["document": "d1", "offset": .string(offset)])
        let linked = try XCTUnwrap(after["chain"]?.arrayValue?.last)
        XCTAssertEqual(linked["decoded_in"]?["document"]?.stringValue, part, "\(linked)")
        let partNode = try XCTUnwrap(linked["decoded_in"]?["node"]?.stringValue)
        XCTAssertNotEqual(partNode, entry["id"]?.stringValue, "the part numbers its nodes from its own top")
        XCTAssertEqual(linked["counterpart"]?.arrayValue?.first?["as"], "decoded")
        XCTAssertTrue(after["focus_note"]?.stringValue?.contains("a part of d1") == true, "\(after)")

        let inPart = String(format: "0x%X", LenovoTestImage.serialInBlock2 - 0x4000)
        let back = try await client.answer("uefi_at", ["document": .string(part), "offset": .string(inPart)])
        let own = try XCTUnwrap(back["chain"]?.arrayValue?.last)
        XCTAssertEqual(own["id"]?.stringValue, partNode)
        XCTAssertNil(own["encoded"], "the part holds it in the clear")
        XCTAssertEqual(own["counterpart"]?.arrayValue?.first?["document"], "d1")
        XCTAssertEqual(own["counterpart"]?.arrayValue?.first?["node"], entry["id"])
        XCTAssertEqual(own["counterpart"]?.arrayValue?.first?["as"], "encoded")
        XCTAssertNil(back["focus_note"], "the call went where the focus is")

        // The part's top wraps the block, the same bytes: only the block —
        // the innermost — is linked, so one node of the parent has one here.
        let chain = try XCTUnwrap(back["chain"]?.arrayValue)
        let blockRange = (start: "0x0", end: "0x1000")
        let wrappers = chain.filter { $0["start"]?.stringValue == blockRange.start && $0["end"]?.stringValue == blockRange.end }
        XCTAssertGreaterThanOrEqual(wrappers.count, 2, "the top and the block: \(chain)")
        XCTAssertEqual(wrappers.filter { $0["counterpart"] != nil }.count, 1, "\(wrappers)")

        let refused = try await client.call("uefi_tree", ["document": "d1", "node": "9.9.9"])
        XCTAssertTrue(refused.isError)
        XCTAssertTrue(refused.answer.stringValue?.contains("The focus is on \(part)") == true, "\(refused.answer)")
        // The part's id asked of the parent: the refusal says whose it is.
        let carried = try await client.call("uefi_tree", ["document": "d1", "node": .string(partNode)])
        XCTAssertTrue(carried.isError)
        XCTAssertTrue(carried.answer.stringValue?.contains("\(partNode) is a node of \(part)") == true, "\(carried.answer)")

        // A panel's answer says which document's panel chose the node.
        _ = try await client.answer("open_panel", ["module": "uefi-structure", "document": .string(part)])
        let selected = try await client.answer("uefi_select", ["document": .string(part), "node": .string(partNode)])
        XCTAssertEqual(selected["document"]?.stringValue, part, "\(selected)")
    }

    /// A compressed section and every node it decompresses to say how the
    /// file holds them, and the latter which section to open.
    func testACompressedSectionAndWhatItHoldsSayTheyAreCompressed() async throws {
        try open(try CompressedTestImage.make(holding: "SECRET-MODEL-GH51G"))
        let sections = try await client.answer("uefi_find", ["type": "Section", "limit": 50])
        let matches = try XCTUnwrap(sections["matches"]?.arrayValue)
        let section = try XCTUnwrap(matches.first { $0["subtype"] == "Compressed section" })
        let algorithm = try XCTUnwrap(section["compressed"]?.stringValue, "\(section)")
        XCTAssertNil(section["compressed_in"])
        let tree = try await client.answer("uefi_tree", ["node": section["id"] ?? .null])
        let child = try XCTUnwrap(tree["children"]?.arrayValue?.first, "\(tree)")
        XCTAssertEqual(child["compressed"]?.stringValue, algorithm)
        XCTAssertEqual(child["compressed_in"], section["id"])
        let at = try await client.answer("uefi_at", ["offset": section["start"] ?? .null])
        let outside = try XCTUnwrap(at["chain"]?.arrayValue?.dropLast())
        XCTAssertFalse(outside.isEmpty)
        XCTAssertTrue(outside.allSatisfy { $0["compressed"] == nil }, "what holds the section is the file's: \(outside)")
    }

    /// What a compressed section decompresses to opens as a part, in a panel
    /// over the same window — not a tab — and goes back compressed.
    func testACompressedSectionOpensDecompressedInAPanel() async throws {
        let controller = try open(try CompressedTestImage.make(holding: "SECRET-MODEL-GH51G"))
        let tree = try await client.answer("uefi_find", ["type": "Section", "limit": 50])
        let section = try XCTUnwrap(tree["matches"]?.arrayValue?.first { $0["subtype"] == "Compressed section" }?["id"]?.stringValue)
        let opened = try await client.answer("open_part", ["node": .string(section), "part": "decompressed"])
        XCTAssertEqual(opened["in_compressed"], true)
        XCTAssertEqual(opened["parent"], "d1")
        XCTAssertEqual(controller.fragments.panelsLinked(to: controller.windowModel.pane1).count, 1,
                       "a panel of the same window")
        let part = try XCTUnwrap(opened["document"]?.stringValue)
        let found = try await client.answer("find_bytes", ["document": .string(part), "text": "GH51G"])
        XCTAssertEqual(found["total"], 1, "the part holds the decompressed bytes")

        let plain = try await client.call("open_part", ["node": .string(section), "part": "decoded"])
        XCTAssertTrue(plain.isError, "a compressed section is not a LENV block")
    }

    /// A LENV block, or an entry in one, opens with its XOR encoding removed.
    func testALENVBlockOpensDecodedInAPanel() async throws {
        let controller = try open(LenovoTestImage.make())
        let at = try await client.answer("uefi_at", ["offset": .string(String(format: "0x%X", LenovoTestImage.serialInBlock2))])
        let entry = try XCTUnwrap(at["chain"]?.arrayValue?.last?["id"]?.stringValue, "\(at)")
        let opened = try await client.answer("open_part", ["node": .string(entry), "part": "decoded"])
        XCTAssertEqual(opened["size"], "0x1000", "the whole block")
        XCTAssertEqual(controller.fragments.panelsLinked(to: controller.windowModel.pane1).count, 1)
        let part = try XCTUnwrap(opened["document"]?.stringValue)
        let read = try await client.answer("read", ["document": .string(part), "offset": "0x28", "length": 8, "format": "ascii"])
        XCTAssertEqual(read["text"], "PF0TEST1", "decoded")
        XCTAssertEqual(opened["part"], "decoded")
        XCTAssertNil(opened["hint"])
    }

    /// A LENV block opened as it is says it is encoded and how to open it
    /// decoded; an argument `open_part` does not take is refused, not dropped.
    func testALENVBlockOpenedAsItIsSaysHowToDecodeIt() async throws {
        try open(LenovoTestImage.make())
        let at = try await client.answer("uefi_at", ["offset": .string(String(format: "0x%X", LenovoTestImage.serialInBlock2))])
        let entry = try XCTUnwrap(at["chain"]?.arrayValue?.last?["id"]?.stringValue, "\(at)")
        let raw = try await client.answer("open_part", ["node": .string(entry)])
        XCTAssertEqual(raw["part"], "all")
        XCTAssertTrue(raw["hint"]?.stringValue?.contains("part: \"decoded\"") == true, "\(raw)")

        let refused = try await client.call("open_part", ["node": .string(entry), "decoded": true])
        XCTAssertTrue(refused.isError)
        let message = refused.answer.stringValue ?? ""
        XCTAssertTrue(message.contains("Perhaps `part: \"decoded\"`"), message)
    }

    /// A decompressed part is a file of its own to every tool: read, searched,
    /// its own UEFI tree, its own tool panel — the parent's is untouched —
    /// and `documents` says what its bytes are.
    func testADecompressedPartIsAFileToEveryTool() async throws {
        let controller = try open(try CompressedTestImage.make(holding: "SECRET-MODEL-GH51G"))
        let tree = try await client.answer("uefi_find", ["type": "Section", "limit": 50])
        let section = try XCTUnwrap(tree["matches"]?.arrayValue?.first { $0["subtype"] == "Compressed section" })
        let opened = try await client.answer("open_part", ["node": section["id"] ?? .null, "part": "decompressed"])
        let part = try XCTUnwrap(opened["document"])

        let documents = try await client.answer("documents")
        let entry = try XCTUnwrap(documents["documents"]?.arrayValue?.first { $0["id"] == part })
        XCTAssertEqual(entry["decoded"], "LZMA")
        XCTAssertEqual(entry["keeps_offsets"], false)

        let found = try await client.answer("find_bytes", ["document": part, "text": "GH51G"])
        XCTAssertEqual(found["total"], 1)
        let raw = try await client.answer("uefi_tree", ["document": part])
        XCTAssertEqual(raw["children"]?.arrayValue?.first?["name"], "Raw", "the part's own tree")

        let panel = try await client.answer("open_panel", ["document": part, "module": "uefi-structure"])
        XCTAssertEqual(panel["document"], part)
        let pane = try XCTUnwrap(controller.fragments.pane(try XCTUnwrap(controller.fragments.expanded)))
        XCTAssertEqual(controller.tools(reading: pane).activeIdentifier, "dev.maxik.tool.uefi-structure",
                       "the part's own tool panel")
        XCTAssertFalse(controller.tools(reading: controller.windowModel.pane1) === controller.tools(reading: pane))
        let selected = try await client.answer("uefi_select", ["document": part, "node": "0"])
        XCTAssertEqual(selected["selected"]?["name"], "Raw")

        // A finding in bytes the file holds only compressed leads to the
        // section they came out of.
        let finding = try await client.answer("finding", ["document": part, "offset": "0x4", "length": 4, "text": "t"])
        XCTAssertEqual(finding["from_part"]?["exact"], false)
        XCTAssertEqual(finding["range"]?["start"], opened["source"]?["start"])
        XCTAssertEqual(finding["range"]?["end"], opened["source"]?["end"])
    }

    /// A finding in a part that keeps the file's addresses lands on the same
    /// bytes of the file.
    func testAFindingInAPartLeadsToTheSameBytesOfTheFile() async throws {
        try open([UInt8](repeating: 0, count: 0x1000))
        let opened = try await client.answer("open_part", ["offset": "0x800", "length": "0x100"])
        let finding = try await client.answer("finding", ["document": opened["document"] ?? .null,
                                                          "offset": "0x10", "length": 4, "text": "t"])
        XCTAssertEqual(finding["range"]?["start"], "0x810")
        XCTAssertEqual(finding["range"]?["end"], "0x814")
        XCTAssertEqual(finding["from_part"]?["exact"], true)
        XCTAssertTrue(finding["path"]?.stringValue?.hasSuffix("front.bin") == true)
    }

    func testAPartNeedsItsParentOnScreenAndAPlace() async throws {
        try open([UInt8](repeating: 0, count: 0x100))
        let url = folder.appendingPathComponent("other.bin")
        try Data(repeating: 1, count: 0x100).write(to: url)
        let opened = try await client.answer("open_dump", ["path": .string(url.path)])
        let background = try XCTUnwrap(opened["document"]?.stringValue)
        let refused = try await client.call("open_part", ["document": .string(background), "offset": 0, "length": 4])
        XCTAssertTrue(refused.answer.stringValue?.contains("Call `show`") == true, "\(refused.answer)")
        let past = try await client.call("open_part", ["document": "d1", "offset": "0xF0", "length": "0x20"])
        XCTAssertTrue(past.isError)
        let neither = try await client.call("open_part")
        XCTAssertEqual(neither.answer, "Give `offset` and `length`, or `node`.")
    }
}

/// A volume holding one file whose only section is LZMA-compressed, and in it
/// a raw section with `text`: bytes the file holds only compressed.
enum CompressedTestImage {
    static func make(holding text: String) throws -> [UInt8] {
        try make(payload: Array(text.utf8))
    }

    /// The same image with `bytes` in the raw section the compressed one
    /// decompresses to.
    static func make(payload bytes: [UInt8]) throws -> [UInt8] {
        func u24(_ value: Int) -> [UInt8] { [UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value >> 16 & 0xFF)] }
        func u32(_ value: Int) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) } }
        let payload = bytes + [UInt8](repeating: 0, count: 12)
        let raw = u24(4 + payload.count) + [0x19] + payload
        let stream = try FirmwareCompression.compress(raw, as: .lzma)
        var section = u24(4 + 5 + stream.count) + [0x01] + u32(raw.count) + [0x02] + stream
        while section.count % 4 != 0 { section.append(0xFF) }
        let fileSize = 0x18 + section.count
        let guid = EFIGUID(low: 0x0000_0000_0000_0003, high: 0x0000_0000_0000_0004)
        let file = guid.bytes + [0, 0xAA, 0x07, 0x00] + u24(fileSize) + [0xF8] + section

        let volumeLength = 0x1000
        var image = [UInt8](repeating: 0xFF, count: volumeLength)
        var header = [UInt8](repeating: 0, count: 0x10) + KnownGUIDs.ffsV2.bytes
        header += (0..<8).map { UInt8(truncatingIfNeeded: volumeLength >> (8 * $0)) }
        header += u32(0x4856_465F) + u32(0x0000_0800) + [0x48, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02]
        header += u32(1) + u32(volumeLength) + u32(0) + u32(0)
        let checksum = Checksums.checksum16(header) ?? 0
        header[0x32] = UInt8(truncatingIfNeeded: checksum)
        header[0x33] = UInt8(truncatingIfNeeded: checksum >> 8)
        image.replaceSubrange(0..<0x48, with: header)
        image.replaceSubrange(0x48..<(0x48 + file.count), with: file)
        return image
    }
}
