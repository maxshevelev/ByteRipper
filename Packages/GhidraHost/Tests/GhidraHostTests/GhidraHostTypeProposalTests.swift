import CodeAnalysis
import Foundation
import XCTest
@testable import GhidraHost

/// A replacement of a shared type agreed by agents: the module's holder
/// proposes, two other agents agree, and the module's next publish replaces
/// the shared type — not when the module's definition moved since — and the
/// module that wrote the shared copy is told on its ticket.
final class GhidraHostTypeProposalTests: XCTestCase {
    private func json(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testAnAgreedProposalIsAppliedByTheModulesNextPublish() async throws {
        guard let paths = ProcessInfo.processInfo.environment["GHIDRA_LIBRARY_MODULES"]?.split(separator: ":"),
              paths.count >= 2 else {
            throw XCTSkip("GHIDRA_LIBRARY_MODULES is not set to two modules")
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GhidraHostTypeProposalTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ContentStore(root: directory.appendingPathComponent("store"))
        let holder = "GhidraHostTypeProposalTests"
        let host = GhidraHost(configuration: .init(projectsRoot: directory.appendingPathComponent("projects"), idle: 300,
                                                   holder: holder,
                                                   ticketsFile: directory.appendingPathComponent("private/tickets.json")),
                              writer: store)
        let first = try Data(contentsOf: URL(fileURLWithPath: String(paths[0])))
        let second = try Data(contentsOf: URL(fileURLWithPath: String(paths[1])))
        let writer = SHA256Digest(data: first), proposer = SHA256Digest(data: second)
        _ = try await host.createCached(module: first, name: "Writer")
        _ = try await host.createCached(module: second, name: "Proposer")
        defer { Task { await host.stop(writer); await host.stop(proposer) } }
        func define(_ module: SHA256Digest, _ c: String) async throws {
            try await host.take(module)
            _ = try await host.write(module, "/v1/type", body: try JSONSerialization.data(withJSONObject: ["c": c]))
        }
        func call(_ request: TypeProposalBook.Request) async throws -> [String: Any] {
            try json(await host.typeProposalCall(request, holder: holder))
        }

        try await define(writer, "typedef struct _VOTE_PPI { unsigned int Size; void *Run; } VOTE_PPI;")
        _ = try await host.publish(writer, by: "agent")
        let proposed = "typedef struct _VOTE_PPI { unsigned int Size; unsigned int Flags; void *Run; } VOTE_PPI;"
        try await define(proposer, proposed)
        do {
            _ = try await host.publish(proposer, by: "agent")
            XCTFail("a replacement is refused")
        } catch let error as GhidraHostError {
            XCTAssertTrue("\(error)".contains("ghidra_type_propose"), "\(error)")
        }

        let proposal = try await call(.init(action: .propose, agent: "Reviewer", module: proposer.hex,
                                            reason: "Run is called through +0x08"))
        let id = try XCTUnwrap(proposal["id"] as? String)
        XCTAssertEqual(Set(proposal["names"] as? [String] ?? []), ["VOTE_PPI", "_VOTE_PPI"], "\(proposal)")
        XCTAssertTrue(((proposal["module_c"] as? [String: String])?["VOTE_PPI"] ?? "").contains("Flags"), "\(proposal)")
        XCTAssertFalse(((proposal["shared_c"] as? [String: String])?["VOTE_PPI"] ?? "").contains("Flags"), "\(proposal)")
        _ = try await call(.init(action: .vote, agent: "Verifier", id: id, choice: .agree))
        let agreed = try await call(.init(action: .vote, agent: "Review Manager", id: id, choice: .agree))
        XCTAssertEqual(agreed["state"] as? String, "agreed")

        // The module's definition moved after the vote: not what was agreed.
        try await define(proposer, "typedef struct _VOTE_PPI { unsigned int Size; unsigned int Mode; void *Run; } VOTE_PPI;")
        do {
            _ = try await host.publish(proposer, by: "agent")
            XCTFail("a definition other than the agreed one is refused")
        } catch let error as GhidraHostError {
            XCTAssertEqual(error.status, 409, "\(error)")
        }

        try await define(proposer, proposed)
        // The dry run decides as the publish does: the agreed proposal, not a refusal.
        let preview = try json(await host.preview(proposer))
        XCTAssertEqual(preview["types_agreed"] as? [String], [id], "\(preview)")
        XCTAssertNil(preview["types_refused"], "\(preview)")
        let published = try await host.publish(proposer, by: "agent")
        XCTAssertTrue(published.typeConflictsTaken.contains("VOTE_PPI"), "\(published.typeConflictsTaken)")
        let shared = try json(await host.read(writer, "/v1/type?name=VOTE_PPI"))["shared"] as? [String: Any]
        XCTAssertTrue((shared?["c"] as? String ?? "").contains("Flags"), "\(String(describing: shared))")
        let applied = try await call(.init(action: .read, id: id))
        XCTAssertEqual(applied["state"] as? String, "applied")
        XCTAssertNotNil((applied["applied"] as? [String: Any])?["version"], "\(applied)")

        // The module that wrote the shared copy reads it on its ticket.
        var remark: TicketBook.Remark?
        for _ in 0..<60 {
            remark = await host.tickets?.ticket(writer.hex)?.remarks.first
            if remark != nil { break }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        let told = try XCTUnwrap(remark, "the writer's ticket has no remark")
        XCTAssertTrue(told.text.contains("VOTE_PPI") && told.text.contains(id), told.text)
        let own = await host.tickets?.ticket(proposer.hex)?.remarks.first
        XCTAssertNil(own, "the proposer is not told of its own")
    }
}
