import AgentKit
import MEAToolUI
import MEFirmware
import UEFIImage
import XCTest
@testable import ByteRipper

/// The firmware questions an agent asks through the service (`Design/AGENT_PLAN.md`,
/// stage 6): the NVRAM variables of a dump and of two dumps side by side, the
/// FIT table, and the ME firmware's summary and structure — every one with the
/// panels closed.
@MainActor
final class AgentFirmwareToolsTests: XCTestCase {
    private var controller: MainViewController?
    private var window: NSWindow?
    private var service: AgentService!
    private var client: AgentTestClient!
    private var defaultsName = ""
    private var defaults: UserDefaults!
    private var folder: URL!

    /// A firmware database that answers at once, so no test reaches GitHub.
    private struct ReachableSource: MEADataSource {
        func database() async throws -> MEADatabase { MEADatabase(revision: 378) }
    }

    override func setUp() {
        super.setUp()
        (defaultsName, defaults) = isolatedDefaults(for: self)
        let desk = AgentDesk(controllers: { [weak self] in self?.controller.map { [$0] } ?? [] },
                             keyController: { [weak self] in self?.controller })
        service = AgentService(desk: desk, defaults: defaults,
                               socketPath: "/tmp/br-\(UUID().uuidString.prefix(8)).sock")
        client = AgentTestClient(service)
        MEAToolSession.dataSource = ReachableSource()
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("agent-firmware-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        service.stop()
        controller?.windowModel.pane1.close()
        window?.orderOut(nil)
        window = nil
        controller = nil
        MEAToolSession.dataSource = MEAGitHubDataRepository()
        try? FileManager.default.removeItem(at: folder)
        discardIsolatedDefaults(defaultsName, defaults)
        super.tearDown()
    }

    @discardableResult
    private func open(_ bytes: [UInt8]) throws -> MainViewController {
        let controller = MainViewController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 900, height: 600))
        window.makeKeyAndOrderFront(nil)
        self.controller = controller
        self.window = window
        try controller.windowModel.pane1.open(url: write(bytes, "front.bin"))
        controller.apply(mode: .singleFile)
        return controller
    }

    @discardableResult
    private func write(_ bytes: [UInt8], _ name: String) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try Data(bytes).write(to: url)
        return url
    }

    /// `bytes` opened by path, with no window: the second dump of a
    /// comparison.
    private func background(_ bytes: [UInt8], _ name: String) async throws -> String {
        let url = try write(bytes, name)
        let opened = try await client.answer("open_dump", ["path": .string(url.path)])
        return try XCTUnwrap(opened["document"]?.stringValue)
    }

    // MARK: - The list

    func testTheFirmwareToolsAreListed() throws {
        let tools = Dictionary(uniqueKeysWithValues: service.server.tools.map { ($0.name, $0) })
        for name in ["variables", "variables_compare", "fit_table", "me_summary", "me_tree"] {
            let tool = try XCTUnwrap(tools[name], name)
            XCTAssertNotNil(tool.inputSchema["properties"]?["document"], name)
            XCTAssertEqual(tool.annotations.readOnly, true, name)
        }
        XCTAssertEqual(tools["variables_compare"]?.inputSchema["required"], ["against"])
    }

    // MARK: - variables

    /// One row per variable — the copy in force — with the number of copies
    /// the store keeps, and the value read as its type.
    func testVariablesListsTheCopyInForceOfEach() async throws {
        try open(NvramTestImage.vss([
            .init("Setup", [1, 1], state: NvramTestImage.superseded),
            .init("Lang", Array("eng".utf8) + [0]),
            .init("Setup", [2, 2])
        ]))
        let answer = try await client.answer("variables")
        let rows = try XCTUnwrap(answer["variables"]?.arrayValue)
        XCTAssertEqual(rows.map { $0["name"] }, ["Lang", "Setup"], "\(answer)")
        let setup = try XCTUnwrap(rows.last)
        XCTAssertEqual(setup["copies"], 2)
        XCTAssertEqual(setup["value"], "514 (0x202)", "two bytes read as a number, as the panel reads them")
        XCTAssertEqual(setup["size"], 2)
        XCTAssertEqual(rows.first?["value"], "\"eng\"")
        XCTAssertEqual(answer["stores"]?.arrayValue?.first?["variables"], 2)
        XCTAssertNotNil(setup["start"], "a value in the file has its address")

        let lang = try await client.answer("variables", ["name": "LANG"])
        XCTAssertEqual(lang["total"], 1)
    }

    func testAnImageWithNoStoreSaysSo() async throws {
        try open(UEFITestImage.make())
        let answer = try await client.answer("variables")
        XCTAssertEqual(answer["total"], 0)
        XCTAssertEqual(answer["note"], "No VSS, NVAR, DVAR or GPNV store in this image.")
    }

    // MARK: - variables_compare

    /// Two dumps set side by side by name and GUID: one variable changed, one
    /// in each alone, one the same.
    func testTwoDumpsCompareByNameAndGUID() async throws {
        try open(NvramTestImage.vss([
            .init("Setup", [1, 1]), .init("Lang", Array("eng".utf8) + [0]), .init("Timeout", [5, 0])
        ]))
        let other = try await background(NvramTestImage.vss([
            .init("BootOrder", [0, 0]), .init("Lang", Array("eng".utf8) + [0]), .init("Setup", [1, 2, 3])
        ]), "other.rom")

        let answer = try await client.answer("variables_compare", ["against": .string(other)])
        XCTAssertEqual(answer["document"], "d1")
        XCTAssertEqual(answer["against"]?.stringValue, other)
        XCTAssertEqual(answer["same"], 1)
        XCTAssertEqual(answer["only_in_document"]?.arrayValue?.map { $0["name"] }, ["Timeout"])
        XCTAssertEqual(answer["only_in_against"]?.arrayValue?.map { $0["name"] }, ["BootOrder"])
        let changed = try XCTUnwrap(answer["changed"]?.arrayValue?.first, "\(answer)")
        XCTAssertEqual(changed["name"], "Setup")
        XCTAssertEqual(changed["size"], 2)
        XCTAssertEqual(changed["against_size"], 3)
        // Byte 1 differs, and byte 2 only the longer value has: one run.
        XCTAssertEqual(changed["runs"], ["0x1–0x3"])
        XCTAssertEqual(changed["differing_bytes"], 2)
    }

    func testAComparisonNeedsTwoDocuments() async throws {
        try open(NvramTestImage.vss([.init("Setup", [1])]))
        let itself = try await client.call("variables_compare", ["against": "d1"])
        XCTAssertEqual(itself.answer, "`document` and `against` are the same document, d1.")
        let missing = try await client.call("variables_compare")
        XCTAssertTrue(missing.isError)
        let unknown = try await client.call("variables_compare", ["against": "d9"])
        XCTAssertEqual(unknown.answer,
                       "No open document has the id d9. Call `documents` for the ones that are open.")
    }

    /// A folder of dumps compared with one, by `survey`: each grouped by how
    /// many of its variables differ from the reference.
    func testASurveyComparesAFolderWithOneDump() async throws {
        try open(NvramTestImage.vss([.init("Setup", [1, 1]), .init("Lang", [0x65])]))
        try write(NvramTestImage.vss([.init("Setup", [1, 1]), .init("Lang", [0x65])]), "same.rom")
        try write(NvramTestImage.vss([.init("Setup", [9, 1]), .init("Lang", [0x65])]), "changed.rom")
        let survey = try await client.answer("survey", [
            "folder": .string(folder.path), "tool": "variables_compare",
            "arguments": ["against": "d1"], "group_by": "counts.changed"
        ])
        let groups = try XCTUnwrap(survey["groups"]?.arrayValue)
        let byValue = Dictionary(uniqueKeysWithValues: groups.map { ($0["value"]?.jsonText ?? "", $0) })
        XCTAssertEqual(byValue["1"]?["files"], ["changed.rom"], "\(survey)")
        XCTAssertEqual(byValue["0"]?["files"], ["same.rom"], "\(survey)")
        // front.bin is d1 itself, which a comparison refuses.
        XCTAssertEqual(survey["failed"]?.arrayValue?.first?["file"], "front.bin")
    }

    // MARK: - fit_table

    func testTheFITTableIsReadWithItsMicrocode() async throws {
        try open(FITTestImage.make())
        let answer = try await client.answer("fit_table", ["entry": 1])
        let rows = try XCTUnwrap(answer["rows"]?.arrayValue, "\(answer)")
        let microcode = try XCTUnwrap(rows.first { $0["cpuids"] != nil }, "\(rows)")
        XCTAssertEqual(microcode["cpuids"], ["806EA"])
        XCTAssertEqual(microcode["type"], "Microcode")
        XCTAssertNotNil(answer["table"]?["checksum"])
        XCTAssertEqual(answer["entry"]?["fields"]?.arrayValue?.isEmpty, false)

        let missing = try await client.call("fit_table", ["entry": 99])
        XCTAssertTrue(missing.answer.stringValue?.hasPrefix("The table has no row 99") == true, "\(missing.answer)")
    }

    func testAWrongChecksumIsAProblem() async throws {
        try open(FITTestImage.make(checksum: 0x42))
        let answer = try await client.answer("fit_table")
        let problems = try XCTUnwrap(answer["problems"]?.arrayValue)
        XCTAssertTrue(problems.contains { $0["severity"] == "error" }, "\(problems)")
        XCTAssertEqual(answer["rows"]?.arrayValue?.first?["problem"], true)
    }

    func testAFileWithNoFITSaysSo() async throws {
        try open([UInt8](repeating: 0xFF, count: 0x1000))
        let answer = try await client.answer("fit_table")
        XCTAssertEqual(answer["summary"], "No FIT table in this file.")
        XCTAssertEqual(answer["rows"], [])
    }

    // MARK: - me_summary, me_tree

    func testTheMESummaryAndTreeAreReadWithThePanelClosed() async throws {
        let controller = try open(METestImage.fptFile())
        XCTAssertNil(controller.tools.activeIdentifier)

        let summary = try await client.answer("me_summary")
        let labels = summary["blocks"]?.arrayValue?.first?["rows"]?.arrayValue?.compactMap { $0["label"]?.stringValue }
        XCTAssertEqual(labels?.first, "Family", "\(summary)")

        let top = try await client.answer("me_tree")
        let regions = try XCTUnwrap(top["children"]?.arrayValue?.first { $0["title"] == "Regions (FPT)" }, "\(top)")
        let id = try XCTUnwrap(regions["id"]?.stringValue)
        let node = try await client.answer("me_tree", ["node": .string(id)])
        XCTAssertEqual(node["children"]?.arrayValue?.compactMap { $0["title"]?.stringValue }.contains("FTUE"), true,
                       "\(node)")
        XCTAssertNotNil(node["node"]?["fields"])

        // The analysis is the pane's now: the panel opens onto it.
        XCTAssertNotNil(controller.windowModel.pane1.uefiState.cachedMEAnalysis())
        let wrong = try await client.call("me_tree", ["node": "9.9"])
        XCTAssertEqual(wrong.answer, "No ME node 9.9. Ids come from `me_tree` on the same document.")
    }
}

/// An NVRAM volume holding one VSS store, its variables given in the order
/// they were written — `UEFITestImage`'s volume with the NVRAM file system
/// GUID.
enum NvramTestImage {
    static let valid: UInt8 = 0x7F
    /// A copy a later one replaced.
    static let superseded: UInt8 = 0x3C
    static let vendor = EFIGUID("8BE4DF61-93CA-11D2-AA0D-00E098032B8C")!

    struct Variable {
        var name: String
        var data: [UInt8]
        var state: UInt8

        init(_ name: String, _ data: [UInt8], state: UInt8 = NvramTestImage.valid) {
            self.name = name
            self.data = data
            self.state = state
        }
    }

    static func vss(_ variables: [Variable]) -> [UInt8] {
        var image = UEFITestImage.make()
        image.replaceSubrange(0x10..<0x20, with: NvramGuids.nvramMainStoreVolumeGuid.bytes)
        image.replaceSubrange(0x48..<0x1000, with: [UInt8](repeating: 0xFF, count: 0x1000 - 0x48))
        image[0x32] = 0
        image[0x33] = 0
        let checksum = Checksums.checksum16(Array(image[0..<0x48])) ?? 0
        image[0x32] = UInt8(truncatingIfNeeded: checksum)
        image[0x33] = UInt8(truncatingIfNeeded: checksum >> 8)

        var body: [UInt8] = []
        for variable in variables {
            let units: [UInt8] = variable.name.utf16.flatMap { unit -> [UInt8] in
                [UInt8(truncatingIfNeeded: unit), UInt8(truncatingIfNeeded: unit >> 8)]
            }
            let name = units + [0, 0]
            body += [0xAA, 0x55, variable.state, 0]
            body += u32(0x07)                       // attributes
            body += u32(UInt32(name.count))
            body += u32(UInt32(variable.data.count))
            body += vendor.bytes
            body += name + variable.data
        }
        body += [UInt8](repeating: 0xFF, count: 0x10)
        var store: [UInt8] = u32(0x5353_5624)       // $VSS
        store += u32(UInt32(16 + body.count))
        store += [0x5A, 0xFE, 0, 0]                 // formatted, healthy
        store += u32(0)
        store += body
        image.replaceSubrange(0x48..<(0x48 + store.count), with: store)
        return image
    }

    private static func u32(_ value: UInt32) -> [UInt8] {
        (0..<4).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) }
    }
}
