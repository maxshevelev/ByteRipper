import CodeAnalysis
import Foundation
import XCTest
@testable import GhidraHost

/// A frame slot the decompiler keeps no name on (issue 025eb415).
///
/// `IdeBusPei`'s ResetDevice (0x1774) copies IDE_BASE_REGISTERS by value onto
/// the outgoing stack with REP MOVSD, and once a review has typed the frame,
/// the decompiler reads the copy's first dwords as ECX left by the Stall call:
/// `UVar1`, `UVar2`. A rename of either is refused — the C keeps printing the
/// placeholder — so the review can only explain them in a comment. Such a
/// slot is the decompiler's piece from then on, in the leftovers and in the
/// export's review gaps alike, not a local the review left unnamed.
///
/// The state takes a review's typing of the frame to reach, so the test runs
/// on a copy of a reviewed project: `GHIDRA_REVIEWED_PROJECTS` is a folder
/// holding IdeBusPei's project folder and the review type archive beside it,
/// as `GhidraProjects` holds them. The copy is used up by the test.
final class GhidraOwnerRefusedNameTests: XCTestCase {
    private func json(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func body(_ object: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: object) }

    func testAFrameSlotTheDecompilerKeepsNoNameOnIsItsPiece() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["GHIDRA_BYVALUE_MODULE"], let projects = environment["GHIDRA_REVIEWED_PROJECTS"] else {
            throw XCTSkip("GHIDRA_BYVALUE_MODULE or GHIDRA_REVIEWED_PROJECTS is not set")
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GhidraOwnerRefusedNameTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ContentStore(root: directory.appendingPathComponent("store"))
        let host = GhidraHost(configuration: .init(projectsRoot: URL(fileURLWithPath: projects),
                                                   idle: 300, holder: "GhidraOwnerRefusedNameTests",
                                                   ticketsFile: directory.appendingPathComponent("private/tickets.json")),
                              writer: store)
        let image = try Data(contentsOf: URL(fileURLWithPath: path))
        let module = SHA256Digest(data: image)
        _ = try await host.createCached(module: image, name: "IdeBusPei")
        try await host.take(module)
        defer { Task { await host.stop(module) } }

        let entry = "0x1774"
        let before = try json(await host.read(module, "/v1/function/\(entry)"))
        let slots = (before["locals"] as? [[String: Any]] ?? []).filter { local in
            (local["named"] as? Bool) == false && (local["storage"] as? String ?? "").hasPrefix("Stack[-")
                && local["first_use"] is String
        }
        XCTAssertFalse(slots.isEmpty, "the premise: unnamed frame slots in \(entry), \(before["locals"] ?? [])")
        XCTAssertNotNil((before["leftovers"] as? [String: Any])?["locals"], "the premise: they are left to name")

        for slot in slots {
            do {
                _ = try await host.write(module, "/v1/rename/variable", body: body([
                    "function": entry, "storage": slot["storage"] as Any, "first_use": slot["first_use"] as Any,
                    "name": "OutRegsCopy\(slots.firstIndex { $0["storage"] as? String == slot["storage"] as? String } ?? 0)"
                ]))
                XCTFail("the decompiler took a name on \(slot) after all: this test no longer shows the case")
            } catch {
                XCTAssertTrue("\(error)".contains("did not keep the name"), "\(error)")
            }
        }

        let after = try json(await host.read(module, "/v1/function/\(entry)"))
        let leftovers = after["leftovers"] as? [String: Any] ?? [:]
        XCTAssertNil(leftovers["locals"], "a slot that keeps no name is not a local left to name: \(leftovers)")
        let pieces = leftovers["fragment_names"] as? [String] ?? []
        for slot in slots {
            XCTAssertTrue(pieces.contains(slot["name"] as? String ?? ""), "\(slot["name"] ?? "") is the decompiler's piece: \(pieces)")
        }

        // The export records the same: no `locals` gap at the publish.
        _ = try await host.publish(module, by: "agent")
        let manifest = try XCTUnwrap(try store.analysis(module: module))
        let list = try json(try store.object(manifest.artifact.sha256))["functions"] as? [[String: Any]] ?? []
        let row = try XCTUnwrap(list.first { $0["entry"] as? String == entry })
        XCTAssertFalse((row["review_gaps"] as? [String] ?? []).contains("locals"), "\(row["review_gaps"] ?? [])")
    }
}
