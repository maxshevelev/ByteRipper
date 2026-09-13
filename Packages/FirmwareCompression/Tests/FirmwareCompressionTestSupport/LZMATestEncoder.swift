import CLZMA
import CLZMAEncoder

/// Test support, and only that: LZMA streams in the layout EDK2 writes, for a
/// test that has to build a compressed section byte by byte.
///
/// A fixture is built rather than committed because no real dump is ever
/// committed to this repository, and an encoded blob pasted into a test is a
/// fixture nobody can read or change.
public enum LZMATestEncoder {
    /// Five property bytes, the size in eight, the stream with no end mark.
    public static func lzma(_ bytes: [UInt8], dictionarySize: UInt32 = 1 << 16) -> [UInt8] {
        var output = [UInt8](repeating: 0, count: bytes.count + bytes.count / 3 + 256)
        var length = output.count
        let result = bytes.withUnsafeBufferPointer { source in
            output.withUnsafeMutableBufferPointer { destination in
                clzma_encode(source.baseAddress, source.count,
                             destination.baseAddress, &length, dictionarySize)
            }
        }
        precondition(result == 0, "the LZMA SDK encoder failed with \(result)")
        return Array(output.prefix(length))
    }

    /// The x86 branch converter run forwards — what an LZMA + x86 section
    /// holds before it is encoded.
    public static func x86Filtered(_ bytes: [UInt8]) -> [UInt8] {
        var filtered = bytes
        filtered.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            clzma_x86_convert(base, buffer.count, 1)
        }
        return filtered
    }

    /// An LZMA + x86 stream: the filter, then the encoder.
    public static func lzmaX86(_ bytes: [UInt8], dictionarySize: UInt32 = 1 << 16) -> [UInt8] {
        lzma(x86Filtered(bytes), dictionarySize: dictionarySize)
    }
}
