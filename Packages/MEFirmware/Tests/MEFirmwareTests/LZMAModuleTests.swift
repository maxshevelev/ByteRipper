import XCTest
import Foundation
import FirmwareCompressionTestSupport
@testable import MEFirmware

/// Phase 8, LZMA half — upstream `cse_unpack`'s `mod_comp == 2` branch. Modules
/// are encoded by the LZMA SDK's own encoder; tests never touch the network.
final class LZMAModuleTests: XCTestCase {
    private let body = Data((0..<3000).map { UInt8(truncatingIfNeeded: $0 * 31 / 7) })

    private func stored(_ data: Data) -> Data {
        Data(LZMATestEncoder.lzma([UInt8](data)))
    }

    func testAModuleDecompressesToItsBody() {
        XCTAssertEqual(LZMAModule.decompress(module: stored(body), uncompressedSize: body.count), body)
    }

    /// The stray zeros are three bytes at `0x0E..<0x11` of a module that starts
    /// with the signature — and nowhere else.
    func testStrayZerosAreRemovedOnlyWhereTheSignatureSaysSo() {
        let head: [UInt8] = LZMAModule.strayZerosSignature + [1, 2, 3, 4, 5, 6, 7, 8, 9]
        let quirky = Data(head + [0, 0, 0] + [0xAB, 0xCD])
        XCTAssertEqual(LZMAModule.decoderInput(quirky), Data(head + [0xAB, 0xCD]))

        let otherStart = Data([0x5D] + head.dropFirst() + [0, 0, 0] + [0xAB, 0xCD])
        XCTAssertEqual(LZMAModule.decoderInput(otherStart), otherStart)

        let noZeros = Data(head + [0, 1, 0] + [0xAB, 0xCD])
        XCTAssertEqual(LZMAModule.decoderInput(noZeros), noZeros)
    }

    /// Short of the `.met`'s size, the module is filled out with its own last
    /// byte — the padding upstream adds back.
    func testAShortModuleIsFilledWithItsLastByte() throws {
        let padded = body + Data(repeating: 0xFF, count: 4)
        let output = try XCTUnwrap(LZMAModule.decompress(module: stored(padded),
                                                         uncompressedSize: padded.count + 12))
        XCTAssertEqual(output.count, padded.count + 12)
        XCTAssertEqual(output.suffix(16), Data(repeating: 0xFF, count: 16))
    }

    func testBytesThatAreNotLZMADoNotDecompress() {
        XCTAssertNil(LZMAModule.decompress(module: Data(repeating: 0xA5, count: 64),
                                           uncompressedSize: 64))
    }

    /// The stored hash is the digest read backwards, and it may cover either
    /// the stored bytes or the decompressed ones.
    func testTheHashCoversTheStoredBytesOrTheDecompressedOnes() throws {
        let module = stored(body)
        let decompressed = try XCTUnwrap(LZMAModule.decompress(module: module,
                                                               uncompressedSize: body.count))
        let overStored = LZMAModule.reversedHex(Digest.sha256Hex(module))
        let overBody = LZMAModule.reversedHex(Digest.sha384Hex(body))

        XCTAssertTrue(LZMAModule.hashMatches(storedHash: overStored,
                                             stored: module, decompressed: decompressed))
        XCTAssertTrue(LZMAModule.hashMatches(storedHash: overBody,
                                             stored: module, decompressed: decompressed),
                      "SHA-384 by length, over what came out")
        XCTAssertFalse(LZMAModule.hashMatches(storedHash: Digest.sha256Hex(module),
                                              stored: module, decompressed: decompressed),
                       "the digest in the order it is printed is not the order it is stored")
    }

    func testReversingHexReversesItsBytes() {
        XCTAssertEqual(LZMAModule.reversedHex("0a1b2c"), "2C1B0A")
        XCTAssertEqual(LZMAModule.reversedHex("ABC"), "", "half a byte is no hash")
    }
}
