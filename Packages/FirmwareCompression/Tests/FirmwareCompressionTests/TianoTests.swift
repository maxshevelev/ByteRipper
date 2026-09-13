import XCTest
import FirmwareCompression
import FirmwareCompressionTestSupport

/// Tiano and EFI 1.1, over buffers EDK2's own compressor writes (§3.3).
final class TianoTests: XCTestCase {
    private let limit: UInt64 = 16 * 1024 * 1024

    private func sample(count: Int = 40_000) -> [UInt8] {
        (0..<count).map { UInt8(truncatingIfNeeded: ($0 * 7) % 251 ^ ($0 >> 9)) }
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

    /// Each algorithm gives back what went in. The other one, when it decodes
    /// at all, gives something else — which is what a caller tells them apart
    /// by.
    func testTianoAndEFI11EachDecodeToWhatWentIn() throws {
        let original = sample()

        let tiano = try FirmwareDecompression.tiano(TianoTestEncoder.tiano(original), limit: limit)
        XCTAssertEqual(tiano.tiano, original)
        XCTAssertNotEqual(tiano.efi11, original)

        let efi11 = try FirmwareDecompression.tiano(TianoTestEncoder.efi11(original), limit: limit)
        XCTAssertEqual(efi11.efi11, original)
        XCTAssertNotEqual(efi11.tiano, original)
    }

    func testLessThanTheHeaderSaysIsTruncated() {
        let stream = TianoTestEncoder.tiano(sample())
        XCTAssertEqual(failure { try FirmwareDecompression.tiano(Array(stream.prefix(stream.count - 1)),
                                                                 limit: self.limit) },
                       .truncated)
        XCTAssertEqual(failure { try FirmwareDecompression.tiano([1, 2, 3], limit: self.limit) },
                       .truncated)
    }

    /// Bytes after the stream mean the header does not describe this data.
    func testMoreThanTheHeaderSaysIsCorrupt() {
        let stream = TianoTestEncoder.tiano(sample()) + [0, 0, 0, 0]
        XCTAssertEqual(failure { try FirmwareDecompression.tiano(stream, limit: self.limit) }, .corrupt)
    }

    func testAnOriginalSizeOverTheLimitIsRefused() {
        let stream = TianoTestEncoder.efi11(sample())
        XCTAssertEqual(failure { try FirmwareDecompression.tiano(stream, limit: 1000) },
                       .tooLarge(declared: 40_000))
    }

    func testAStreamNeitherAlgorithmReadsIsCorrupt() {
        var stream = TianoTestEncoder.tiano(sample())
        for index in 8..<stream.count { stream[index] = 0xFF }
        XCTAssertEqual(failure { try FirmwareDecompression.tiano(stream, limit: self.limit) }, .corrupt)
    }
}
