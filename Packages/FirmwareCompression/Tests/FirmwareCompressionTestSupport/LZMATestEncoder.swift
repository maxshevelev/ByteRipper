import FirmwareCompression

/// Test support, and only that: LZMA streams in the layout EDK2 writes, for a
/// test that has to build a compressed section byte by byte — the product's
/// encoder with a small dictionary and nothing to handle.
///
/// A fixture is built rather than committed because no real dump is ever
/// committed to this repository, and an encoded blob pasted into a test is a
/// fixture nobody can read or change.
public enum LZMATestEncoder {
    /// Five property bytes, the size in eight, the stream with no end mark.
    public static func lzma(_ bytes: [UInt8], dictionarySize: UInt32 = 1 << 16) -> [UInt8] {
        encode(bytes, as: .lzma, dictionarySize: dictionarySize)
    }

    /// The x86 branch converter run forwards — what an LZMA + x86 section
    /// holds before it is encoded.
    public static func x86Filtered(_ bytes: [UInt8]) -> [UInt8] {
        FirmwareCompression.x86Filter(bytes)
    }

    /// An LZMA + x86 stream: the filter, then the encoder.
    public static func lzmaX86(_ bytes: [UInt8], dictionarySize: UInt32 = 1 << 16) -> [UInt8] {
        encode(bytes, as: .lzmaX86, dictionarySize: dictionarySize)
    }

    private static func encode(
        _ bytes: [UInt8], as variant: FirmwareDecompression.Variant, dictionarySize: UInt32
    ) -> [UInt8] {
        do {
            return try FirmwareCompression.compress(bytes, as: variant, dictionarySize: dictionarySize)
        } catch {
            preconditionFailure("the LZMA encoder failed: \(error)")
        }
    }
}
