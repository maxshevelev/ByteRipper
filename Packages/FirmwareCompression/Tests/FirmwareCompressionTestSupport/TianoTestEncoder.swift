import CTianoEncoder

/// Test support, and only that: Tiano and EFI 1.1 buffers as EDK2's compressor
/// writes them — an 8-byte header of compressed and original size, then the
/// stream. The compressor keeps its state in file-level statics, so this is
/// for a test building one fixture at a time.
public enum TianoTestEncoder {
    public static func tiano(_ bytes: [UInt8]) -> [UInt8] {
        encode(bytes, tiano: true)
    }

    public static func efi11(_ bytes: [UInt8]) -> [UInt8] {
        encode(bytes, tiano: false)
    }

    private static func encode(_ bytes: [UInt8], tiano: Bool) -> [UInt8] {
        var output = [UInt8](repeating: 0, count: bytes.count * 2 + 256)
        var length = UInt32(output.count)
        let result = bytes.withUnsafeBufferPointer { source in
            output.withUnsafeMutableBufferPointer { destination in
                ctiano_encode(source.baseAddress, UInt32(source.count),
                              destination.baseAddress, &length, tiano ? 1 : 0)
            }
        }
        precondition(result == 0, "the EDK2 compressor failed")
        return Array(output.prefix(Int(length)))
    }
}
