import AgentKit
import MEFirmware
import MEPresentation
import XCTest
@testable import MEATool

/// How `me_files_compare` words a comparison, and how a byte comparison's run
/// is placed at the one ME file it touches.
@MainActor
final class MEAAgentFilesTests: XCTestCase {
    private func side(_ extents: [Range<Int>], size: Int = 0x40) -> MEFileComparison.Side {
        MEFileComparison.Side(storedSize: size, contentSize: size, extents: extents,
                              contentDigest: nil, integrity: nil, complete: true)
    }

    private func row(_ key: Int, _ status: MEFileComparison.Status, name: String? = nil,
                     moved: Bool = false, rewritten: Bool? = nil, differing: Int? = nil) -> MEFileComparison.Row {
        MEFileComparison.Row(volume: .mfs, key: key, name: name, status: status,
                             a: status == .onlyInB ? nil : side([0x100..<0x140]),
                             b: status == .onlyInA ? nil : side([0x200..<0x240]),
                             moved: moved, differingBytes: differing, integrityDiffers: rewritten)
    }

    private func page(after: String? = nil) throws -> AgentPage {
        try AgentPage(AgentArguments(after.map { ["after": .string($0)] } ?? [:]), fingerprint: "f")
    }

    /// A file with more stretches than one answer holds keeps the first of
    /// them, says how many there are, and is marked.
    func testAFileTooLargeForOneAnswerKeepsItsFirstStretches() throws {
        let many = (0..<2000).map { 0x1000 + $0 * 0x42..<0x1040 + $0 * 0x42 }
        var row = row(4, .different)
        row.a = side(many, size: many.count * 0x40)
        let answer = try MEAAgentFiles.answer(MEFileComparison(rows: [row], gaps: []), volume: nil, name: nil,
                                              extents: true, limit: 40, page: page(), bound: 24 << 10)
        let item = try XCTUnwrap(answer["different"]?.arrayValue?.first)
        XCTAssertEqual(item["truncated"], "item")
        XCTAssertEqual(item["extents"]?["document"]?.arrayValue?.count, MEAAgentFiles.extentsShortened)
        XCTAssertEqual(item["extents"]?["document_total"], 2000)
        XCTAssertLessThanOrEqual(answer.encoded().count, 24 << 10)
    }

    func testTheAnswerCountsMovedAndRewrittenFilesAmongTheSame() throws {
        let comparison = MEFileComparison(rows: [
            row(1, .same, moved: true), row(2, .same, rewritten: true), row(3, .same),
            row(4, .different, name: "/home/mca/eom", rewritten: true, differing: 3),
            row(5, .onlyInA), row(6, .onlyInB),
        ], gaps: [MEFileComparison.Gap(volume: .efs, inA: false, reason: .unreadable)])
        let answer = try MEAAgentFiles.answer(comparison, volume: nil, name: nil, extents: false, limit: 40,
                                              page: page(), bound: 24 << 10)
        XCTAssertEqual(answer["counts"], [
            "same": 3, "moved": 1, "rewritten": 1, "different": 1,
            "only_in_document": 1, "only_in_against": 1,
        ])
        let different: JSONValue = [[
            "volume": "mfs", "index": 4, "name": "/home/mca/eom",
            "size": ["document": "0x40", "against": "0x40"] as JSONValue,
            "differing_bytes": 3, "integrity_differs": true,
        ] as JSONValue]
        XCTAssertEqual(answer["different"], different)
        XCTAssertEqual(answer["not_compared"], [[
            "volume": "efs", "in": "against",
            "reason": "The EFS partition holds no volume that could be read; its System page may be erased.",
        ]])
        XCTAssertEqual(answer["next"], .null)
    }

    func testExtentsAreGivenOnlyWhenAskedFor() throws {
        let comparison = MEFileComparison(rows: [row(4, .different)], gaps: [])
        let plain = try MEAAgentFiles.answer(comparison, volume: nil, name: nil, extents: false, limit: 40,
                                             page: page(), bound: 24 << 10)
        XCTAssertNil(plain["different"]?.arrayValue?.first?["extents"])
        let placed = try MEAAgentFiles.answer(comparison, volume: nil, name: nil, extents: true, limit: 40,
                                              page: page(), bound: 24 << 10)
        XCTAssertEqual(placed["different"]?.arrayValue?.first?["extents"], [
            "document": [["start": "0x100", "end": "0x140"]],
            "against": [["start": "0x200", "end": "0x240"]],
        ])
    }

    func testTheListsAreNarrowedAndCut() throws {
        let comparison = MEFileComparison(rows: [
            row(1, .different, name: "/home/a"), row(2, .different, name: "/home/b"),
            row(3, .different, name: "/fpf/c"),
        ], gaps: [])
        let narrowed = try MEAAgentFiles.answer(comparison, volume: nil, name: "HOME", extents: false, limit: 40,
                                                page: page(), bound: 24 << 10)
        XCTAssertEqual(narrowed["counts"]?["different"], 2)
        let cut = try MEAAgentFiles.answer(comparison, volume: nil, name: nil, extents: false, limit: 1,
                                           page: page(), bound: 24 << 10)
        XCTAssertEqual(cut["different"]?.arrayValue?.count, 1)
        XCTAssertEqual(cut["counts"]?["different"], 3, "the counts are of all of them")
        XCTAssertNotNil(cut["next"]?.stringValue)
        let second = try MEAAgentFiles.answer(comparison, volume: nil, name: nil, extents: false, limit: 1,
                                              page: page(after: cut["next"]?.stringValue), bound: 24 << 10)
        XCTAssertEqual(second["different"]?.arrayValue?.first?["index"], 2, "the next one, none skipped")
        let efsOnly = try MEAAgentFiles.answer(comparison, volume: .efs, name: nil, extents: false, limit: 40,
                                               page: page(), bound: 24 << 10)
        XCTAssertEqual(efsOnly["counts"]?["different"], 0)
    }

    // MARK: - Placing a run at a file

    func testARunIsPlacedAtTheOneFileItTouches() {
        let a = MEANode(path: [0, 1, 0], title: "a", extents: [0x100..<0x140, 0x300..<0x340])
        let b = MEANode(path: [0, 1, 1], title: "b", extents: [0x142..<0x182])
        let index = MEAAgentLocator.FileIndex([a, b])
        XCTAssertEqual(index.only(touching: 0x310..<0x320)?.title, "a")
        XCTAssertEqual(index.only(touching: 0x130..<0x142)?.title, "a", "its CRC is not another file's")
        XCTAssertNil(index.only(touching: 0x130..<0x150), "two files: the partition says it")
        XCTAssertNil(index.only(touching: 0x200..<0x210), "between files")
        XCTAssertEqual(index.only(touching: 0x180..<0x400)?.title, nil)
    }
}
