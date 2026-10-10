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
