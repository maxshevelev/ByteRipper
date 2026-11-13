import CodeAnalysis
import Foundation
import XCTest
@testable import GhidraHost

/// A module that changes only the head of an entry it applied — its
/// convention, as TcgPei did for the divide in proposal a2af6661 — offers the
/// entry's own C under the new head, and the registry takes that: the C the
/// module's decompiler prints, with a temporary it cannot name and labels of
/// its own, never reaches the entry. No Ghidra: the offer is a store's.
final class LibraryEntryHeadOfferTests: XCTestCase {
    private var directory: URL!
    private var store: ContentStore!
    private let source = SHA256Digest(data: Data("the entry's module".utf8))
    private let other = SHA256Digest(data: Data("TcgPei".utf8))
    private let body = LibraryBody(size: 0x31, full: "e785b0688524a34a", specific: "84b055009bb8dc5e")

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibraryEntryHeadOffer-\(UUID().uuidString)", isDirectory: true)
        store = try ContentStore(root: directory)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func entry(convention: String, c: String) throws -> Data {
        let object: [String: Any] = [
            "schema": 1, "kind": "edk2", "name": "InternalMathDivRemU64x64",
            "body": ["size": 0x31, "full": "e785b0688524a34a", "specific": "84b055009bb8dc5e"],
            "calling_convention": convention, "return_type": "UINT64",
            "signature": "UINT64 InternalMathDivRemU64x64(UINT64 Dividend, UINT64 Divisor)",
            "params": [["ordinal": 0, "name": "Dividend", "storage": "Stack[0x4]:8", "type": "UINT64"],
                       ["ordinal": 1, "name": "Divisor", "storage": "Stack[0xc]:8", "type": "UINT64"]],
            "locals": [], "plate": "Divides.", "comments": [],
            "function": ["c": c, "c_spans": [], "entry": "0x9DFC200", "name": "InternalMathDivRemU64x64",
                         "signature": "UINT64 InternalMathDivRemU64x64(UINT64 Dividend, UINT64 Divisor)"]
        ]
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private let heldC = """

        /* WARNING: Unknown calling convention -- yet parameter storage is locked */
        /* Divides. */

        UINT64 InternalMathDivRemU64x64(UINT64 Dividend,UINT64 Divisor)

        {
          ulonglong ShiftedDividend;
          ulonglong ShiftedDivisor;
          \("")
          ShiftedDividend = Dividend;
          ShiftedDivisor = Divisor;
          if (Divisor == (UINT64 *)0x0) goto LAB_09dfc271;
          ShiftedDividend = ShiftedDividend / ShiftedDivisor;
        LAB_09dfc271:
          return ShiftedDividend;
        }


        """

    private let offeredC = """

        /* Divides. */

        UINT64 __cdecl InternalMathDivRemU64x64(UINT64 Dividend,UINT64 Divisor)

        {
          ulonglong uVar1;
          ulonglong uVar2;
          \("")
          uVar1 = Dividend;
          uVar2 = Divisor;
          if (Divisor == NULL) goto LAB_09a1a951;
          uVar1 = uVar1 / uVar2;
        LAB_09a1a951:
          return uVar1;
        }


        """

    func testAConventionOnlyChangeRecordsTheEntrysC() async throws {
        let written = try await store.writeLibraryEntries(
            module: source, rev: 1, by: "agent",
            proposals: [LibraryProposal(body: body, name: "InternalMathDivRemU64x64", kind: "edk2",
                                        address: "0x9DFC200", entry: try entry(convention: "unknown", c: heldC))],
            take: .none)
        let id = try XCTUnwrap(written.added.first?.id, "\(written)")

        let offer = LibraryProposal(body: body, name: "InternalMathDivRemU64x64", kind: "edk2", address: "0x9A1A8E0",
                                    entry: try entry(convention: "__cdecl", c: offeredC), basedOn: id, base: 1)
        let offered = try await GhidraHost.withoutLinked([offer], writer: store)
        XCTAssertEqual(offered.count, 1)

        let taken = try await store.writeLibraryEntries(
            module: other, rev: 7, by: "agent", proposals: offered,
            take: .these([id: "EFIAPI is __cdecl on IA32: the body ends in a plain RET"]))
        XCTAssertEqual(taken.updated.map(\.id), [id], "\(taken)")
        let index = try await store.readLibraryIndex()
        let held = try XCTUnwrap(index.entries[id])
        let stored = try await store.readObject(held.entry)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: stored) as? [String: Any])
        let function = try XCTUnwrap(object["function"] as? [String: Any])
        let c = try XCTUnwrap(function["c"] as? String)

        XCTAssertEqual(object["calling_convention"] as? String, "__cdecl")
        XCTAssertTrue(c.contains("UINT64 __cdecl InternalMathDivRemU64x64(UINT64 Dividend,UINT64 Divisor)"), c)
        XCTAssertFalse(c.contains("Unknown calling convention"), c)
        for kept in ["ShiftedDividend = Dividend;", "ShiftedDivisor = Divisor;", "goto LAB_09dfc271;", "(UINT64 *)0x0"] {
            XCTAssertTrue(c.contains(kept), "\(kept) is lost:\n\(c)")
        }
        for noise in ["uVar1", "uVar2", "LAB_09a1a951", "NULL"] {
            XCTAssertFalse(c.contains(noise), "\(noise) came in:\n\(c)")
        }
        // The C is still the reading of the module it came from.
        XCTAssertEqual((function["source"] as? [String: Any])?["module"] as? String, source.hex)
    }
}
