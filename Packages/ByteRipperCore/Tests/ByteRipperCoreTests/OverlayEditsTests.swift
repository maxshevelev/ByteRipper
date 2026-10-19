import XCTest
@testable import ByteRipperCore

/// A file's unsaved changes written down as runs and laid over the same file
/// again read back as the same content, marked changed where it was.
final class OverlayEditsTests: XCTestCase {
    private let original: [UInt8] = (0..<256).map { UInt8($0) }

    private func storage() -> EditOverlayStorage {
        EditOverlayStorage(base: MemoryBackedStorage(bytes: original))
    }

    /// A base that stands for the file on disk, not a private buffer.
    private func fileStorage() throws -> EditOverlayStorage {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("edits-\(UUID().uuidString).bin")
        try Data(original).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return EditOverlayStorage(base: try FileBackedStorage(url: url))
    }

    private func all(_ storage: EditOverlayStorage) throws -> [UInt8] {
        try storage.read(at: 0, length: Int(storage.size))
    }

    func testOverwritesComeBackInPlace() throws {
        let edited = try fileStorage()
        try edited.overwrite(range: 0x10..<0x12, with: [0xAA, 0xBB])
        let edits = try edited.exportEdits()
        XCTAssertEqual(edits.added.count, 2, "only the changed bytes are kept")

        let restored = try fileStorage()
        try restored.applyEdits(edits)
        XCTAssertEqual(try all(restored), try all(edited))
        XCTAssertTrue(restored.isDirty)
        XCTAssertTrue(restored.canPatchInPlace, "nothing shifted")
        XCTAssertEqual(restored.changedRanges, [0x10..<0x12])
    }

    func testInsertsAndDeletesComeBackShifted() throws {
        let edited = try fileStorage()
        try edited.insert(at: 0x20, bytes: [1, 2, 3])
        try edited.delete(range: 0x80..<0x90)
        let edits = try edited.exportEdits()

        let restored = try fileStorage()
        try restored.applyEdits(edits)
        XCTAssertEqual(try all(restored), try all(edited))
        XCTAssertFalse(restored.canPatchInPlace)
        XCTAssertEqual(restored.changedRanges, [0x20..<restored.size])
    }

    func testEditsOfAnotherSizedFileAreRefused() throws {
        let edited = try fileStorage()
        try edited.overwrite(range: 0..<1, with: [0xFF])
        let edits = try edited.exportEdits()
        let other = EditOverlayStorage(base: MemoryBackedStorage(bytes: [1, 2, 3]))
        XCTAssertThrowsError(try other.applyEdits(edits))
    }

    func testAPrivateBaseIsKeptWhole() throws {
        let edited = storage()
        try edited.overwrite(range: 0..<1, with: [0xFF])
        let edits = try edited.exportEdits()
        XCTAssertEqual(edits.baseSize, 0)
        XCTAssertEqual(edits.added.count, original.count)
        let restored = storage()
        try restored.applyEdits(edits)
        XCTAssertEqual(try all(restored), try all(edited))
    }

    func testEditsReadBackFromJSON() throws {
        let edited = try fileStorage()
        try edited.insert(at: 4, bytes: [9])
        let edits = try edited.exportEdits()
        let data = try JSONEncoder().encode(edits)
        XCTAssertEqual(try JSONDecoder().decode(OverlayEdits.self, from: data), edits)
    }
}
