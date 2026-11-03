import CodeAnalysis
import Foundation
import XCTest
@testable import GhidraHost

/// What the reviews asked of the owner's calls, against Ghidra, on a copy of the
/// kept CpuPei project. Nothing here writes to a kept project.
final class GhidraOwnerRemarksTests: XCTestCase {
    private var directory: URL!
    private var host: GhidraHost!
    private var store: ContentStore!
    private var module: SHA256Digest!

    override func setUp() async throws {
        guard (try? GhidraInstall.find()) != nil else { throw XCTSkip("no Ghidra on this machine") }
        let source = GhidraHost.defaultProjectsRoot
        guard let original = GhidraProject.all(in: source).first(where: { (try? $0.state().module.name) == "CpuPei" }) else {
            throw XCTSkip("no kept CpuPei project to copy")
        }
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GhidraOwnerRemarks-\(UUID().uuidString)", isDirectory: true)
        let projects = directory.appendingPathComponent("projects")
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        let copy = projects.appendingPathComponent(original.module.hex)
        try FileManager.default.copyItem(at: original.folder, to: copy)
        try? FileManager.default.removeItem(at: copy.appendingPathComponent("owner.json"))
        store = try ContentStore(root: directory.appendingPathComponent("store"))
        host = GhidraHost(configuration: .init(projectsRoot: projects, idle: 120, holder: "GhidraOwnerRemarksTests"),
                          writer: store)
        module = original.module
    }

    override func tearDown() async throws {
        if let host, let module { await host.stop(module) }
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func read(_ path: String) async throws -> [String: Any] {
        let data = try await host.read(module, path)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func post(_ path: String, _ object: [String: Any]) async throws -> [String: Any] {
        let body = try JSONSerialization.data(withJSONObject: object)
        let data = try await host.write(module, path, body: body)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func entries() async throws -> [String] {
        (try await read("/v1/functions")["functions"] as? [[String: Any]] ?? []).compactMap { $0["entry"] as? String }
    }

    private func instructions(_ entry: String) async throws -> [[String: Any]] {
        try await read("/v1/disassembly/\(entry)")["instructions"] as? [[String: Any]] ?? []
    }

    /// `names` lets only those go, the answer holds what it needs to give one
    /// back, and a name the function has not got changes nothing.
    func testResettingNamedLocalsLeavesTheOthersAndSaysWhatWent() async throws {
        for entry in try await entries() {
            let locals = try await read("/v1/function/\(entry)")["locals"] as? [[String: Any]] ?? []
            let stack = locals.filter { ($0["storage"] as? String ?? "").hasPrefix("Stack") }
            guard stack.count >= 2, let storage = stack[0]["storage"] as? String else { continue }
            var rename: [String: Any] = ["function": entry, "name": "RemarkKept", "storage": storage]
            if let first = stack[0]["first_use"] as? String { rename["first_use"] = first }
            guard (try? await post("/v1/rename/variable", rename)) != nil else { continue }
            do {
                _ = try await post("/v1/clear/locals", ["address": entry, "names": ["NoSuchLocal"]])
                XCTFail("an unknown name is refused")
            } catch {}
            let reset = try await post("/v1/clear/locals", ["address": entry, "names": ["RemarkKept"]])
            XCTAssertEqual(reset["names"] as? [String], ["RemarkKept"])
            let gone = try XCTUnwrap((reset["locals"] as? [[String: Any]])?.first)
            XCTAssertEqual(gone["name"] as? String, "RemarkKept")
            XCTAssertNotNil(gone["storage"])
            XCTAssertNotNil(gone["type"])
            return
        }
        throw XCTSkip("no function with two stack locals that takes a name")
    }

    /// Comments in the live C stand with the code, as the stored C has them.
    func testLiveCIndentsACommentWithItsCode() async throws {
        for entry in try await entries() {
            let code = try await instructions(entry)
            guard code.count > 6, let at = code[code.count / 2]["address"] as? String else { continue }
            _ = try await post("/v1/set/comment", ["address": at, "kind": "pre", "text": "RemarkStep"])
            let c = try await read("/v1/function/\(entry)")["c"] as? String ?? ""
            let lines = c.components(separatedBy: "\n")
            guard let line = lines.firstIndex(where: { $0.contains("RemarkStep") }), line + 1 < lines.count else { continue }
            func indent(_ text: String) -> Int { text.prefix { $0 == " " }.count }
            guard let next = lines[(line + 1)...].first(where: { !$0.isEmpty && !$0.contains("/*") }) else { continue }
            XCTAssertEqual(indent(lines[line]), indent(next), c)
            return
        }
        throw XCTSkip("no function printed the comment")
    }

    /// A UINT64 a 32-bit convention moves is named in the answer.
    func testASignatureSaysWhatTheConventionAligned() async throws {
        let all = try await entries()
        let entry = try XCTUnwrap(all.first)
        let answer = try await post("/v1/set/signature", ["address": entry, "signature": "void RemarkFn(UINT32 First, UINT64 Wide, UINT32 Last)"])
        let aligned = (answer["aligned"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
        let plain = try await post("/v1/set/signature", ["address": entry, "signature": "void RemarkFn(UINT32 First, UINT32 Last)"])
        XCTAssertNil(plain["aligned"], "\(plain)")
        print("aligned: \(aligned), storage \(answer)")
        XCTAssertEqual(aligned.first, "Wide", "\(answer)")
    }

    /// Several operands in one call; `in_c` on one, `not_in_c` over many.
    func testAnEquateTakesItemsAndSaysWhetherTheCPrintsIt() async throws {
        var places: [(String, Int)] = []
        search: for entry in try await entries() {
            for instruction in try await instructions(entry) {
                let text = instruction["text"] as? String ?? ""
                if text.hasPrefix("MOV"), text.range(of: #",0x[0-9a-f]{2,}$"#, options: .regularExpression) != nil,
                   let at = instruction["address"] as? String {
                    places.append((at, 1))
                    if places.count == 3 { break search }
                }
            }
        }
        guard places.count == 3 else { throw XCTSkip("too few immediates") }
        let one = try await post("/v1/set/equate", ["address": places[0].0, "operand": 1, "name": "REMARK_ONE"])
        XCTAssertNotNil(one["in_c"], "\(one)")
        let many = try await post("/v1/set/equate", ["items": [
            ["address": places[1].0, "operand": 1, "name": "REMARK_TWO"],
            ["address": places[2].0, "operand": 1, "name": "REMARK_THREE"]
        ]])
        XCTAssertEqual((many["items"] as? [[String: Any]])?.count, 2, "\(many)")
        XCTAssertNotNil(many["not_in_c"], "\(many)")
        let held = try await instructions(places[1].0)
        XCTAssertTrue(held.contains { ($0["equates"] as? [[String: Any]])?.first?["name"] as? String == "REMARK_TWO" }, "\(held.count)")
    }

    /// Code no function holds is read to the next function, and says so.
    func testDisassemblyReadsAGap() async throws {
        let all = try await entries()
        guard all.count > 3 else { throw XCTSkip("too few functions") }
        let gone = all[1], next = all[2]
        _ = try await post("/v1/delete/function", ["address": gone])
        let answer = try await read("/v1/disassembly/\(gone)")
        XCTAssertEqual(answer["gap"] as? String, gone, "\(answer)")
        XCTAssertNil(answer["entry"])
        let addresses = (answer["instructions"] as? [[String: Any]] ?? []).compactMap { $0["address"] as? String }
        XCTAssertEqual(addresses.first, gone)
        XCTAssertFalse(addresses.contains(next), "it stops at the next function")
        do {
            _ = try await read("/v1/disassembly/0x1")
            XCTFail("nothing at that address")
        } catch {}
    }

    /// The filter says what it leaves out.
    func testTheUnfinishedFilterCountsWhatItLeavesOut() async throws {
        let summary = try await read("/v1/functions?filter=unfinished")["summary"] as? [String: Any]
        XCTAssertNotNil(summary?["fragments_only"], "\(String(describing: summary))")
    }

    /// Two functions merged answer the merge, on the object read again.
    func testAMergeGrowsTheFirstFunction() async throws {
        let all = try await entries()
        guard all.count > 3 else { throw XCTSkip("too few functions") }
        for index in 1..<(all.count - 1) {
            guard let answer = try? await post("/v1/merge/functions", ["into": all[index], "from": all[index + 1]]) else { continue }
            XCTAssertEqual(answer["merged"] as? String, all[index + 1])
            let after = try await entries()
            XCTAssertFalse(after.contains(all[index + 1]))
            return
        }
        XCTFail("no pair of neighbours merged")
    }

    /// A comment on data a function reaches is in the function's answer.
    func testAFunctionListsTheCommentsOnItsData() async throws {
        let data = try await read("/v1/data")
        let places = Set((data["data"] as? [[String: Any]] ?? data["items"] as? [[String: Any]] ?? []).compactMap { $0["address"] as? String })
        for entry in try await entries() {
            for instruction in try await instructions(entry) {
                for reference in instruction["references"] as? [[String: Any]] ?? [] {
                    guard let to = reference["to"] as? String, places.contains(to) else { continue }
                    _ = try await post("/v1/set/comment", ["address": to, "kind": "plate", "text": "RemarkDatum"])
                    let comments = try await read("/v1/function/\(entry)")["data_comments"] as? [[String: Any]] ?? []
                    XCTAssertTrue(comments.contains { $0["comment"] as? String == "RemarkDatum" }, "\(comments)")
                    return
                }
            }
        }
        throw XCTSkip("no function reaches listed data")
    }

    /// A publish with nothing new keeps the time of the one before it.
    func testAPublishWithNothingNewKeepsItsTime() async throws {
        let all = try await entries()
        _ = try await post("/v1/set/comment", ["address": try XCTUnwrap(all.first), "kind": "plate", "text": "Remark"])
        let project = GhidraProject(root: directory.appendingPathComponent("projects"), module: module)
        _ = try await host.publish(module, by: "agent")
        let first = try XCTUnwrap(project.state().published)
        try await Task.sleep(nanoseconds: 1_200_000_000)
        _ = try await host.publish(module, by: "agent")
        let second = try XCTUnwrap(project.state().published)
        XCTAssertEqual(second.rev, first.rev)
        XCTAssertEqual(second.at, first.at)
    }
}
