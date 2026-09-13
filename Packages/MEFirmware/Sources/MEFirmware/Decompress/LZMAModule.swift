import Foundation
import FirmwareCompression

/// CSE LZMA module decompression — upstream `cse_unpack`'s `mod_comp == 2`
/// branch (MEA.py ~7245), over the decoder in `FirmwareCompression`
/// (`Design/UEFI/COMPRESSED_SECTIONS.md` §2.3).
///
/// Upstream does three things around the decode that the LZMA format itself
/// knows nothing about, and all three are here: three stray zero bytes some
/// modules carry in their header, the trailing padding a decoded module can be
/// short of, and a stored hash that covers the compressed bytes for most
/// modules and the decompressed ones for a few.
enum LZMAModule {
    /// How a module with the stray zeros starts (after Igor Skochinsky's
    /// `me_unpack.py`, which upstream cites).
    static let strayZerosSignature: [UInt8] = [0x36, 0x00, 0x40, 0x00, 0x00]

    /// What any one CSME module may decompress to. Modules are kilobytes to a
    /// few megabytes; the declared size is an untrusted number.
    static let maximumSize: UInt64 = 64 * 1024 * 1024

    /// The stored bytes as the decoder wants them: a module that starts with
    /// the signature and has zeros at `0x0E..<0x11` loses those three bytes
    /// (upstream `mod_data[:0xE] + mod_data[0x11:]`).
    static func decoderInput(_ stored: Data) -> Data {
        let bytes = [UInt8](stored)
        guard bytes.count >= 0x11,
              Array(bytes.prefix(strayZerosSignature.count)) == strayZerosSignature,
              bytes[0x0E..<0x11].allSatisfy({ $0 == 0 })
        else { return stored }
        return Data(bytes[..<0x0E] + bytes[0x11...])
    }

    /// The module decompressed, or nil when it does not decode.
    ///
    /// A stream shorter than the `.met`'s uncompressed size is filled out with
    /// its own last byte — `0xFF` or `0x00`, whichever the module pads with —
    /// the way upstream adds the "missing EOF padding" (usually on
    /// `NFTP.ptt`).
    static func decompress(module stored: Data, uncompressedSize: Int) -> Data? {
        guard let decoded = try? FirmwareDecompression.lzma(
            [UInt8](decoderInput(stored)), limit: maximumSize
        ) else { return nil }
        var output = Data(decoded.bytes)
        if output.count < uncompressedSize, let last = output.last {
            output.append(Data(repeating: last, count: uncompressedSize - output.count))
        }
        return output
    }

    /// Whether the `.met` hash covers this module: the stored bytes, stray
    /// zeros included (most LZMA modules), or failing that the decompressed
    /// ones (a few) — upstream's `mea_hash_c`, then `mea_hash_u`.
    ///
    /// `storedHash` is `ModuleAttributesExtension.moduleHash`, the hash bytes
    /// in the order the `.met` holds them. Upstream prints the same bytes as a
    /// little-endian integer, so its digest is this one read backwards. The
    /// digest is chosen by length like `get_hash`: 32 bytes SHA-256, otherwise
    /// SHA-384.
    static func hashMatches(storedHash: String, stored: Data, decompressed: Data) -> Bool {
        let expected = reversedHex(storedHash)
        guard !expected.isEmpty else { return false }
        let digest: (Data) -> String = expected.count == 64 ? Digest.sha256Hex : Digest.sha384Hex
        return digest(stored) == expected || digest(decompressed) == expected
    }

    /// Uppercase hex with its bytes in the opposite order.
    static func reversedHex(_ hex: String) -> String {
        let characters = Array(hex.uppercased())
        guard characters.count % 2 == 0 else { return "" }
        return stride(from: characters.count - 2, through: 0, by: -2)
            .map { String(characters[$0..<($0 + 2)]) }
            .joined()
    }
}
