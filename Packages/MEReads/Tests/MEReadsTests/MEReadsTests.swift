import XCTest
import MEFirmware
import ToolModuleKit
@testable import MEReads

/// `MEReads` — the bytes both panels hand the engine.
///
/// The reading is thin, and it is what decides which buffer the engine is given
/// and where the addresses in its analysis point, so the cases worth pinning
/// are the ones that choose a buffer: a region the tree resolved, a region that
/// is absent, and a region that is empty.
final class MEReadsTests: XCTestCase {
    /// A reader over a fixed buffer that throws rather than truncates, the way
    /// the real one does.
    private struct Bytes: ToolContentReader {
        let bytes: [UInt8]
        var size: UInt64 { UInt64(bytes.count) }

        func read(at offset: UInt64, length: Int) throws -> [UInt8] {
            guard length >= 0, offset <= UInt64(bytes.count),
                  offset + UInt64(length) <= UInt64(bytes.count) else {
                throw NSError(domain: "MEReadsTests", code: 1)
            }
            return Array(bytes[Int(offset)..<(Int(offset) + length)])
        }
    }

    private let file = Bytes(bytes: (0..<64).map(UInt8.init))

    func testTheRegionIsWhatIsReadWhenTheTreeCouldResolveIt() throws {
        XCTAssertEqual(try MEReads.regionBytes(file, 16..<24),
                       Data((16..<24).map(UInt8.init)), "the region's own bytes")
        XCTAssertEqual(MEReads.regionBase(16..<24), 16,
                       "and its own base, so the analysis stays absolute in the file")
    }

    func testTheWholeFileIsReadWhenTheRegionIsAbsent() throws {
        XCTAssertEqual(try MEReads.regionBytes(file, nil).count, 64, "the whole file")
        XCTAssertEqual(MEReads.regionBase(nil), 0, "from the file's own start")
    }

    func testAnEmptyRegionFallsBackLikeAnAbsentOne() throws {
        XCTAssertEqual(try MEReads.regionBytes(file, 16..<16).count, 64,
                       "an empty region names no bytes")
        XCTAssertEqual(MEReads.regionBase(16..<16), 0)
    }

    func testReadingPastTheEndThrows() {
        XCTAssertThrowsError(try MEReads.readRange(file, 0..<128),
                             "a range past the end is a failure, not a short read")
    }

    /// The reader is asked in 1 MB chunks, so a region that is not a whole
    /// number of them exercises the loop's tail — the last chunk being the
    /// remainder rather than a full one.
    func testAChunkedReadIsTheWholeRange() throws {
        let big = Bytes(bytes: (0..<(1 << 20) + 16).map { UInt8(truncatingIfNeeded: $0) })
        let data = try MEReads.readRange(big, 0..<UInt64(big.bytes.count))
        XCTAssertEqual(data.count, big.bytes.count)
        XCTAssertEqual(data.last, big.bytes.last, "the tail came with it")
    }
}
