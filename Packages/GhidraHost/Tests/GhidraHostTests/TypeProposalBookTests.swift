import Foundation
import XCTest
@testable import GhidraHost

/// Agents agreeing a replacement of shared types: two agents other than the
/// author agree and none objects; an objection holds it until its author
/// votes again; one live proposal per module and per type; the author
/// withdraws; an administrator decides whatever the votes.
final class TypeProposalBookTests: XCTestCase {
    private var file: URL!
    private let module = String(repeating: "ab", count: 32)
    private let other = String(repeating: "cd", count: 32)
    private let author = TicketBook.Caller(author: "Reviewer · bench-mac", holder: "token bench-mac")
    private let first = TicketBook.Caller(author: "Verifier · bench-mac", holder: "token bench-mac")
    private let second = TicketBook.Caller(author: "Review Manager", holder: "local MCP")

    override func setUp() {
        file = FileManager.default.temporaryDirectory
            .appendingPathComponent("TypeProposalBookTests-\(UUID().uuidString)/private/type-proposals.json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: file.deletingLastPathComponent().deletingLastPathComponent())
    }

    private func draft(_ module: String, _ names: [String] = ["CUT_PPI", "_CUT_PPI"]) -> TypeProposalBook.Draft {
        .init(module: module, name: "Module", bits: "Ia32", names: names,
              moduleC: Dictionary(uniqueKeysWithValues: names.map { ($0, "ours \($0)") }),
              sharedC: Dictionary(uniqueKeysWithValues: names.map { ($0, "theirs \($0)") }), origins: [:])
    }

    private func refused(_ body: () async throws -> Void, _ words: String, status: Int = 409,
                         file: StaticString = #filePath, line: UInt = #line) async {
        do {
            try await body()
            XCTFail("not refused", file: file, line: line)
        } catch let error as GhidraHostError {
            XCTAssertEqual(error.status, status, "\(error)", file: file, line: line)
            XCTAssertTrue("\(error)".contains(words), "\(error)", file: file, line: line)
        } catch {
            XCTFail("\(error)", file: file, line: line)
        }
    }

    func testTwoOtherAgentsAgreeingWithNoObjectionAgreeIt() async throws {
        let book = TypeProposalBook(file: file)
        let proposal = try await book.propose(draft(module), reason: "Function1C is read at +0x20", by: author)
        XCTAssertEqual(proposal.state, .open)
        await refused({ _ = try await book.vote(proposal.id, choice: .agree, text: nil, by: self.author) }, "other agents vote")
        var now = try await book.vote(proposal.id, choice: .agree, text: nil, by: first)
        XCTAssertEqual(now.state, .open, "one is not enough")
        // The same agent again, by another spelling, is still one agent.
        now = try await book.vote(proposal.id, choice: .agree, text: "again",
                                  by: .init(author: "verifier · BENCH-MAC", holder: "local MCP"))
        XCTAssertEqual(now.agrees.count, 1)
        XCTAssertEqual(now.state, .open)
        now = try await book.vote(proposal.id, choice: .agree, text: nil, by: second)
        XCTAssertEqual(now.state, .agreed)
        let agreed = await book.agreed(module: module.uppercased())
        XCTAssertEqual(agreed.map(\.id), [proposal.id])
        // It outlives the book.
        let again = TypeProposalBook(file: file)
        let read = await again.proposal(proposal.id)
        XCTAssertEqual(read?.state, .agreed)
        try await again.markApplied([proposal.id], revision: 7, version: 3)
        let applied = await again.proposal(proposal.id)
        XCTAssertEqual(applied?.state, .applied)
        XCTAssertEqual(applied?.applied?.version, 3)
    }

    func testAnObjectionHoldsItUntilItsAuthorVotesAgain() async throws {
        let book = TypeProposalBook(file: file)
        let proposal = try await book.propose(draft(module), reason: "the layout the code reads", by: author)
        _ = try await book.vote(proposal.id, choice: .agree, text: nil, by: first)
        await refused({ _ = try await book.vote(proposal.id, choice: .object, text: " ", by: self.second) }, "say why",
                      status: 400)
        var now = try await book.vote(proposal.id, choice: .object, text: "PlatformStage1Pei reads +0x1C as Function1C",
                                      by: second)
        XCTAssertEqual(now.objections, ["Review Manager"])
        now = try await book.vote(proposal.id, choice: .agree, text: nil,
                                  by: .init(author: "Analyzis", holder: "local MCP"))
        XCTAssertEqual(now.state, .open, "two agree, one objects")
        now = try await book.vote(proposal.id, choice: .agree, text: "checked again: it is +0x20", by: second)
        XCTAssertEqual(now.state, .agreed)
        // An objection after the agreement takes it back before it is applied.
        now = try await book.vote(proposal.id, choice: .object, text: "no, after all", by: first)
        XCTAssertEqual(now.state, .open)
    }

    func testOneLiveProposalPerModuleAndPerTypeAndOnlyTheAuthorWithdraws() async throws {
        let book = TypeProposalBook(file: file)
        await refused({ _ = try await book.propose(self.draft(self.module), reason: "", by: self.author) }, "say why",
                      status: 400)
        await refused({ _ = try await book.propose(self.draft(self.module, []), reason: "x", by: self.author) },
                      "nothing to propose")
        let proposal = try await book.propose(draft(module), reason: "evidence", by: author)
        await refused({ _ = try await book.propose(self.draft(self.module, ["OTHER"]), reason: "x", by: self.author) },
                      proposal.id)
        await refused({ _ = try await book.propose(self.draft(self.other), reason: "x", by: self.first) }, "CUT_PPI")
        await refused({ _ = try await book.withdraw(proposal.id, note: nil, by: self.first) }, "only its author")
        let withdrawn = try await book.withdraw(proposal.id, note: "the shared one is right", by: author)
        XCTAssertEqual(withdrawn.state, .withdrawn)
        await refused({ _ = try await book.vote(proposal.id, choice: .agree, text: nil, by: self.first) }, "withdrawn")
        // The way is free again.
        let next = try await book.propose(draft(other), reason: "evidence", by: first)
        XCTAssertEqual(next.state, .open)
    }

    func testAnAdministratorDecidesWhateverTheVotes() async throws {
        let book = TypeProposalBook(file: file)
        let proposal = try await book.propose(draft(module), reason: "evidence", by: author)
        let agreed = try await book.force(proposal.id, agree: true, note: "read it myself", by: "admin")
        XCTAssertEqual(agreed.state, .agreed)
        XCTAssertEqual(agreed.decided?.forced, true)
        let other = try await book.propose(draft(self.other, ["X"]), reason: "evidence", by: first)
        let rejected = try await book.force(other.id, agree: false, note: nil, by: "admin")
        XCTAssertEqual(rejected.state, .rejected)
        await refused({ _ = try await book.force(other.id, agree: true, note: nil, by: "admin") }, "rejected already")
    }
}
