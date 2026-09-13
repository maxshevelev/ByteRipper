import CLZMA
import CTiano

/// Decoders for the compressed data a firmware image holds
/// (`Design/UEFI/COMPRESSED_SECTIONS.md` §3).
///
/// Every function takes bytes read from an untrusted image and a limit on how
/// much the caller is willing to allocate, and hands back either the whole
/// decoded buffer or the reason there is none. Nothing comes back partial: a
/// stream that stops early is a failure, not a shorter buffer, because a parser
/// reading a short buffer finds structures cut off in the middle and reports
/// them as broken — which blames the image for a decode that did not finish.
public enum FirmwareDecompression {
    public enum Failure: Error, Equatable, Sendable {
        /// The data ends before its header does, or before the stream has
        /// produced the size the header declares.
        case truncated
        /// The header or the stream is not something the decoder accepts.
        case corrupt
        /// The header declares more than the caller allows. Refused before
        /// anything is allocated: the size is a number in an untrusted file.
        case tooLarge(declared: UInt64)
    }

    public enum Variant: String, Equatable, Sendable {
        case lzma = "LZMA"
        /// The four extra bytes some Intel images put in front of the header
        /// (§3.1).
        case lzmaIntelLegacy = "LZMA (Intel legacy)"
        case lzmaX86 = "LZMA with x86 filter"
        case tiano = "Tiano"
        case efi11 = "EFI 1.1"
    }

    /// What a Tiano-or-EFI-1.1 buffer decoded to, each way it decoded (§3.3).
    ///
    /// The two algorithms share a header and differ in one field width inside
    /// the stream, so the stream alone does not always say which one it is:
    /// both can succeed, and then only what the bytes are meant to be — a run
    /// of sections, for a UEFI image — tells them apart. That is the caller's
    /// to decide, so both results come back.
    public struct TianoDecoded: Equatable, Sendable {
        public var tiano: [UInt8]?
        public var efi11: [UInt8]?

        public init(tiano: [UInt8]?, efi11: [UInt8]?) {
            self.tiano = tiano
            self.efi11 = efi11
        }
    }

    /// Compressed size, then original size, each 32 bits.
    public static let tianoHeaderSize = 8

    public struct Decoded: Equatable, Sendable {
        public var bytes: [UInt8]
        public var variant: Variant
        /// The dictionary size from the LZMA properties — worth showing, since
        /// it is the one thing that tells two encoders' output apart.
        public var dictionarySize: UInt32?

        public init(bytes: [UInt8], variant: Variant, dictionarySize: UInt32? = nil) {
            self.bytes = bytes
            self.variant = variant
            self.dictionarySize = dictionarySize
        }
    }

    /// Properties, then the uncompressed size as a 64-bit number.
    public static let lzmaPropertiesSize = 5
    public static let lzmaHeaderSize = 13
    public static let lzmaIntelLegacyPrefix = 4

    /// An LZMA stream as EDK2 writes it — the compression section's type
    /// `0x02` and the three LZMA GUID-defined sections (§2.1, §2.2).
    ///
    /// The Intel legacy layout is recognised the way UEFITool recognises it:
    /// when the header at the start does not give a size that fits in 32 bits,
    /// the same header is looked for four bytes further on.
    public static func lzma(_ data: [UInt8], limit: UInt64) throws -> Decoded {
        if let declared = declaredSize(in: data, at: 0) {
            return Decoded(
                bytes: try decode(data, at: 0, declared: declared, limit: limit),
                variant: .lzma,
                dictionarySize: dictionarySize(in: data, at: 0)
            )
        }
        let start = lzmaIntelLegacyPrefix
        guard let declared = declaredSize(in: data, at: start) else {
            throw data.count <= lzmaHeaderSize ? Failure.truncated : Failure.corrupt
        }
        return Decoded(
            bytes: try decode(data, at: start, declared: declared, limit: limit),
            variant: .lzmaIntelLegacy,
            dictionarySize: dictionarySize(in: data, at: start)
        )
    }

    /// LZMA, then the x86 branch converter run backwards over the result
    /// (§3.2) — the compression section's type `0x86` and its GUID-defined
    /// twin. There is no legacy layout of this one.
    ///
    /// The filter assumes x86 code. On an image for another architecture it
    /// turns correct bytes into wrong ones without failing, and what shows is
    /// the sections that no longer parse.
    public static func lzmaX86(_ data: [UInt8], limit: UInt64) throws -> Decoded {
        guard let declared = declaredSize(in: data, at: 0) else {
            throw data.count <= lzmaHeaderSize ? Failure.truncated : Failure.corrupt
        }
        var bytes = try decode(data, at: 0, declared: declared, limit: limit)
        bytes.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            clzma_x86_convert(base, buffer.count, 0)
        }
        return Decoded(
            bytes: bytes,
            variant: .lzmaX86,
            dictionarySize: dictionarySize(in: data, at: 0)
        )
    }

    /// A Tiano or EFI 1.1 buffer — the compression section's type `0x01` and
    /// the Tiano GUID-defined section (§2.1, §2.2) — decoded both ways.
    ///
    /// The header has to account for the data exactly, the way UEFITool checks
    /// it: compressed size plus the header is the length of what was handed in.
    /// It fails only when neither algorithm decodes.
    public static func tiano(_ data: [UInt8], limit: UInt64) throws -> TianoDecoded {
        guard data.count >= tianoHeaderSize else { throw Failure.truncated }
        let compressed = UInt64(littleEndian32(data, at: 0))
        let original = UInt64(littleEndian32(data, at: 4))
        guard compressed + UInt64(tianoHeaderSize) <= UInt64(data.count) else {
            throw Failure.truncated
        }
        guard compressed + UInt64(tianoHeaderSize) == UInt64(data.count) else {
            throw Failure.corrupt
        }
        guard original <= limit else { throw Failure.tooLarge(declared: original) }

        var declared: UInt32 = 0
        var scratch: UInt32 = 0
        let info = data.withUnsafeBufferPointer { source in
            ctiano_info(source.baseAddress, UInt32(source.count), &declared, &scratch)
        }
        guard info == 0, UInt64(declared) == original else { throw Failure.corrupt }
        guard declared > 0 else { return TianoDecoded(tiano: [], efi11: []) }

        func decode(tiano: Bool) -> [UInt8]? {
            var ok = false
            let bytes = [UInt8](unsafeUninitializedCapacity: Int(declared)) { buffer, initialized in
                ok = data.withUnsafeBufferPointer { source in
                    ctiano_decode(source.baseAddress, UInt32(source.count),
                                  buffer.baseAddress, declared, tiano ? 1 : 0) == 0
                }
                initialized = ok ? Int(declared) : 0
            }
            return ok ? bytes : nil
        }
        let result = TianoDecoded(tiano: decode(tiano: true), efi11: decode(tiano: false))
        guard result.tiano != nil || result.efi11 != nil else { throw Failure.corrupt }
        return result
    }

    private static func littleEndian32(_ data: [UInt8], at offset: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { value, index in
            value | UInt32(data[offset + index]) << (8 * index)
        }
    }

    // MARK: - The LZMA header

    /// The uncompressed size the header at `start` declares, or nil when there
    /// is no header there — fewer bytes than a header and a stream, or a size
    /// that does not fit in 32 bits, which no section of a flash image has.
    private static func declaredSize(in data: [UInt8], at start: Int) -> UInt64? {
        guard data.count - start > lzmaHeaderSize else { return nil }
        var size: UInt64 = 0
        for index in (0..<8).reversed() {
            size = size << 8 | UInt64(data[start + lzmaPropertiesSize + index])
        }
        return size <= UInt64(UInt32.max) ? size : nil
    }

    private static func dictionarySize(in data: [UInt8], at start: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { value, index in
            value | UInt32(data[start + 1 + index]) << (8 * index)
        }
    }

    // MARK: - Decoding

    private static func decode(
        _ data: [UInt8],
        at start: Int,
        declared: UInt64,
        limit: UInt64
    ) throws -> [UInt8] {
        guard declared <= limit else { throw Failure.tooLarge(declared: declared) }
        let count = Int(declared)
        guard count > 0 else { return [] }

        var result = Int(CLZMA_OK)
        var written = 0
        let bytes = [UInt8](unsafeUninitializedCapacity: count) { buffer, initialized in
            var status: Int32 = 0
            result = Int(data.withUnsafeBufferPointer { source in
                clzma_decode(
                    source.baseAddress! + start, source.count - start,
                    buffer.baseAddress, count, &written, &status
                )
            })
            initialized = result == CLZMA_OK ? written : 0
        }

        switch result {
        case CLZMA_OK:
            // The decoder stops where the stream does. Short of the declared
            // size, the header and the stream disagree about where that is.
            guard written == count else { throw Failure.truncated }
            return bytes
        case CLZMA_ERROR_INPUT_EOF:
            throw Failure.truncated
        default:
            throw Failure.corrupt
        }
    }
}
