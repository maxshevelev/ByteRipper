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

    /// An answered report waits on its reporter: still open, carrying the
    /// answer. Confirmed, it is resolved and leaves the open list.
    func testAnAnsweredReportWaitsOnItsReporterUntilConfirmed() async throws {
        let book = IssueBook(file: file)
        let first = try await book.report(.init(tool: "a", expected: "b"), by: "x")
        let second = try await book.report(.init(tool: "c", expected: "d"), by: "x")
        let answered = try await book.resolve(first.id, by: "admin", note: "fixed in 476")
        XCTAssertEqual(answered.resolved?.by, "admin")
        XCTAssertEqual(answered.status, .awaitingConfirmation)
        let waiting = await book.list()
        XCTAssertEqual(waiting.map(\.id), [second.id, first.id], "waiting on its reporter is still open")
        let confirmed = try await book.confirm(first.id, by: "x", works: true, note: nil)
        XCTAssertEqual(confirmed.status, .resolved)
        XCTAssertEqual(confirmed.resolved?.note, "fixed in 476", "the answer stays")
        let open = await book.list()
        let all = await book.list(all: true)
        XCTAssertEqual(open.map(\.id), [second.id])
        XCTAssertEqual(all.map(\.id), [second.id, first.id], "newest first")
        do {
            _ = try await book.resolve("nothing", by: "admin", note: "x")
            XCTFail("an unknown id")
        } catch let error as GhidraHostError {
            XCTAssertEqual(error.status, 404)
        }
        do {
            _ = try await book.resolve(second.id, by: "admin", note: "  ")
            XCTFail("a resolution with no answer")
        } catch let error as GhidraHostError {
            XCTAssertEqual(error.status, 400)
        }
    }

    /// Every step is kept with who took it, when, its note and its build;
    /// the steps the reporter reads need a note, and going back takes the
    /// answer back.
    func testEveryStatusStepIsKeptAndTheReporterFacingOnesNeedANote() async throws {
        let book = IssueBook(file: file)
        let issue = try await book.report(.init(tool: "ghidra_type", expected: "named members"), by: "token bench")
        XCTAssertEqual(issue.status, .new)
        _ = try await book.setStatus(issue.id, .investigating, by: "admin", note: nil)
        for status in [IssueBook.Status.waitingForData, .awaitingConfirmation, .noChange] {
            do {
                _ = try await book.setStatus(issue.id, status, by: "admin", note: " ")
                XCTFail("\(status) with no note")
            } catch let error as GhidraHostError {
                XCTAssertEqual(error.status, 400)
            }
        }
        _ = try await book.setStatus(issue.id, .fixing, by: "admin", note: "cause found")
        let deployed = try await book.setStatus(issue.id, .deployed, by: "admin", note: nil, build: "v0.10-705-g6533b52c")
        XCTAssertEqual(deployed.history.map(\.status), [.investigating, .fixing, .deployed])
        XCTAssertEqual(deployed.history.last?.build, "v0.10-705-g6533b52c")
        XCTAssertEqual(deployed.history.last?.by, "admin")
        let answered = try await book.setStatus(issue.id, .awaitingConfirmation, by: "admin", note: "fixed in 705")
        XCTAssertEqual(answered.resolved?.note, "fixed in 705")
        let back = try await book.setStatus(issue.id, .fixing, by: "admin", note: "not yet")
        XCTAssertNil(back.resolved, "taken up again, the answer is taken back")
        let reread = await IssueBook(file: file).list(all: true)
        XCTAssertEqual(reread.first?.history.count, 5, "kept across a restart")
    }

    /// Only the reporter confirms, and only a report waiting on it; a fix
    /// that does not work goes back to the maintainers with why.
    func testOnlyTheReporterConfirmsAndAFailedFixGoesBack() async throws {
        let book = IssueBook(file: file)
        let issue = try await book.report(.init(tool: "ghidra_publish", expected: "no conflict"), by: "token bench")
        func refused(_ status: Int, _ run: () async throws -> Void) async {
            do {
                try await run()
                XCTFail("taken")
            } catch let error as GhidraHostError {
                XCTAssertEqual(error.status, status, error.message)
            } catch {
                XCTFail("\(error)")
            }
        }
        await refused(409) { _ = try await book.confirm(issue.id, by: "token bench", works: true, note: nil) }
        _ = try await book.resolve(issue.id, by: "admin", note: "fixed in 705")
        await refused(403) { _ = try await book.confirm(issue.id, by: "token other", works: true, note: nil) }
        await refused(400) { _ = try await book.confirm(issue.id, by: "token bench", works: false, note: nil) }
        let back = try await book.confirm(issue.id, by: "token bench", works: false, note: "still refused on Tcg2Pei")
        XCTAssertEqual(back.status, .investigating)
        XCTAssertNil(back.resolved)
        XCTAssertEqual(back.history.last?.by, "token bench")
        XCTAssertEqual(back.history.last?.note, "still refused on Tcg2Pei")
    }

    /// A file from before statuses reads: an answered report as resolved,
    /// any other as new.
    func testAReportFromBeforeStatusesReads() async throws {
        let old = """
            [{"at":"2026-11-17T23:43:22Z","expected":"x","id":"aaaa0001","reporter":"local MCP","tool":"t"},
             {"at":"2026-11-17T23:43:23Z","expected":"y","id":"aaaa0002","reporter":"local MCP","tool":"t",
              "resolved":{"at":"2026-11-18T00:00:00Z","by":"console","note":"fixed"}}]
            """
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(old.utf8).write(to: file)
        let all = await IssueBook(file: file).list(all: true)
        XCTAssertEqual(all.map(\.status), [.resolved, .new])
        XCTAssertEqual(all.map(\.history.count), [0, 0])
        let open = await IssueBook(file: file).list()
        XCTAssertEqual(open.map(\.id), ["aaaa0001"])
    }

    func testAReporterReadsItsOwnReportsWithTheirAnswers() async throws {
        let book = IssueBook(file: file)
        let mine = try await book.report(.init(tool: "a", expected: "b"), by: "token bench")
        _ = try await book.report(.init(tool: "c", expected: "d"), by: "token other")
        let later = try await book.report(.init(tool: "e", expected: "f"), by: "token bench")
        _ = try await book.resolve(mine.id, by: "console", note: "fixed in 478")
        let read = await book.mine("token bench")
        XCTAssertEqual(read.map(\.id), [later.id, mine.id], "its own, newest first, open and resolved")
        XCTAssertEqual(read.last?.resolved?.note, "fixed in 478")
        let one = await book.mine("token bench", limit: 1)
        XCTAssertEqual(one.map(\.id), [later.id])
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

    /// The reporter confirms through the tool, as the host's own holder.
    func testTheConfirmToolConfirmsAsItsHolder() async throws {
        let host = GhidraHost(configuration: .init(projectsRoot: file.deletingLastPathComponent(), holder: "local MCP",
                                                   issuesFile: file),
                              writer: try ContentStore(root: file.deletingLastPathComponent().appendingPathComponent("store")))
        let book = try XCTUnwrap(host.issues)
        let issue = try await book.report(.init(tool: "ghidra_publish", expected: "no conflict"), by: "local MCP")
        _ = try await book.resolve(issue.id, by: "console", note: "fixed in 705")
        let tool = try XCTUnwrap(GhidraTools.tools(backend: host).first { $0.name == "ghidra_issue_confirm" })
        do {
            _ = try await tool.run(AgentCall(tool: tool.name, arguments: AgentArguments(["id": .string(issue.id)])))
            XCTFail("no works")
        } catch let error as AgentToolError {
            XCTAssertTrue(error.message.contains("works"), error.message)
        }
        let answer = try await tool.run(AgentCall(tool: tool.name, arguments: AgentArguments([
            "id": .string(issue.id), "works": .bool(true)])))
        guard case .json(let value) = answer else { return XCTFail("\(answer)") }
        XCTAssertEqual(value["status"], "resolved")
    }
}
