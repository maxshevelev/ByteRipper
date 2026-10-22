import Foundation
import XCTest
@testable import ByteRipperCore

/// What a workspace keeps in `Kept/` beside its JSON — a history's log, a
/// file's edits — still reads as an earlier build wrote it. Each version from
/// the first a build must still read (workspace version 4) is kept in
/// `Fixtures/` and never rewritten (`Design/WORKSPACE_PLAN.md`, "Versions").
final class KeptFormatVersionTests: XCTestCase {
    /// The content the version-4 log was written over.
    static let base = [UInt8](0..<64)

    /// The edits the version-4 log holds: every kind of op, a typing series,
    /// a labelled group and a fill. The fixture was written from these, so
    /// they stay as they are.
    static func makeVersion4Edits(on doc: BinaryDocument) throws {
        doc.beginSeries(7)
        try doc.overwrite(range: 0..<1, with: [0xAA])
        try doc.overwrite(range: 1..<2, with: [0xBB])
        doc.endSeries()
        try doc.insert(at: 10, bytes: [1, 2, 3])
        try doc.delete(range: 20..<25)
        try doc.fill(pattern: [0xF0, 0x0F], in: 30..<50)
        doc.beginEditGroup(label: "Add Microcode")
        try doc.overwrite(range: 2..<4, with: [9, 9])
        try doc.insert(at: 62, bytes: [0xEE])
        doc.endEditGroup()
    }

    /// Where the version-4 log was pinned when it was written.
    static let version4LogLength: UInt64 = 1188
    static let version4LogHash = "c3a7b341d313df31b94a3e15d9d521410fefd1b59d7cc88d19bd7149ca2bbfc5"
    static let version4Selection = SelectionModel(start: 3, end: 7, fileSize: 63)
    static let version4Segments = Data(#"{"contentSize":64,"pieces":[]}"#.utf8)

    /// What the version-4 edits file holds.
    static let version4Edits = OverlayEdits(baseSize: 64, runs: [.base(0..<10), .added(0..<3), .base(10..<64)],
                                            added: Data([1, 2, 3]))

    private func fixture(_ name: String) throws -> URL {
        try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures/v4"))
    }

    private func makeDocument() -> BinaryDocument {
        BinaryDocument(storage: EditOverlayStorage(base: MemoryBackedStorage(bytes: Self.base)),
                       url: URL(fileURLWithPath: "/dev/null"), readOnly: false)
    }

    func testALogOfVersion4Reads() throws {
        let records = try HistoryLog.read(try fixture("history.log"), length: Self.version4LogLength,
                                          hash: try XCTUnwrap(Data(hex: Self.version4LogHash)))
        let doc = makeDocument()
        try Self.makeVersion4Edits(on: doc)

        XCTAssertEqual(records.map(\.label), doc.undoHistory.heldTransactions.map(\.label))
        XCTAssertEqual(records.map(\.seriesID), doc.undoHistory.heldTransactions.map(\.seriesID))
        XCTAssertEqual(records.last?.transaction.selectionAfter, Self.version4Selection)
        XCTAssertEqual(records.first?.segmentsBefore, Self.version4Segments)

        let first = try XCTUnwrap(records.first).transaction.parent
        let last = try XCTUnwrap(records.last).transaction.serial
        let map = Dictionary(uniqueKeysWithValues: records.map { ($0.transaction.serial, $0.transaction) })
        let storage = EditOverlayStorage(base: MemoryBackedStorage(bytes: Self.base))
        try HistoryLog.apply(try XCTUnwrap(HistoryLog.path(from: first, to: last, through: map)), to: storage)
        XCTAssertEqual(try storage.read(at: 0, length: Int(storage.size)),
                       try doc.read(at: 0, length: Int(doc.size)))
    }

    func testEditsOfVersion4Read() throws {
        let data = try Data(contentsOf: try fixture("file.edits"))
        XCTAssertEqual(try PropertyListDecoder().decode(OverlayEdits.self, from: data), Self.version4Edits)
    }
}

private extension Data {
    init?(hex: String) {
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}
