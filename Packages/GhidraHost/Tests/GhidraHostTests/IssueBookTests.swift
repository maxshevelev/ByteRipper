import AgentKit
import CodeAnalysis
import Foundation
import XCTest
@testable import GhidraHost

/// Agents' reports about the tools: kept across a restart, cut and not
/// refused when long, resolved with a note, and reachable as a tool.
final class IssueBookTests: XCTestCase {
    private var file: URL!

    override func setUp() {
        file = FileManager.default.temporaryDirectory
            .appendingPathComponent("IssueBookTests-\(UUID().uuidString)/private/issues.json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: file.deletingLastPathComponent().deletingLastPathComponent())
    }

    func testAReportIsKeptWithItsReporterAndOutlivesTheBook() async throws {
        let book = IssueBook(file: file)
        let kept = try await book.report(.init(tool: "ghidra_rename_variable", arguments: #"{"name":"Idtr"}"#,
                                               answer: "ok, stale: true", expected: "no stale flag",
                                               module: "a4cc4a55", note: "read back right"), by: "token bench-mac")
        XCTAssertEqual(kept.reporter, "token bench-mac")
        XCTAssertEqual(kept.id.count, 8)
        let again = IssueBook(file: file)
        let listed = await again.list()
        XCTAssertEqual(listed, [kept])
    }

    func testAReportNamesTheToolAndWhatWasExpected() async {
        let book = IssueBook(file: file)
        for report in [IssueBook.Report(tool: " ", expected: "x"), IssueBook.Report(tool: "ghidra_type", expected: "")] {
            do {
                _ = try await book.report(report, by: "x")
                XCTFail("\(report) was taken")
            } catch let error as GhidraHostError {
                XCTAssertEqual(error.status, 400)
            } catch {
                XCTFail("\(error)")
            }
        }
    }

    func testALongAnswerIsCutNotRefused() async throws {
        let book = IssueBook(file: file)
        let long = String(repeating: "ж", count: IssueBook.textLimit)
        let kept = try await book.report(.init(tool: "ghidra_function", answer: long, expected: "C"), by: "x")
        let answer = try XCTUnwrap(kept.answer)
        XCTAssertLessThan(answer.utf8.count, IssueBook.textLimit + 64)
        XCTAssertTrue(answer.hasSuffix("(cut at \(IssueBook.textLimit) bytes)"))
    }

    func testAResolvedReportLeavesTheOpenListAndKeepsItsNote() async throws {
        let book = IssueBook(file: file)
        let first = try await book.report(.init(tool: "a", expected: "b"), by: "x")
        let second = try await book.report(.init(tool: "c", expected: "d"), by: "x")
        let resolved = try await book.resolve(first.id, by: "admin", note: "fixed in 476")
        XCTAssertEqual(resolved.resolved?.by, "admin")
        let open = await book.list()
        let all = await book.list(all: true)
        XCTAssertEqual(open.map(\.id), [second.id])
        XCTAssertEqual(all.map(\.id), [second.id, first.id], "newest first")
        do {
            _ = try await book.resolve("nothing", by: "admin", note: nil)
            XCTFail("an unknown id")
        } catch let error as GhidraHostError {
            XCTAssertEqual(error.status, 404)
        }
    }

    func testTheToolReportsThroughItsBackendAndSaysWhenThereIsNoServer() async throws {
        let host = GhidraHost(configuration: .init(projectsRoot: file.deletingLastPathComponent(), holder: "local MCP",
                                                   issuesFile: file),
                              writer: try ContentStore(root: file.deletingLastPathComponent().appendingPathComponent("store")))
        let tool = try XCTUnwrap(GhidraTools.tools(backend: host).first { $0.name == "ghidra_report_issue" })
        let answer = try await tool.run(AgentCall(tool: tool.name, arguments: AgentArguments([
            "tool": "ghidra_equate", "expected": "the name in the C", "module": "a4cc4a55"])))
        guard case .json(let value) = answer else { return XCTFail("\(answer)") }
        XCTAssertEqual(value["reporter"], "local MCP")
        let listed = await host.issues?.list()
        XCTAssertEqual(listed?.first?.tool, "ghidra_equate")

        let none = GhidraHost(configuration: .init(projectsRoot: file.deletingLastPathComponent()),
                              writer: try ContentStore(root: file.deletingLastPathComponent().appendingPathComponent("store2")))
        let refusing = try XCTUnwrap(GhidraTools.tools(backend: none).first { $0.name == "ghidra_report_issue" })
        do {
            _ = try await refusing.run(AgentCall(tool: refusing.name, arguments: AgentArguments([
                "tool": "x", "expected": "y"])))
            XCTFail("a host without reports")
        } catch let error as AgentToolError {
            XCTAssertTrue(error.message.contains("Tell the person"), error.message)
        }
    }
}
