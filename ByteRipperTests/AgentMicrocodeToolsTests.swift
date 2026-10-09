import AgentKit
import FITTool
import FITToolUI
import XCTest
@testable import ByteRipper

/// An agent's microcode work through the online catalogue: what it offers for
/// the image, and adding, updating, replacing and removing — with the panel's
/// own refusals of a microcode the table already has, found through the
/// extended signature tables as well.
@MainActor
final class AgentMicrocodeToolsTests: XCTestCase {
    private var controller: MainViewController?
    private var window: NSWindow?
    private var service: AgentService!
    private var client: AgentTestClient!
    private var defaultsName = ""
    private var defaults: UserDefaults!
    private var folder: URL!
    private var savedSource: (any MicrocodeSource)!

    override func setUp() {
        super.setUp()
        (defaultsName, defaults) = isolatedDefaults(for: self)
        let desk = AgentDesk(controllers: { [weak self] in self?.controller.map { [$0] } ?? [] },
                             keyController: { [weak self] in self?.controller })
        service = AgentService(desk: desk, defaults: defaults,
                               socketPath: "/tmp/br-\(UUID().uuidString.prefix(8)).sock")
        service.editsAllowed = true
        client = AgentTestClient(service)
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("agent-microcode-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        savedSource = FITToolSession.microcodeSource
        FITToolSession.microcodeSource = CatalogueStub()
    }

    override func tearDown() {
        FITToolSession.microcodeSource = savedSource
        service.stop()
        controller?.windowModel.pane1.close()
        window?.orderOut(nil)
        window = nil
        controller = nil
        try? FileManager.default.removeItem(at: folder)
        discardIsolatedDefaults(defaultsName, defaults)
        super.tearDown()
    }

    @discardableResult
    private func open(_ bytes: [UInt8]) throws -> PaneViewModel {
        let controller = MainViewController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        self.controller = controller
        self.window = window
        let url = folder.appendingPathComponent("image.bin")
        try Data(bytes).write(to: url)
        try controller.windowModel.pane1.open(url: url)
        controller.apply(mode: .singleFile)
        return controller.windowModel.pane1
    }

    private func rows() async throws -> [JSONValue] {
        let table = try await client.answer("fit_table")
        return try XCTUnwrap(table["rows"]?.arrayValue)
    }

    // MARK: - The catalogue

    func testTheCatalogueSaysHowTheImageStands() async throws {
        try open(FITTestImage.make())
        let answer = try await client.answer("microcode_catalogue", ["in_image": true])
        let installed = try XCTUnwrap(answer["installed"]?.arrayValue?.first)
        XCTAssertEqual(installed["entry"], 1)
        XCTAssertEqual(installed["revision"], "0xF0")
        XCTAssertEqual(installed["catalogue"], "outdated")
        XCTAssertEqual(installed["newest_revision"], "0xF4", "the extended update, filed under 806EA too")
        let files = try XCTUnwrap(answer["files"]?.arrayValue)
        XCTAssertEqual(files.compactMap { $0["path"]?.stringValue },
                       [CatalogueStub.extendedUnder806EA, CatalogueStub.newer], "the files for 806EA, newest first")
        XCTAssertEqual(files.first?["serves_rows"], [1])
        XCTAssertEqual(files.first?["newer_than_installed"], true)
        XCTAssertEqual(answer["next"], .null)

        let narrowed = try await client.answer("microcode_catalogue", ["cpuid": "906", "latest_only": true])
        XCTAssertEqual(narrowed["files"]?.arrayValue?.compactMap { $0["cpuid"]?.stringValue }, ["906EA"])
    }

    // MARK: - Adding and updating

    /// The same processor's newer update takes the row's place; the very same
    /// update again is refused with the row that holds it.
    func testANewerUpdateReplacesTheRowAndTheSameOneIsRefused() async throws {
        let pane = try open(FITTestImage.make())
        let added = try await client.answer("fit_add_microcode", ["path": .string(CatalogueStub.newer)])
        XCTAssertEqual(added["change"], "replaced")
        XCTAssertEqual(added["entry"], 1)
        XCTAssertEqual(added["replaced"]?["revision"], "0xF0")
        XCTAssertEqual(added["undo"], "Agent: Add Microcode 806EA")
        XCTAssertNotNil(added["protected_ranges"])
        XCTAssertEqual(pane.undoLabel, "Agent: Add Microcode 806EA")
        let after = try await rows()
        XCTAssertEqual(after.filter { $0["type"] == "Microcode" || $0["cpuids"] != nil }.count, 1, "still one row")

        let again = try await client.call("fit_add_microcode", ["path": .string(CatalogueStub.newer)])
        XCTAssertTrue(again.isError)
        XCTAssertTrue(again.answer.stringValue?.hasPrefix("This microcode is already in the table") == true,
                      "\(again.answer)")
        XCTAssertTrue(again.answer.stringValue?.hasSuffix("In `fit_table` that row is entry 1.") == true)
    }

    /// An update filed under another CPUID whose extended signature table
    /// names the row's processor is that processor's update: it takes the row,
    /// it does not get a second one.
    func testAnUpdateThatServesTheRowThroughItsExtendedTableReplacesIt() async throws {
        try open(FITTestImage.make())
        let added = try await client.answer("fit_add_microcode", ["path": .string(CatalogueStub.extended)])
        XCTAssertEqual(added["change"], "replaced", "\(added)")
        XCTAssertEqual(added["replaced"]?["cpuid"], "806EA")
        let microcodeRows = try await rows().filter { $0["cpuids"] != nil }
        XCTAssertEqual(microcodeRows.count, 1)
        XCTAssertEqual(microcodeRows.first?["cpuids"], ["806EB", "806EA"])
    }

    /// A processor nothing in the table serves gets a row of its own.
    func testAnUpdateForAnotherProcessorIsAdded() async throws {
        try open(FITTestImage.make())
        let added = try await client.answer("fit_add_microcode", ["path": .string(CatalogueStub.other)])
        XCTAssertEqual(added["change"], "added", "\(added)")
        let microcodeRows = try await rows().filter { $0["cpuids"] != nil }
        XCTAssertEqual(microcodeRows.count, 2)
    }

    // MARK: - Replacing

    /// Replacing a row with an update that serves, through its extended table,
    /// the processor another row serves would leave two microcodes for it:
    /// refused, naming the row to replace instead.
    func testAReplacementServingAnotherRowsProcessorIsRefused() async throws {
        let pane = try open(FITTestImage.make(extraMicrocode: true))
        let refused = try await client.call("fit_replace_microcode",
                                            ["entry": 2, "path": .string(CatalogueStub.extended)])
        XCTAssertTrue(refused.isError)
        XCTAssertTrue(refused.answer.stringValue?.contains("already holds a microcode for CPUID 806EA") == true,
                      "\(refused.answer)")
        XCTAssertTrue(refused.answer.stringValue?.hasSuffix("In `fit_table` that row is entry 1.") == true)
        XCTAssertNil(pane.undoLabel, "nothing written")

        let replaced = try await client.answer("fit_replace_microcode",
                                               ["entry": 1, "path": .string(CatalogueStub.extended)])
        XCTAssertEqual(replaced["change"], "replaced")
        XCTAssertEqual(replaced["undo"], "Agent: Replace Microcode 806EB")
    }

    // MARK: - Removing

    func testARowIsRemovedButNotTheLastOne() async throws {
        try open(FITTestImage.make(extraMicrocode: true))
        let removed = try await client.answer("fit_remove_microcode", ["entry": 2])
        XCTAssertEqual(removed["change"], "removed")
        XCTAssertEqual(removed["undo"], "Agent: Remove Microcode 906EA")
        let remaining = try await rows().filter { $0["cpuids"] != nil }
        XCTAssertEqual(remaining.count, 1)

        let last = try await client.call("fit_remove_microcode", ["entry": 1])
        XCTAssertTrue(last.isError, "\(last.answer)")
        let notMicrocode = try await client.call("fit_remove_microcode", ["entry": 0])
        XCTAssertEqual(notMicrocode.answer, "The table has no row 0; its rows are 1 to 1 after the header.")
    }

    func testAPathNotInTheCatalogueOrNotIntelIsRefused() async throws {
        try open(FITTestImage.make())
        let unknown = try await client.call("fit_add_microcode", ["path": "Intel/nothing.bin"])
        XCTAssertEqual(unknown.answer, "No file Intel/nothing.bin in the catalogue; `microcode_catalogue` lists them.")
        let amd = try await client.call("fit_add_microcode", ["path": .string(CatalogueStub.amd)])
        XCTAssertEqual(amd.answer, .string("\(CatalogueStub.amd) is AMD microcode; a FIT names only Intel's."))
    }

    func testTheEditsWaitForThePersonsPermission() async throws {
        service.editsAllowed = false
        try open(FITTestImage.make())
        let refused = try await client.call("fit_add_microcode", ["path": .string(CatalogueStub.newer)])
        XCTAssertTrue(refused.answer.stringValue?.hasPrefix("Editing is switched off.") == true, "\(refused.answer)")
    }
}

/// A catalogue of a few files and their bytes, no network.
private struct CatalogueStub: MicrocodeSource {
    static let newer = "Intel/cpu806EA_plat01_ver000000F2_2020-01-01_PRD_00000001.bin"
    static let extended = "Intel/cpu806EB_plat01_ver000000F4_2021-01-01_PRD_00000002.bin"
    static let extendedUnder806EA = "Intel/cpu806EA_plat01_ver000000F4_2021-01-01_PRD_00000002.bin"
    static let other = "Intel/cpu906EA_plat01_ver000000B4_2021-01-01_PRD_00000003.bin"
    static let amd = "AMD/cpu00800F11_ver08001129_2017-07-14_4F426450.bin"

    func catalogue() async throws -> [MicrocodeCatalogueEntry] {
        [Self.newer, Self.extended, Self.extendedUnder806EA, Self.other, Self.amd]
            .compactMap { MicrocodeCatalogue.entry(at: $0, size: 0x100) }
    }

    func download(_ entry: MicrocodeCatalogueEntry) async throws -> [UInt8] {
        switch entry.path {
        case Self.newer: return FITTestImage.microcode(signature: 0x806EA, revision: 0xF2)
        case Self.extended, Self.extendedUnder806EA:
            return MicrocodeWithExtendedTable.make(signature: 0x806EB, revision: 0xF4,
                                                   extended: [(0x806EB, 1), (0x806EA, 1)])
        default: return FITTestImage.microcode(signature: entry.cpuid ?? 0, revision: entry.revision ?? 0)
        }
    }
}

/// An update whose extended signature table names further processors, every
/// checksum right.
enum MicrocodeWithExtendedTable {
    static func make(signature: UInt32, revision: UInt32, extended: [(UInt32, UInt32)]) -> [UInt8] {
        func u32(_ value: UInt32) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) } }
        func sum(_ bytes: [UInt8]) -> UInt32 {
            stride(from: 0, to: bytes.count, by: 4).reduce(UInt32(0)) { total, index in
                total &+ (UInt32(bytes[index]) | UInt32(bytes[index + 1]) << 8
                    | UInt32(bytes[index + 2]) << 16 | UInt32(bytes[index + 3]) << 24)
            }
        }
        let dataSize: UInt32 = 0x40
        var table = u32(UInt32(extended.count)) + u32(0) + [UInt8](repeating: 0, count: 12)
        for (processor, platforms) in extended { table += u32(processor) + u32(platforms) + u32(0) }
        table.replaceSubrange(4..<8, with: u32(0 &- sum(table)))
        let total = UInt32(0x30) + dataSize + UInt32(table.count)
        var bytes: [UInt8] = []
        let date: [UInt8] = [0x19, 0x20, 0x15, 0x07]
        for part in [u32(1), u32(revision), date, u32(signature), u32(0), u32(1), u32(1),
                     u32(dataSize), u32(total), u32(0), u32(0), u32(0)] {
            bytes += part
        }
        bytes += [UInt8](repeating: 0x5A, count: Int(dataSize))
        bytes += table
        bytes.replaceSubrange(0x10..<0x14, with: u32(0 &- sum(bytes)))
        return bytes
    }
}
