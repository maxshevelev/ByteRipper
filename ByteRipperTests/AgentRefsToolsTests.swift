import AgentKit
import UEFIImage
import XCTest
@testable import ByteRipper

/// Who refers to an address or a GUID (`refs`, issue #34): the forms an
/// address is searched as, hits inside longer hits left out, a GUID found in
/// what a compressed section decompresses to, hits grouped by file.
@MainActor
final class AgentRefsToolsTests: XCTestCase {
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
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("agent-refs-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        service.stop()
        controller?.windowModel.pane1.close()
        window?.orderOut(nil)
        window = nil
        controller = nil
        try? FileManager.default.removeItem(at: folder)
        discardIsolatedDefaults(defaultsName, defaults)
        super.tearDown()
    }

    private func open(_ bytes: [UInt8]) throws {
        let controller = MainViewController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 900, height: 600))
        self.controller = controller
        self.window = window
        let url = folder.appendingPathComponent("refs.bin")
        try Data(bytes).write(to: url)
        try controller.windowModel.pane1.open(url: url)
        controller.apply(mode: .singleFile)
    }

    private static let guid = EFIGUID("8964FEDC-6FE7-4E1E-A55E-FF821D71FFCF")!

    // MARK: - The forms

    /// The BIOS region's end sits at 4 GiB: in a 16 MiB chip with the region
    /// at the top, 0x668000 is 0xFF668000 on the bus.
    func testAnAddressIsSearchedOnTheBusInTheFileAndInTheRegion() {
        let made = AgentRefsTools.forms(address: 0x668000, relativeToRegion: false, bios: 0x600000..<0x1000000,
                                        names: ["bus", "file", "region"])
        XCTAssertEqual(made.forms.map(\.name), ["bus", "bus", "file", "region"])
        XCTAssertEqual(made.forms[0].bytes, [0x00, 0x80, 0x66, 0xFF, 0, 0, 0, 0])
        XCTAssertEqual(made.forms[1].bytes, [0x00, 0x80, 0x66, 0xFF])
        XCTAssertEqual(made.forms[2].bytes, [0x00, 0x80, 0x66, 0x00])
        XCTAssertEqual(made.forms[3].bytes, [0x00, 0x80, 0x06, 0x00])

        let region = AgentRefsTools.forms(address: 0x68000, relativeToRegion: true, bios: 0x600000..<0x1000000,
                                          names: ["file"])
        XCTAssertEqual(region.forms.map(\.bytes), [[0x00, 0x80, 0x66, 0x00]], "counted from the region")

        // A BIOS-only image: the file and the region are one, searched once.
        let alone = AgentRefsTools.forms(address: 0x8000, relativeToRegion: false, bios: 0..<0x800000,
                                         names: ["file", "region"])
        XCTAssertEqual(alone.forms.map(\.name), ["file"])

        let tiny = AgentRefsTools.forms(address: 0x600010, relativeToRegion: false, bios: 0x600000..<0x1000000,
                                        names: ["region"])
        XCTAssertEqual(tiny.forms, [])
        XCTAssertEqual(tiny.skipped, ["region"], "0x10 would match nearly everywhere")
    }

    /// The 32-bit bus form inside a 64-bit one is the same reference, once.
    func testAHitInsideALongerFormsHitIsLeftOut() {
        let forms = [AgentRefsTools.Form(name: "bus", bytes: [1, 2, 3, 4, 0, 0, 0, 0]),
                     AgentRefsTools.Form(name: "bus", bytes: [1, 2, 3, 4])]
        let hits = [AgentRefsTools.Hit(range: 0x10..<0x14, form: 1), AgentRefsTools.Hit(range: 0x10..<0x18, form: 0),
                    AgentRefsTools.Hit(range: 0x40..<0x44, form: 1)]
        XCTAssertEqual(AgentRefsTools.withoutInner(hits, forms: forms).map(\.range), [0x10..<0x18, 0x40..<0x44])
    }

    // MARK: - refs

    /// A GUID inside a compressed section and one in the file as stored:
    /// each in its own group, the compressed one with its section and the
    /// offset in it, the other with its file address.
    func testAGUIDIsFoundInTheFileAndInWhatASectionDecompressesTo() async throws {
        var image = try CompressedTestImage.make(payload: [0xAA, 0xBB] + Self.guid.bytes)
        image += [UInt8](repeating: 0xFF, count: 0x100)
        image.replaceSubrange(0x1040..<0x1050, with: Self.guid.bytes)
        try open(image)

        let answer = try await client.answer("refs", ["guid": .string(Self.guid.description)])
        XCTAssertEqual(answer["total"], 2, "\(answer)")
        XCTAssertEqual(answer["files"], 2)
        let groups = try XCTUnwrap(answer["refs"]?.arrayValue)
        let raw = try XCTUnwrap(groups.first { $0["in_compressed"] == false && $0["node"] != nil })
        XCTAssertEqual(raw["hits"]?.arrayValue?.first?["file_start"], "0x1040")
        let file = try XCTUnwrap(groups.first { $0["file"] != nil }, "\(groups)")
        let hit = try XCTUnwrap(file["hits"]?.arrayValue?.first)
        XCTAssertEqual(hit["form"], "guid")
        XCTAssertEqual(hit["in_compressed"], true)
        XCTAssertNil(hit["file_start"], "no file address inside a compressed section")
        XCTAssertNotNil(hit["section"])

        let raws = try await client.answer("refs", ["guid": .string(Self.guid.description), "scope": "raw"])
        XCTAssertEqual(raws["total"], 1)
        let none = try await client.answer("refs", ["guid": "13C8B020-4F27-453B-8F80-1BFCA187380F"])
        XCTAssertEqual(none["total"], 0)
        XCTAssertEqual(none["refs"], .array([]))
    }

    /// Several forms of one address at once, one of them across the
    /// boundary between two reads of the search.
    func testSeveralFormsAreFoundAcrossAReadBoundary() async throws {
        var image = try CompressedTestImage.make(holding: "x")
        image += [UInt8](repeating: 0xFF, count: 0x20_0000 - image.count)
        let address: UInt64 = 0x1F_0000
        // A BIOS-only image: the region is the file, its end at 4 GiB.
        let bus = UInt32(0x1_0000_0000 - (UInt64(image.count) - address))
        let busBytes = (0..<4).map { UInt8(truncatingIfNeeded: bus >> (8 * UInt32($0))) }
        let fileBytes = (0..<4).map { UInt8(truncatingIfNeeded: address >> (8 * UInt64($0))) }
        image.replaceSubrange(0x10_0000 - 2..<0x10_0000 + 2, with: busBytes)   // across 1 MiB
        image.replaceSubrange(0x18_0000..<0x18_0004, with: fileBytes)
        try open(image)

        let answer = try await client.answer("refs", ["address": .string(String(format: "0x%llX", address))])
        let hits = (answer["refs"]?.arrayValue ?? []).flatMap { $0["hits"]?.arrayValue ?? [] }
        XCTAssertEqual(Set(hits.compactMap { $0["form"]?.stringValue }), ["bus", "file"], "\(answer)")
        XCTAssertTrue(hits.contains { $0["file_start"] == "0xFFFFE" }, "the bus form across the boundary")
        XCTAssertTrue(hits.contains { $0["file_start"] == "0x180000" })
    }

    /// Hundreds of chance hits in one area: counted exactly, the first few
    /// listed and the rest only counted. (A page cut by size, over hundreds
    /// of files, is tried on a real dump.)
    func testManyHitsInOneAreaAreCountedExactly() async throws {
        var image = try CompressedTestImage.make(holding: "x")
        image += [UInt8](repeating: 0xFF, count: 0x10_0000 - image.count)
        for index in 0..<600 {
            image.replaceSubrange((0x2000 + index * 0x400)..<(0x2000 + index * 0x400 + 4), with: [0x00, 0x80, 0x0A, 0x00])
        }
        try open(image)
        let answer = try await client.answer("refs", ["address": "0xA8000", "forms": ["file"]])
        XCTAssertEqual(answer["total"], 600)
        XCTAssertEqual(answer["files"], 1)
        let group = try XCTUnwrap(answer["refs"]?.arrayValue?.first)
        XCTAssertEqual(group["hits"]?.arrayValue?.count, AgentRefsTools.maxHitsPerFile)
        XCTAssertEqual(group["hits_total"], 600)
        XCTAssertEqual(answer["next"], .null)
    }
}
