import CodeAnalysis
import Foundation
import XCTest
@testable import GhidraHost

/// A publish warns of an EDK2 function whose plate does not cite the pinned
/// tag truly, and of nothing else; with no sources configured it checks nothing.
final class GhidraHostEvidenceTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GhidraHostEvidence-\(UUID().uuidString)", isDirectory: true)
        let library = directory.appendingPathComponent("checkout/MdePkg/Library/BaseLib", isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        try Data("""
            UINTN
            EFIAPI
            AsciiStrLen (
              IN CONST CHAR8  *String
              )
            {
              return 0;
            }
            """.utf8).write(to: library.appendingPathComponent("String.c"))
        try Data("MdePkg/Library/BaseLib/String.c\n".utf8)
            .write(to: directory.appendingPathComponent("checkout/\(EDK2Evidence.listingName)"))
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func proposal(_ name: String, kind: String = "edk2", plate: String) throws -> LibraryProposal {
        let entry = try JSONSerialization.data(withJSONObject: ["name": name, "plate": plate], options: [.sortedKeys])
        return LibraryProposal(body: LibraryBody(size: 8, full: "00", specific: "01"), name: name, kind: kind,
                               address: "0x1000", entry: entry)
    }

    func testOnlyAnEDK2FunctionWhoseCitationFailsIsWarnedOf() throws {
        let checkout = directory.appendingPathComponent("checkout")
        let warnings = GhidraHost.evidenceWarnings([
            try proposal("AsciiStrLen", plate: "Length.\n\nEvidence: AsciiStrLen, MdePkg/Library/BaseLib/String.c:3."),
            try proposal("AsciiStrLenWrong", plate: "Evidence: AsciiStrLen, MdePkg/Library/BaseLib/String.c:641."),
            try proposal("LibAmdIoWrite", kind: "amd", plate: "No EDK2 here.")
        ], checkout: checkout)
        XCTAssertEqual(warnings.map(\.name), ["AsciiStrLenWrong"])
        XCTAssertEqual(warnings.first?.findings.first?.outcome, .notDefinition)
        XCTAssertEqual(warnings.first?.findings.first?.definedAt, 3)
    }

    func testNoSourcesConfiguredChecksNothing() async throws {
        let host = GhidraHost(configuration: .init(projectsRoot: directory.appendingPathComponent("projects"),
                                                   holder: "GhidraHostEvidenceTests", edk2Sources: nil),
                              writer: try ContentStore(root: directory.appendingPathComponent("store")))
        let result = await host.evidenceCheck([try proposal("AsciiStrLen", plate: "no evidence")])
        XCTAssertEqual(result.warnings, [])
        XCTAssertNil(result.unchecked)
    }

    func testTheConfiguredCheckoutIsRead() async throws {
        let host = GhidraHost(configuration: .init(projectsRoot: directory.appendingPathComponent("projects"),
                                                   holder: "GhidraHostEvidenceTests",
                                                   edk2Sources: directory.appendingPathComponent("checkout")),
                              writer: try ContentStore(root: directory.appendingPathComponent("store")))
        let result = await host.evidenceCheck([try proposal("AsciiStrLen", plate: "no evidence")])
        XCTAssertEqual(result.warnings.first?.findings.map(\.outcome), [.noEvidence])
        XCTAssertNil(result.unchecked)
    }
}

/// Issue cb568508: a proposal over seven large registry entries answered
/// 147 KB, over an agent's bound, so its author never got the id. The list,
/// a propose and a vote answer a summary — entries by id, field names and
/// sizes — and an entry's texts are read one entry at a time.
final class GhidraHostProposalViewTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GhidraHostProposalView-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    func testAnAgentReadsAProposalOfLargeEntriesASummaryAndOneEntryAtATime() async throws {
        let host = GhidraHost(configuration: .init(projectsRoot: directory.appendingPathComponent("projects"),
                                                   holder: "GhidraHostProposalViewTests",
                                                   ticketsFile: directory.appendingPathComponent("private/tickets.json"),
                                                   edk2Sources: nil),
                              writer: try ContentStore(root: directory.appendingPathComponent("store")))
        let book = try XCTUnwrap(host.typeProposals)
        let big = String(repeating: "x", count: 30_000)
        var entries: [String: TypeProposalBook.Entry] = [:]
        for index in 0..<7 {
            entries["16-\(index)"] = .init(name: "Function\(index)", proposedName: nil, heldBy: "aa", version: 2,
                                           fields: [.init(field: "plate", held: "old \(index)", offered: "new \(index)"),
                                                    .init(field: "c", held: big, offered: big)])
        }
        let module = String(repeating: "ab", count: 32)
        let draft = TypeProposalBook.Draft(module: module, name: "PeiCore", bits: "Ia32", names: [], moduleC: [:],
                                           sharedC: [:], origins: [:], entries: entries)
        let proposal = try await book.propose(draft, reason: "lines at the tag", by: .init(author: "Analyzis", holder: "local MCP"))
        func call(_ request: TypeProposalBook.Request) async throws -> Data {
            try await host.typeProposalCall(request, holder: "local MCP")
        }

        let full = try await call(.init(action: .list, module: module))
        XCTAssertGreaterThan(full.count, 7 * 60_000, "the console's view is still all of it")

        let list = try await call(.init(action: .list, module: module, view: .summary))
        XCTAssertLessThan(list.count, 8_000, String(decoding: list, as: UTF8.self))
        let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: list) as? [[String: Any]])
        XCTAssertEqual(rows.first?["id"] as? String, proposal.id)
        let row = try XCTUnwrap((rows.first?["entries"] as? [[String: Any]])?.first)
        XCTAssertEqual(row["id"] as? String, "16-0")
        XCTAssertEqual(row["fields"] as? [String], ["plate", "c"])
        XCTAssertEqual(row["bytes"] as? Int, 60_000 + 10)

        let one = try await call(.init(action: .read, id: proposal.id, view: .proposal))
        XCTAssertLessThan(one.count, 8_000)

        let entry = try await call(.init(action: .read, id: proposal.id, view: .proposal, entry: "16-3"))
        let read = try XCTUnwrap(JSONSerialization.jsonObject(with: entry) as? [String: Any])
        let fields = try XCTUnwrap((read["entry"] as? [String: Any])?["fields"] as? [[String: Any]])
        XCTAssertEqual(fields.first?["offered"] as? String, "new 3")
        XCTAssertEqual((fields.last?["held"] as? String)?.count, 30_000)
        do {
            _ = try await call(.init(action: .read, id: proposal.id, view: .proposal, entry: "16-9"))
            XCTFail("an entry the proposal has not")
        } catch let error as GhidraHostError {
            XCTAssertEqual(error.status, 404)
            XCTAssertTrue("\(error)".contains("16-0"), "\(error)")
        }
    }
}
