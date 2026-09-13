import FirmwareCompression

/// Test support, and only that: Tiano and EFI 1.1 buffers as EDK2's compressor
/// writes them — an 8-byte header of compressed and original size, then the
/// stream — through the product's encoder, with nothing to handle.
public enum TianoTestEncoder {
    public static func tiano(_ bytes: [UInt8]) -> [UInt8] {
        encode(bytes, as: .tiano)
    }

    public static func efi11(_ bytes: [UInt8]) -> [UInt8] {
        encode(bytes, as: .efi11)
    }

    private static func encode(_ bytes: [UInt8], as variant: FirmwareDecompression.Variant) -> [UInt8] {
        do {
            return try FirmwareCompression.compress(bytes, as: variant)
        } catch {
            preconditionFailure("the EDK2 compressor failed: \(error)")
        }
    }
}
