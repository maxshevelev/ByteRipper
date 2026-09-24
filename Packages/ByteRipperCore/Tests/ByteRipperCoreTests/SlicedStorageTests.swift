import Foundation
import XCTest
@testable import ByteRipperCore

/// §21.7 a window onto part of another storage: what a piece's *source* is when
/// the piece stands for a stretch of a file rather than the whole of it.
final class SlicedStorageTests: XCTestCase {
    private let base = MemoryBackedStorage(bytes: [UInt8](0..<16))

    func testTheSliceIsItsOwnStorage() throws {
        let slice = SlicedStorage(base: base, range: 4..<10)

        XCTAssertEqual(slice.size, 6)
        XCTAssertEqual(try slice.read(at: 0, length: 6), [4, 5, 6, 7, 8, 9],
                       "byte 0 of the slice is byte 4 of the base")
        XCTAssertEqual(try slice.read(at: 2, length: 2), [6, 7])
    }

    /// A read past the slice's end is clamped, never a read of the base's next
    /// bytes: the window is the whole of what the slice can answer for.
    func testAReadPastTheSliceStopsAtItsEnd() throws {
        let slice = SlicedStorage(base: base, range: 4..<10)

        XCTAssertEqual(try slice.read(at: 4, length: 8), [8, 9])
        XCTAssertEqual(try slice.read(at: 6, length: 4), [])
    }

    /// The window is clamped to the base's size *at read time*, so a base that
    /// shrank underneath — a source file rewritten on disk — short-reads at the
    /// end rather than reading someone else's bytes.
    func testASliceOfABaseThatShrankReportsWhatIsLeft() throws {
        let shrunk = MemoryBackedStorage(bytes: [UInt8](0..<6))
        let slice = SlicedStorage(base: shrunk, range: 4..<10)

        XCTAssertEqual(slice.size, 2)
        XCTAssertEqual(try slice.read(at: 0, length: 6), [4, 5])
    }

    /// A window that opens past the base's end holds nothing at all.
    func testASliceBeyondTheBaseIsEmpty() throws {
        let slice = SlicedStorage(base: base, range: 20..<24)

        XCTAssertEqual(slice.size, 0)
        XCTAssertEqual(try slice.read(at: 0, length: 4), [])
    }
}
