import XCTest
import FirmwareCompression
import FirmwareCompressionTestSupport

/// LZMA and LZMA with the x86 filter, over streams the SDK's own encoder
/// writes in the layout EDK2 uses (§3.1, §3.2).
final class LZMATests: XCTestCase {
    private let limit: UInt64 = 16 * 1024 * 1024

    /// Something an encoder can squeeze and a filter can change: runs of a
    /// pattern, with x86 `call rel32` instructions scattered through them.
    private func sample(count: Int = 70_000) -> [UInt8] {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(count)
        while bytes.count < count {
            bytes += [0xE8, 0x10, 0x00, 0x00, 0x00]              // call +0x10
            bytes += (0..<27).map { UInt8(truncatingIfNeeded: $0 * 7 + bytes.count / 64) }
        }
        return Array(bytes.prefix(count))
    }

    private func encode(_ bytes: [UInt8]) -> [UInt8] {
        LZMATestEncoder.lzma(bytes)
    }

    private func failure(_ body: () throws -> Any) -> FirmwareDecompression.Failure? {
        do {
            _ = try body()
            return nil
        } catch let failure as FirmwareDecompression.Failure {
            return failure
        } catch {
            XCTFail("unexpected error \(error)")
            return nil
        }
    }

    func testAStreamDecodesToWhatWentIn() throws {
        let original = sample()
        let decoded = try FirmwareDecompression.lzma(encode(original), limit: limit)

        XCTAssertEqual(decoded.bytes, original)
        XCTAssertEqual(decoded.variant, .lzma)
        XCTAssertEqual(decoded.dictionarySize, 1 << 16)
    }

    /// The filter is undone after the decode: the stream holds the converted
    /// bytes, and only running the converter backwards gives the code back.
    func testTheX86FilterIsUndoneAfterDecoding() throws {
        let original = sample()
        let filtered = LZMATestEncoder.x86Filtered(original)
        XCTAssertNotEqual(filtered, original, "the sample has calls the filter converts")
        let stream = LZMATestEncoder.lzmaX86(original)

        XCTAssertEqual(try FirmwareDecompression.lzmaX86(stream, limit: limit).bytes, original)
        XCTAssertEqual(try FirmwareDecompression.lzma(stream, limit: limit).bytes, filtered,
                       "plain LZMA leaves the converted bytes as they were stored")
    }

    /// Four bytes in front of the header push the size field onto the
    /// dictionary size, which no longer fits in 32 bits — that is how the
    /// layout is recognised.
    func testTheIntelLegacyPrefixIsSkipped() throws {
        let original = sample()
        let decoded = try FirmwareDecompression.lzma([0xDE, 0xAD, 0xBE, 0xEF] + encode(original),
                                                     limit: limit)

        XCTAssertEqual(decoded.bytes, original)
        XCTAssertEqual(decoded.variant, .lzmaIntelLegacy)
        XCTAssertEqual(decoded.dictionarySize, 1 << 16)
    }

    func testAStreamThatStopsEarlyIsTruncated() {
        let stream = encode(sample())
        XCTAssertEqual(failure { try FirmwareDecompression.lzma(Array(stream.prefix(stream.count / 2)),
                                                                limit: self.limit) },
                       .truncated)
    }

    func testLessThanAHeaderIsTruncated() {
        XCTAssertEqual(failure { try FirmwareDecompression.lzma([0x5D, 0x00, 0x00, 0x01, 0x00],
                                                                limit: self.limit) },
                       .truncated)
        XCTAssertEqual(failure { try FirmwareDecompression.lzmaX86([], limit: self.limit) },
                       .truncated)
    }

    /// The size is a number in an untrusted file: past the limit nothing is
    /// allocated at all.
    func testASizeOverTheLimitIsRefused() {
        let stream = encode(sample())
        XCTAssertEqual(failure { try FirmwareDecompression.lzma(stream, limit: 1000) },
                       .tooLarge(declared: 70_000))
        XCTAssertEqual(failure { try FirmwareDecompression.lzmaX86(stream, limit: 1000) },
                       .tooLarge(declared: 70_000))
    }

    /// A properties byte above `(4 * 5 + 4) * 9 + 8` names no lc/lp/pb.
    func testImpossiblePropertiesAreCorrupt() {
        var stream = encode(sample())
        stream[0] = 0xFF
        XCTAssertEqual(failure { try FirmwareDecompression.lzma(stream, limit: self.limit) },
                       .corrupt)
    }

    /// A header that promises more than the stream holds does not come back as
    /// a buffer with a tail of whatever the allocator left there.
    func testADeclaredSizeBeyondTheStreamIsAFailure() {
        var stream = encode(sample())
        stream[FirmwareDecompression.lzmaPropertiesSize] &+= 100
        XCTAssertNotNil(failure { try FirmwareDecompression.lzma(stream, limit: self.limit) })
    }

    /// A size that fits in 32 bits in neither place is not a legacy header
    /// either, and the data is long enough to have held one.
    func testNoUsableHeaderEitherWayIsCorrupt() {
        let stream = [UInt8](repeating: 0xFF, count: 64)
        XCTAssertEqual(failure { try FirmwareDecompression.lzma(stream, limit: self.limit) },
                       .corrupt)
    }
}
