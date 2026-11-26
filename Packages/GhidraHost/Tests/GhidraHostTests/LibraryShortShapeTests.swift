import CodeAnalysis
import Foundation
import XCTest
@testable import GhidraHost

/// A short body whose reference sits elsewhere in another module is still a
/// candidate for the entry of its instructions (issue 33cc22d2).
final class LibraryShortShapeTests: XCTestCase {
    private typealias Row = LibraryShortShape.Row

    private func row(_ address: String, _ bytes: String, _ targets: String...) -> Row {
        Row(address: address, bytes: bytes, references: targets.map { .init(to: $0) })
    }

    /// AmdNbioGfxRNDxe's 0x128C, `MOV [RIP + 0x45B6], EDX; XOR EAX, EAX; RET`.
    private var ours: [Row] {
        [row("0x128C", "89 15 B6 45 00 00", "0x5848"), row("0x1292", "33 C0"), row("0x1294", "C3")]
    }

    /// The same three instructions in another module, the global elsewhere.
    private var theirs: [Row] {
        [row("0x2F10", "89 15 E2 31 00 00", "0x60F8"), row("0x2F16", "33 C0"), row("0x2F18", "C3")]
    }

    func testARIPRelativeDisplacementIsMasked() throws {
        XCTAssertEqual(LibraryShortShape.masked(ours[0]), "89 15 ?? ?? ?? ??")
        XCTAssertEqual(LibraryShortShape.shape(ours), LibraryShortShape.shape(theirs))
        XCTAssertNotNil(LibraryShortShape.shape(ours))
    }

    /// 32-bit code names the global by its address: `MOV [0x2A40], EAX`.
    func testAnAbsoluteAddressIsMasked() {
        let one = [row("0x1000", "A3 40 2A 00 00", "0x2A40"), row("0x1005", "C3")]
        let other = [row("0x3000", "A3 10 5C 00 00", "0x5C10"), row("0x3005", "C3")]
        XCTAssertEqual(LibraryShortShape.masked(one[0]), "A3 ?? ?? ?? ??")
        XCTAssertEqual(LibraryShortShape.shape(one), LibraryShortShape.shape(other))
        // `MOV dword ptr [0x2A40], 0x7`: the address, not the immediate.
        XCTAssertEqual(LibraryShortShape.masked(row("0x1000", "C7 05 40 2A 00 00 07 00 00 00", "0x2A40")),
                       "C7 05 ?? ?? ?? ?? 07 00 00 00")
        // A 64-bit absolute (`MOVABS RAX, [addr]`).
        XCTAssertEqual(LibraryShortShape.masked(row("0x1000", "48 A1 40 2A 00 00 01 00 00 00", "0x100002A40")),
                       "48 A1 ?? ?? ?? ?? ?? ?? ?? ??")
    }

    /// Bytes no reference encodes still tell bodies apart.
    func testOtherBytesStillDiffer() {
        let other = [row("0x2F10", "89 0D E2 31 00 00", "0x60F8"), row("0x2F16", "33 C0"), row("0x2F18", "C3")]
        XCTAssertNotEqual(LibraryShortShape.shape(ours), LibraryShortShape.shape(other))
        let immediate = [row("0x2F10", "89 15 E2 31 00 00", "0x60F8"), row("0x2F16", "B0 01"), row("0x2F18", "C3")]
        XCTAssertNotEqual(LibraryShortShape.shape(ours), LibraryShortShape.shape(immediate))
    }

    /// The function at 0x128C is offered SetDebugMask as a short candidate,
    /// and nothing links it by itself.
    func testAShortBodyOfAnotherDisplacementIsAShortCandidate() throws {
        let id = "3-c7e9606909b6a3f2-8c1f31a39edae5c2"
        let module = SHA256Digest(data: Data("Other".utf8))
        let body = LibraryBody(size: 3, full: "c7e9606909b6a3f2", specific: "8c1f31a39edae5c2")
        var index = LibraryIndex()
        index.entries[id] = LibraryIndexEntry(
            version: 1, entry: SHA256Digest(data: Data("SetDebugMask".utf8)), name: "SetDebugMask", kind: "edk2",
            source: LibrarySource(module: module, address: "0x2F10", rev: 1, by: "agent"),
            variants: [LibraryVariant(body: body, module: module)])
        index.bodies[id] = id
        let shape = try XCTUnwrap(LibraryShortShape.shape(theirs))
        let match = GhidraHost.LibraryMatch(address: "0x128C", name: "FUN_0000128c", named: false,
                                            key: "3-0123456789abcdef-fedcba9876543210", instructions: ours)
        // Before: no exact, no near, no candidate.
        XCTAssertTrue(GhidraHost.libraryPlan(GhidraHost.withShortShapes([match], entries: [:]),
                                             index: index, hashed: 1, comparisons: [:]).candidates.isEmpty)
        let matches = GhidraHost.withShortShapes([match], entries: [shape: [id]])
        XCTAssertEqual(matches.first?.near, [id])
        XCTAssertNil(matches.first?.instructions)
        let plan = GhidraHost.libraryPlan(matches, index: index, hashed: 1, comparisons: [:])
        XCTAssertEqual(plan.candidates.map(\.state), ["short_candidate"])
        XCTAssertEqual(plan.candidates.first?.id, id)
        XCTAssertTrue(plan.toApply.isEmpty)
    }
}
