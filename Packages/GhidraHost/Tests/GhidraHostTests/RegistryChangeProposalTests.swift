import CodeAnalysis
import Foundation
import XCTest
@testable import GhidraHost

/// A change of the registry itself — an entry taken out, a body restored or
/// split off — is a proposal like a replacement: voted, or decided by an
/// administrator, and applied by the server the moment it is agreed.
final class RegistryChangeProposalTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RegistryChangeProposalTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testAnAgreedChangeIsAppliedAtOnceAndARefusedOneIsNotProposed() async throws {
        let store = try ContentStore(root: directory.appendingPathComponent("store"))
        let holder = "RegistryChangeProposalTests"
        let host = GhidraHost(configuration: .init(projectsRoot: directory.appendingPathComponent("projects"),
                                                   holder: holder,
                                                   ticketsFile: directory.appendingPathComponent("private/tickets.json")),
                              writer: store)
        let body = LibraryBody(size: 0x15, full: "00112233445566aa", specific: "0123456789abcdef")
        let entry = try JSONSerialization.data(withJSONObject: ["schema": 1, "name": "SetMem", "kind": "edk2"],
                                               options: .sortedKeys)
        let module = SHA256Digest(data: Data("module".utf8))
        let id = try XCTUnwrap(try store.putLibraryEntries(
            module: module, rev: 1, by: "agent",
            proposals: [LibraryProposal(body: body, name: "SetMem", kind: "edk2", address: "0x1000", entry: entry)])
            .added.first?.id)
        func call(_ request: TypeProposalBook.Request) async throws -> [String: Any] {
            let data = try await host.typeProposalCall(request, holder: holder)
            return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        }

        // What the registry would refuse is not proposed.
        do {
            _ = try await call(.init(action: .propose, agent: "Reviewer", module: module.hex, reason: "wrong",
                                     change: LibraryChange(action: .restore, body: body.key)))
            XCTFail("a restore of a body that was never taken out was proposed")
        } catch {}
        do {
            _ = try await call(.init(action: .propose, agent: "Reviewer", module: module.hex, reason: "a source",
                                     change: LibraryChange(action: .cite, id: id, file: "a.c", line: 1)))
            XCTFail("a citation went to a vote")
        } catch {
            XCTAssertTrue("\(error)".contains("ghidra_library_cite"), "\(error)")
        }

        // Proposed, nothing moves; two agents agree, and it is applied at once.
        let proposed = try await call(.init(action: .propose, agent: "Reviewer", module: module.hex,
                                            reason: "it reads the module's own data",
                                            change: LibraryChange(action: .takeOut, id: id)))
        let first = try XCTUnwrap(proposed["id"] as? String)
        XCTAssertEqual(proposed["state"] as? String, "open")
        XCTAssertEqual((proposed["change"] as? [String: Any])?["action"] as? String, "take_out")
        XCTAssertNotNil(try store.libraryIndex().entries[id])
        do {
            _ = try await call(.init(action: .propose, agent: "Other", module: module.hex, reason: "again",
                                     change: LibraryChange(action: .takeOut, id: id)))
            XCTFail("a second live change of the same entry")
        } catch {
            XCTAssertTrue("\(error)".contains(first), "\(error)")
        }
        _ = try await call(.init(action: .vote, agent: "Verifier", id: first, choice: .agree))
        XCTAssertNotNil(try store.libraryIndex().entries[id], "one agreement is not enough")
        let agreed = try await call(.init(action: .vote, agent: "Review Manager", id: first, choice: .agree))
        XCTAssertEqual(agreed["state"] as? String, "applied")
        XCTAssertNil(try store.libraryIndex().entries[id])

        // An administrator's decision applies a change the same way.
        let back = try await call(.init(action: .propose, agent: "Reviewer", module: module.hex,
                                        reason: "the data is a constant of the library",
                                        change: LibraryChange(action: .restore, body: body.key)))
        let decided = try await host.decideProposal(try XCTUnwrap(back["id"] as? String), agree: true,
                                                    note: "read it", by: "admin")
        XCTAssertEqual(decided.state, .applied)
        XCTAssertNotNil(try store.libraryIndex().entries[id])
    }
}
