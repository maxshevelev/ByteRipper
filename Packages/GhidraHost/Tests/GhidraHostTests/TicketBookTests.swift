import Foundation
import XCTest
@testable import GhidraHost

/// The review board: one ticket per module, remarks with their own authors,
/// closed only by a verifier other than the reviewer and only with nothing
/// left open, opened again by a new remark, and overruled by an administrator.
final class TicketBookTests: XCTestCase {
    private var file: URL!
    private let module = String(repeating: "ab", count: 32)
    private let reviewer = TicketBook.Caller(author: "Reviewer · devex-macbook", holder: "token devex-macbook")
    private let verifier = TicketBook.Caller(author: "Verifier · devex-macbook", holder: "token devex-macbook")
    private let reviewManager = TicketBook.Caller(author: "Review Manager", holder: "local MCP")

    override func setUp() {
        file = FileManager.default.temporaryDirectory
            .appendingPathComponent("TicketBookTests-\(UUID().uuidString)/private/tickets.json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: file.deletingLastPathComponent().deletingLastPathComponent())
    }

    func testRemarksFromTwoAuthorsShareTheModulesOneTicketAndOutliveTheBook() async throws {
        let book = TicketBook(file: file)
        _ = try await book.add(.init(severity: .wrong, text: "the plate says EFI_NOT_FOUND, the code returns 0x0E",
                                     function: "ReadPolicy", address: "0x9A01234", revision: 3),
                               module: module, name: "TcgPei", reviewer: reviewer.author, by: verifier)
        let ticket = try await book.add(.init(severity: .cosmetic, text: "typo in the plate"),
                                        module: module.uppercased(), name: nil, reviewer: nil, by: reviewManager)
        XCTAssertEqual(ticket.remarks.map(\.author), ["Verifier · devex-macbook", "Review Manager"])
        XCTAssertEqual(ticket.name, "TcgPei")
        XCTAssertEqual(ticket.state, "open")
        let again = await TicketBook(file: file).ticket(module)
        XCTAssertEqual(again, ticket)
    }

    func testTheTicketClosesOnlyWithNothingLeftOpenAndNotByTheReviewer() async throws {
        let book = TicketBook(file: file)
        var ticket = try await book.add(.init(severity: .wrong, text: "wrong offset"), module: module, name: "TcgPei",
                                        reviewer: reviewer.author, by: verifier)
        let id = try XCTUnwrap(ticket.remarks.first?.id)
        await assertRefused(409) { _ = try await book.close(module: self.module, name: nil, reviewer: nil, note: nil, by: self.verifier) }

        ticket = try await book.reply(module: module, remark: id, text: "retyped", status: .fixed, revision: 4, by: reviewer)
        XCTAssertEqual(ticket.remarks[0].status, .fixed)
        await assertRefused(409, "a fix is not yet verified") {
            _ = try await book.close(module: self.module, name: nil, reviewer: nil, note: nil, by: self.verifier)
        }
        await assertRefused(409, "the reviewer verifies its own fix") {
            _ = try await book.reply(module: self.module, remark: id, text: nil, status: .verified, revision: nil, by: self.reviewer)
        }
        ticket = try await book.reply(module: module, remark: id, text: "reads right in rev 4", status: .verified,
                                      revision: nil, by: verifier)
        XCTAssertEqual(ticket.state, "settled")
        await assertRefused(409, "the reviewer closes its own ticket") {
            _ = try await book.close(module: self.module, name: nil, reviewer: nil, note: nil, by: self.reviewer)
        }
        ticket = try await book.close(module: module, name: nil, reviewer: nil, note: "all verified", by: verifier)
        XCTAssertEqual(ticket.state, "closed")
        XCTAssertEqual(ticket.closed?.by, "Verifier · devex-macbook")
        XCTAssertEqual(ticket.remarks[0].thread.map(\.status), [.fixed, .verified])
    }

    func testANewRemarkOpensAClosedModuleAgain() async throws {
        let book = TicketBook(file: file)
        var ticket = try await book.close(module: module, name: "DebugMaskPei", reviewer: reviewer.author,
                                          note: "checked, nothing found", by: reviewManager)
        XCTAssertEqual(ticket.state, "closed")
        XCTAssertTrue(ticket.remarks.isEmpty)
        ticket = try await book.add(.init(severity: .misleading, text: "a later check: the loop bound is off by one"),
                                    module: module, name: nil, reviewer: nil, by: reviewManager)
        XCTAssertNil(ticket.closed)
        XCTAssertEqual(ticket.state, "open")
        XCTAssertEqual(ticket.reviewer, reviewer.author, "the reviewer the closing knew is kept")
    }

    func testADeclineOrAnAnswerSaysWhyAndEveryCallNamesItsAgent() async throws {
        let book = TicketBook(file: file)
        let ticket = try await book.add(.init(severity: .cosmetic, text: "x"), module: module, name: nil,
                                        reviewer: reviewer.author, by: verifier)
        let id = ticket.remarks[0].id
        await assertRefused(400) {
            _ = try await book.reply(module: self.module, remark: id, text: " ", status: .wontfix, revision: nil, by: self.reviewer)
        }
        await assertRefused(400) {
            _ = try await book.add(.init(severity: .wrong, text: "y"), module: self.module, name: nil, reviewer: nil,
                                   by: .init(author: " ", holder: "local MCP"))
        }
        await assertRefused(400) {
            _ = try await book.add(.init(severity: .wrong, text: "y"), module: "TcgPei", name: nil, reviewer: nil, by: self.verifier)
        }
        await assertRefused(404) {
            _ = try await book.reply(module: self.module, remark: "nothere", text: "z", status: nil, revision: nil, by: self.verifier)
        }
    }

    func testTheReviewerTakingTheModuleIsWhoCannotClose() async throws {
        let book = TicketBook(file: file)
        _ = try await book.add(.init(severity: .cosmetic, text: "x"), module: module, name: nil, reviewer: nil, by: reviewManager)
        try await book.noteReviewer(module, name: "TcgPei", author: "Analyzis")
        let ticket = try await book.ticket(module).map { $0 }
        XCTAssertEqual(ticket?.reviewer, "Analyzis")
        let other = String(repeating: "cd", count: 32)
        try await book.noteReviewer(other, name: "DxeCore", author: "Reviewer · devex-macbook")
        let unlisted = await book.list()
        XCTAssertEqual(unlisted.map(\.module), [module], "a ticket that only knows its reviewer is listed nowhere")
        let later = try await book.add(.init(severity: .wrong, text: "z"), module: other, name: nil, reviewer: nil, by: reviewManager)
        XCTAssertEqual(later.reviewer, "Reviewer · devex-macbook", "the reviewer noted before the first remark")
        let id = try XCTUnwrap(ticket?.remarks.first?.id)
        _ = try await book.reply(module: module, remark: id, text: "ok", status: .verified, revision: nil, by: reviewManager)
        await assertRefused(409) {
            _ = try await book.close(module: self.module, name: nil, reviewer: nil, note: nil,
                                     by: .init(author: "analyzis", holder: "local MCP"))
        }
        let closed = try await book.close(module: module, name: nil, reviewer: nil, note: nil, by: reviewManager)
        XCTAssertEqual(closed.state, "closed")
    }

    func testAnAdministratorSetsAnyStatusAndClosesWhateverTheRemarksHold() async throws {
        let book = TicketBook(file: file)
        let ticket = try await book.add(.init(severity: .wrong, text: "x"), module: module, name: nil,
                                        reviewer: reviewer.author, by: verifier)
        var forced = try await book.force(module: module, remark: nil, status: nil, close: true, note: "out of scope", by: "admin")
        XCTAssertEqual(forced.state, "closed")
        XCTAssertEqual(forced.closed?.forced, true)
        forced = try await book.force(module: module, remark: ticket.remarks[0].id, status: .open, close: nil,
                                      note: "still wrong", by: "admin")
        XCTAssertEqual(forced.state, "open", "an open remark opens the ticket again")
        let listed = await book.list(state: "open", author: "verifier · devex-macbook")
        XCTAssertEqual(listed.map(\.module), [module])
        let none = await book.list(state: "closed")
        XCTAssertEqual(none, [])
    }

    private func assertRefused(_ status: Int, _ message: String = "", file: StaticString = #filePath, line: UInt = #line,
                               _ body: () async throws -> Void) async {
        do {
            try await body()
            XCTFail("taken: \(message)", file: file, line: line)
        } catch let error as GhidraHostError {
            XCTAssertEqual(error.status, status, "\(message): \(error)", file: file, line: line)
        } catch {
            XCTFail("\(error)", file: file, line: line)
        }
    }
}
