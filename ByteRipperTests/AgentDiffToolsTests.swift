import AgentKit
import ToolModuleKit
import XCTest
@testable import ByteRipper

/// Two documents compared byte by byte for an agent (`Design/AGENT_PLAN.md`,
/// stage 8): the runs, merged and counted, placed in the firmware's
/// structure, paged behind a cursor that refuses once a document changed; and
/// the pair shown to the person and walked difference by difference.
@MainActor
final class AgentDiffToolsTests: XCTestCase {
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
        // A test's own "new tab": the pair in its one window.
        service.diffTools.openPairInNewTab = { [weak self] first, second in
            guard let controller = self?.controller else { return }
            try? controller.windowModel.pane1.open(url: first)
            try? controller.windowModel.pane2.open(url: second)
            controller.apply(mode: .comparison)
        }
        client = AgentTestClient(service)
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("agent-diff-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        service.stop()
        controller?.windowModel.pane1.close()
        controller?.windowModel.pane2.close()
        window?.orderOut(nil)
        window = nil
        controller = nil
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

    private func background(_ bytes: [UInt8], _ name: String = "other.bin") async throws -> String {
        let url = try write(bytes, name)
        let opened = try await client.answer("open_dump", ["path": .string(url.path)])
        return try XCTUnwrap(opened["document"]?.stringValue)
    }

    private func runs(_ answer: JSONValue) -> [String] {
        (answer["runs"]?.arrayValue ?? []).compactMap { run in
            guard let start = run["start"]?.stringValue, let end = run["end"]?.stringValue else { return nil }
            return "\(start)–\(end):\(run["differing_bytes"]?.jsonText ?? "?")"
        }
    }

    // MARK: - The list

    func testTheDiffToolsAreListed() throws {
        let tools = Dictionary(uniqueKeysWithValues: service.server.tools.map { ($0.name, $0) })
        XCTAssertEqual(try XCTUnwrap(tools["diff"]).annotations, .readOnly)
        XCTAssertEqual(try XCTUnwrap(tools["compare"]).annotations, .view)
        XCTAssertEqual(try XCTUnwrap(tools["reveal_diff"]).annotations, .view)
        XCTAssertEqual(tools["diff"]?.inputSchema["required"], ["against"])
    }

    // MARK: - Runs

    func testIdenticalFilesHaveNoRuns() async throws {
        try open([UInt8](repeating: 7, count: 0x3000))
        let other = try await background([UInt8](repeating: 7, count: 0x3000))
        let answer = try await client.answer("diff", ["against": .string(other), "structure": "none"])
        XCTAssertEqual(answer["runs"], [])
        XCTAssertEqual(answer["totals"], ["runs": 0, "differing_bytes": 0])
        XCTAssertEqual(answer["next"], .null)
        XCTAssertNil(answer["tail"])
    }

    /// A difference at the first byte, two across a chunk boundary, and one at
    /// the last byte, merged across `merge_gap` matching bytes and not past.
    func testRunsAreMergedAcrossTheGapAndCounted() async throws {
        var bytes = [UInt8](repeating: 0, count: 0x20_0010)
        try open(bytes)
        bytes[0] = 1
        bytes[0x10_0000 - 1] = 1                // the last byte of the first megabyte chunk
        bytes[0x10_0000 + 4] = 1                // four matching bytes later, in the next chunk
        bytes[bytes.count - 1] = 1
        let other = try await background(bytes)

        let merged = try await client.answer("diff", ["against": .string(other), "structure": "none"])
        XCTAssertEqual(runs(merged), ["0x0–0x1:1", "0xFFFFF–0x100005:2", "0x20000F–0x200010:1"])
        XCTAssertEqual(merged["totals"], ["runs": 3, "differing_bytes": 4])
        XCTAssertEqual(merged["runs"]?.arrayValue?[1]["length"], "0x6")

        let apart = try await client.answer("diff", ["against": .string(other), "structure": "none", "merge_gap": 3])
        XCTAssertEqual(apart["totals"]?["runs"], 4, "five bytes apart is past a gap of three")
        let none = try await client.answer("diff", ["against": .string(other), "structure": "none", "merge_gap": 0])
        XCTAssertEqual(none["totals"]?["runs"], 4)
    }

    func testARangeIsComparedAlone() async throws {
        var bytes = [UInt8](repeating: 0, count: 0x100)
        try open(bytes)
        bytes[0x10] = 1
        bytes[0x80] = 1
        let other = try await background(bytes)
        let answer = try await client.answer("diff", ["against": .string(other), "structure": "none",
                                                      "offset": "0x40", "end": "0x100"])
        XCTAssertEqual(runs(answer), ["0x80–0x81:1"])
        XCTAssertEqual(answer["range"]?["start"], "0x40")
    }

    /// Only the bytes both hold are compared; the longer one's tail is said,
    /// not counted.
    func testTheLongerFilesTailIsReportedApart() async throws {
        try open([1, 2, 3, 4, 5, 6])
        let other = try await background([1, 2, 9, 4])
        let answer = try await client.answer("diff", ["against": .string(other), "structure": "none"])
        XCTAssertEqual(runs(answer), ["0x2–0x3:1"])
        XCTAssertEqual(answer["tail"], ["in": "document", "start": "0x4", "end": "0x6"])
        XCTAssertEqual(answer["truncated_at"], "0x4")
        let past = try await client.call("diff", ["against": .string(other), "end": "0x6"])
        XCTAssertEqual(past.answer, "`end` 0x6 is past the end of the shorter document, which is 0x4 bytes long.")
    }

    func testWrongArgumentsAreRefused() async throws {
        try open([1, 2, 3, 4])
        let other = try await background([1, 2, 3, 4])
        let itself = try await client.call("diff", ["against": "d1"])
        XCTAssertEqual(itself.answer, "`document` and `against` are the same document, d1.")
        let backwards = try await client.call("diff", ["against": .string(other), "offset": "0x3", "end": "0x2"])
        XCTAssertEqual(backwards.answer, "`offset` 0x3 is not below `end` 0x2.")
    }

    // MARK: - Pages

    /// The pages add up to the totals, and a page asked for after a document
    /// changed is refused rather than answered from other bytes.
    func testPagesAddUpAndACursorDiesWithAnEdit() async throws {
        var bytes = [UInt8](repeating: 0, count: 0x100)
        let controller = try open(bytes)
        for index in stride(from: 0, to: 0x100, by: 0x20) { bytes[index] = 1 }
        let other = try await background(bytes)

        var seen: [String] = []
        var after: JSONValue?
        repeat {
            var arguments: [String: JSONValue] = ["against": .string(other), "structure": "none", "limit": 3]
            if let after { arguments["after"] = after }
            let page = try await client.answer("diff", .object(arguments))
            XCTAssertEqual(page["totals"]?["runs"], 8)
            seen += runs(page)
            after = page["next"] == .null ? nil : page["next"]
        } while after != nil
        XCTAssertEqual(seen.count, 8)
        XCTAssertEqual(Set(seen).count, 8)

        let first = try await client.answer("diff", ["against": .string(other), "structure": "none", "limit": 3])
        try controller.windowModel.pane1.applyToolWrites([(offset: 0x40, bytes: [1])], named: "Test")
        let stale = try await client.call("diff", ["against": .string(other), "structure": "none", "limit": 3,
                                                   "after": first["next"] ?? .null])
        XCTAssertEqual(stale.answer,
                       "A document changed since that page, or the range or `merge_gap` did; ask again without `after`.")
    }

    // MARK: - Where

    /// A changed variable is placed at its entry, inside the volume that is
    /// the image's top-level area; the summary accounts for every byte.
    func testARunIsPlacedAtTheVariableItChanged() async throws {
        try open(NvramTestImage.vss([.init("Setup", [1, 1]), .init("Lang", [0x65])]))
        let other = try await background(NvramTestImage.vss([.init("Setup", [1, 9]), .init("Lang", [0x65])]))

        let answer = try await client.answer("diff", ["against": .string(other)])
        let place = try XCTUnwrap(answer["runs"]?.arrayValue?.first?["where"]?.arrayValue, "\(answer)")
        XCTAssertEqual(place.last?["name"], "Setup")
        XCTAssertEqual(place.last?["kind"], "uefi")
        XCTAssertEqual(place.first?["id"], "0", "the volume, the image's one area")

        let summary = try await client.answer("diff", ["against": .string(other), "summary": true])
        let areas = try XCTUnwrap(summary["areas"]?.arrayValue)
        XCTAssertEqual(areas.count, 1, "\(areas)")
        XCTAssertEqual(areas.first?["differing_bytes"], 1)
        XCTAssertEqual(areas.first?["runs"], 1)
    }

    /// A file that is no firmware image is one stretch of padding to the
    /// parser, and so one area, and its runs are placed in it.
    func testAFileWithNoStructureIsOneArea() async throws {
        try open([UInt8](repeating: 0x55, count: 0x200))
        var bytes = [UInt8](repeating: 0x55, count: 0x200)
        bytes[0x100] = 0
        let other = try await background(bytes)
        let summary = try await client.answer("diff", ["against": .string(other), "summary": true])
        let areas = try XCTUnwrap(summary["areas"]?.arrayValue)
        XCTAssertEqual(areas.count, 1, "\(areas)")
        XCTAssertEqual(areas.first?["end"], "0x200")
        XCTAssertEqual(areas.first?["differing_bytes"], 1)
        let list = try await client.answer("diff", ["against": .string(other)])
        XCTAssertEqual(list["runs"]?.arrayValue?.first?["where"]?.arrayValue?.count, 1)
    }

    /// The finer areas take the coarser one's place, and what they leave of it
    /// keeps its name.
    func testADividedAreaKeepsItsGaps() {
        let region = ToolAgentPlace(kind: "uefi", id: "0.1", name: "ME region", range: 0x1000..<0x6000)
        let finer = [ToolAgentPlace(kind: "me", id: "2.1", name: "Boot 1", range: 0x2000..<0x3000),
                     ToolAgentPlace(kind: "me", id: "2.0", name: "Data", range: 0x3000..<0x4000),
                     ToolAgentPlace(kind: "me", id: "9", name: "Elsewhere", range: 0x7000..<0x8000)]
        let pieces = AgentDiffTools.divided(region, by: finer)
        XCTAssertEqual(pieces.map(\.name), ["ME region", "Boot 1", "Data", "ME region"])
        XCTAssertEqual(pieces.map(\.range), [0x1000..<0x2000, 0x2000..<0x3000, 0x3000..<0x4000, 0x4000..<0x6000])
        XCTAssertEqual(AgentDiffTools.divided(region, by: []), [region])
    }

    // MARK: - survey

    func testASurveyComparesAFolderWithOneDump() async throws {
        var bytes = [UInt8](repeating: 0, count: 0x40)
        try open(bytes)
        try write(bytes, "same.bin")
        bytes[3] = 1
        try write(bytes, "changed.bin")
        let survey = try await client.answer("survey", [
            "folder": .string(folder.path), "tool": "diff",
            "arguments": ["against": "d1", "structure": "none"], "group_by": "totals.runs"
        ])
        let groups = try XCTUnwrap(survey["groups"]?.arrayValue)
        let byValue = Dictionary(uniqueKeysWithValues: groups.map { ($0["value"]?.jsonText ?? "", $0) })
        XCTAssertEqual(byValue["1"]?["files"], ["changed.bin"], "\(survey)")
        XCTAssertEqual(byValue["0"]?["files"], ["same.bin"], "\(survey)")
    }

    // MARK: - compare, reveal_diff

    /// A file alone in its tab gets the other beside it, and the walk lands
    /// both carets on each difference in turn.
    func testThePairIsShownAndWalked() async throws {
        var bytes = [UInt8](repeating: 0, count: 0x400)
        let controller = try open(bytes)
        bytes[0x100] = 1
        bytes[0x300] = 1
        let other = try await background(bytes)

        let shown = try await client.answer("compare", ["against": .string(other)])
        XCTAssertEqual(shown["a"], "d1")
        XCTAssertEqual(controller.mode, .comparison)
        XCTAssertEqual(controller.windowModel.pane2.document?.url.lastPathComponent, "other.bin")
        XCTAssertTrue(service.desk.background.entries.isEmpty, "the background copy gave way to the tab")
        let again = try await client.answer("compare", ["document": shown["a"] ?? .null, "against": shown["b"] ?? .null])
        XCTAssertEqual(again["was_shown"], true)

        let first = try await client.answer("reveal_diff", ["from": 0])
        XCTAssertEqual(first["start"], "0x100")
        XCTAssertEqual(controller.windowModel.pane1.caretOffset, 0x100)
        XCTAssertEqual(controller.windowModel.pane2.caretOffset, 0x100)
        let second = try await client.answer("reveal_diff")
        XCTAssertEqual(second["start"], "0x300")
        let end = try await client.answer("reveal_diff")
        XCTAssertEqual(end["found"], false)
        let back = try await client.answer("reveal_diff", ["direction": "previous"])
        XCTAssertEqual(back["start"], "0x100")
    }

    func testRevealDiffNeedsAPair() async throws {
        try open([0, 1])
        let refused = try await client.call("reveal_diff")
        XCTAssertEqual(refused.answer, "d1 is not one of a pair shown side by side. `compare` shows it beside another.")
    }

    // MARK: - Merging

    func testRunsMergeAcrossAtMostTheGap() {
        let differing: [Range<UInt64>] = [0..<2, 4..<5, 9..<10]
        XCTAssertEqual(AgentDiffTools.runs(differing, mergeGap: 2).map(\.range), [0..<5, 9..<10])
        XCTAssertEqual(AgentDiffTools.runs(differing, mergeGap: 4).map(\.range), [0..<10])
        XCTAssertEqual(AgentDiffTools.runs(differing, mergeGap: 4).first?.differing, 4)
        XCTAssertEqual(AgentDiffTools.runs(differing, mergeGap: 0).count, 3)
    }
}
