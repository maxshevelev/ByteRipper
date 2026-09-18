import Foundation
import XCTest
import FirmwareCompression

/// Compressing again, for putting an edited buffer back into its section
/// (`Design/UEFI/UPDATE_IN_PARENT.md` §5): every variant the decoders read,
/// written so that the decoder reads it back.
final class CompressionTests: XCTestCase {
    private let limit: UInt64 = 16 * 1024 * 1024

    /// Code-like bytes: runs of a pattern with x86 `call rel32` in them, so the
    /// encoder has something to squeeze and the filter something to convert.
    private func sample(count: Int = 60_000, seed: Int = 0) -> [UInt8] {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(count)
        while bytes.count < count {
            bytes += [0xE8, 0x10, 0x00, 0x00, 0x00]
            bytes += (0..<27).map { UInt8(truncatingIfNeeded: $0 * 7 + bytes.count / 64 + seed) }
        }
        return Array(bytes.prefix(count))
    }

    func testEveryVariantComesBackAsWhatWentIn() throws {
        let original = sample()

        let lzma = try FirmwareCompression.compress(original, as: .lzma)
        XCTAssertEqual(try FirmwareDecompression.lzma(lzma, limit: limit).bytes, original)
        XCTAssertLessThan(lzma.count, original.count, "it compresses")

        let x86 = try FirmwareCompression.compress(original, as: .lzmaX86)
        XCTAssertEqual(try FirmwareDecompression.lzmaX86(x86, limit: limit).bytes, original)

        let tiano = try FirmwareCompression.compress(original, as: .tiano)
        XCTAssertEqual(try FirmwareDecompression.tiano(tiano, limit: limit).tiano, original)

        let efi11 = try FirmwareCompression.compress(original, as: .efi11)
        XCTAssertEqual(try FirmwareDecompression.tiano(efi11, limit: limit).efi11, original)
    }

    /// Both levels write a stream that comes back byte for byte, and on data
    /// full of matches far back — runs copied from anywhere earlier — the
    /// maximum level's is the shorter one. (Not on all data: on a short block
    /// repeated with a byte changed every few hundred, it came out longer.)
    func testBothLevelsRoundTripAndTheMaximumFindsMore() throws {
        var state: UInt32 = 4
        func next() -> Int {
            state = state &* 1_103_515_245 &+ 12345
            return Int(state >> 8)
        }
        var data: [UInt8] = (0..<512).map { _ in UInt8(truncatingIfNeeded: next()) }
        while data.count < 0x8000 {
            let from = next() % max(1, data.count - 64)
            let end = min(data.count, from + 16 + next() % 200)
            data += data[from..<end]
            data += (0..<(next() % 6)).map { _ in UInt8(truncatingIfNeeded: next()) }
        }
        data = Array(data.prefix(0x8000))

        let normal = try FirmwareCompression.compress(data, as: .lzma, effort: .normal)
        let maximum = try FirmwareCompression.compress(data, as: .lzma, effort: .maximum)

        XCTAssertEqual(try FirmwareDecompression.lzma(normal, limit: 1 << 24).bytes, data)
        XCTAssertEqual(try FirmwareDecompression.lzma(maximum, limit: 1 << 24).bytes, data)
        XCTAssertLessThan(maximum.count + 256, normal.count, "normal \(normal.count), maximum \(maximum.count)")
    }

    func testTheDictionarySizeAskedForIsTheOneWritten() throws {
        let stream = try FirmwareCompression.compress(sample(), as: .lzma, dictionarySize: 1 << 20)
        XCTAssertEqual(try FirmwareDecompression.lzma(stream, limit: limit).dictionarySize, 1 << 20)
    }

    /// The four bytes of an Intel legacy stream are the original's: they are
    /// not the encoder's to make up.
    func testALegacyStreamKeepsItsFourBytes() throws {
        let prefix: [UInt8] = [0xDE, 0xAD, 0xBE, 0xEF]
        let stream = try FirmwareCompression.compress(sample(), as: .lzmaIntelLegacy, legacyPrefix: prefix)

        XCTAssertEqual(Array(stream.prefix(4)), prefix)
        let decoded = try FirmwareDecompression.lzma(stream, limit: limit)
        XCTAssertEqual(decoded.variant, .lzmaIntelLegacy)
        XCTAssertEqual(decoded.bytes, sample())

        XCTAssertThrowsError(try FirmwareCompression.compress(sample(), as: .lzmaIntelLegacy)) { error in
            XCTAssertEqual(error as? FirmwareCompression.Failure, .missingLegacyPrefix)
        }
    }

    /// What Update in Parent does: an edited buffer compressed the way the
    /// stream it came out of was.
    func testAnEditedBufferIsCompressedTheWayItsOriginalWas() throws {
        let original = try FirmwareCompression.compress(sample(), as: .lzmaX86, dictionarySize: 1 << 21)
        let decoded = try FirmwareDecompression.lzmaX86(original, limit: limit)
        var edited = decoded.bytes
        edited[100] ^= 0xFF

        let stream = try FirmwareCompression.compress(edited, like: decoded, from: original)

        let again = try FirmwareDecompression.lzmaX86(stream, limit: limit)
        XCTAssertEqual(again.bytes, edited)
        XCTAssertEqual(again.variant, .lzmaX86)
        XCTAssertEqual(again.dictionarySize, 1 << 21)
    }

    func testALegacyOriginalGivesItsPrefixToTheNewStream() throws {
        let prefix: [UInt8] = [0x01, 0x02, 0x03, 0x04]
        let original = try FirmwareCompression.compress(sample(), as: .lzmaIntelLegacy,
                                                        dictionarySize: 1 << 18, legacyPrefix: prefix)
        let decoded = try FirmwareDecompression.lzma(original, limit: limit)

        let stream = try FirmwareCompression.compress(sample(seed: 3), like: decoded, from: original)

        XCTAssertEqual(Array(stream.prefix(4)), prefix)
        XCTAssertEqual(try FirmwareDecompression.lzma(stream, limit: limit).bytes, sample(seed: 3))
    }

    func testNothingCompressesToAStreamOfNothing() throws {
        for variant: FirmwareDecompression.Variant in [.lzma, .lzmaX86, .tiano, .efi11] {
            let stream = try FirmwareCompression.compress([], as: variant)
            XCTAssertFalse(stream.isEmpty, "\(variant) still writes its header")
        }
    }

    /// An encode says how far it has got: forward only, the encoder's share
    /// first, and all the way when the check is done.
    func testAnEncodeReportsItsProgress() throws {
        let reported = Reported<Double>()
        _ = try FirmwareCompression.compress(sample(count: 400_000), as: .lzma) {
            reported.append($0)
        }
        let fractions = reported.all

        XCTAssertEqual(fractions.first, 0)
        XCTAssertEqual(fractions.last, 1)
        XCTAssertEqual(fractions, fractions.sorted(), "never backwards")
        XCTAssertTrue(fractions.contains { $0 > 0 && $0 < FirmwareCompression.encodedShare },
                      "the encoder reports along the way: \(fractions)")
    }

    /// EDK2's compressor keeps its state in statics; encodes from several
    /// threads at once still each come back whole.
    func testTianoEncodesFromSeveralThreadsAtOnce() {
        let failures = NSLock()
        var failed = 0
        DispatchQueue.concurrentPerform(iterations: 8) { index in
            do {
                _ = try FirmwareCompression.compress(sample(count: 20_000, seed: index),
                                                     as: index.isMultiple(of: 2) ? .tiano : .efi11)
            } catch {
                failures.lock()
                failed += 1
                failures.unlock()
            }
        }
        XCTAssertEqual(failed, 0)
    }
}

/// Where a progress closure puts what it is told. The closure is `@Sendable`
/// and may be called from wherever the encoder is running, so what it writes
/// into cannot be a captured `var`.
private final class Reported<Element>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Element] = []

    func append(_ item: Element) {
        lock.lock()
        items.append(item)
        lock.unlock()
    }

    var all: [Element] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }
}
