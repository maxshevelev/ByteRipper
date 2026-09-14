import CLZMA
import CLZMAEncoder
import CTianoEncoder
import Foundation

/// Encoders for the compressed data a firmware image holds — the other
/// direction from `FirmwareDecompression`, for putting an edited buffer back
/// into its section (`Design/UEFI/UPDATE_IN_PARENT.md` §5).
///
/// Every stream is decoded again before it is handed back, and compared with
/// what went in. A compressed section whose stream does not open is a board
/// that does not start, and an encoder that misbehaves is not something to find
/// out that way — so a stream that does not come back byte for byte is an
/// error, never a result.
public enum FirmwareCompression {
    public enum Failure: Error, Equatable, Sendable {
        /// The encoder refused, with its own result code.
        case encoderFailed(code: Int32)
        /// More than the format holds: its sizes are 32 bits.
        case tooLarge(UInt64)
        /// The new stream does not decode to what went in.
        case roundTripFailed
        /// An Intel legacy stream starts with four bytes of its own, and they
        /// were not given.
        case missingLegacyPrefix
    }

    /// How far an encode has got, from 0 to 1: the encoding up to
    /// `encodedShare`, the decode that checks it after.
    public typealias Progress = @Sendable (Double) -> Void

    /// The part of the progress bar the encoding takes; the check is the rest.
    public static let encodedShare = 0.8

    /// The LZMA dictionary used when the caller has none to keep: 8 MiB, more
    /// than the distance between any two matches in a section of a flash image.
    public static let defaultDictionarySize: UInt32 = 1 << 23

    /// How hard LZMA works at a stream. Tiano and EFI 1.1 have one way only.
    ///
    /// The level a stream was made at is not written into it — its header
    /// keeps the dictionary size, which is kept, and nothing else of the
    /// settings — so a section is compressed again at the normal level, and at
    /// the maximum level only when a normal stream does not fit.
    public enum Effort: Sendable, Equatable {
        /// The SDK's normal level (5): quick, and nearly as small.
        case normal
        /// Level 9 with 273 fast bytes, what the old UEFITool used: the
        /// smallest stream, and several times the time.
        case maximum
    }

    /// `bytes` as a stream of `variant`, decoded back and checked.
    ///
    /// - Parameters:
    ///   - dictionarySize: the LZMA dictionary written into the header; ignored
    ///     by Tiano and EFI 1.1.
    ///   - legacyPrefix: the four bytes an Intel legacy stream starts with —
    ///     required for that variant, ignored by the others.
    ///   - effort: the LZMA level; ignored by Tiano and EFI 1.1.
    ///   - progress: called on the encoding thread as the work goes. The LZMA
    ///     encoder reports as it reads; Tiano reports only when it is done.
    public static func compress(
        _ bytes: [UInt8],
        as variant: FirmwareDecompression.Variant,
        dictionarySize: UInt32 = defaultDictionarySize,
        legacyPrefix: [UInt8]? = nil,
        effort: Effort = .normal,
        progress: Progress? = nil
    ) throws -> [UInt8] {
        guard UInt64(bytes.count) <= UInt64(UInt32.max / 2) else {
            throw Failure.tooLarge(UInt64(bytes.count))
        }
        progress?(0)
        let stream: [UInt8]
        switch variant {
        case .lzma:
            stream = try lzma(bytes, dictionarySize: dictionarySize, effort: effort, progress: progress)
        case .lzmaIntelLegacy:
            guard let legacyPrefix, legacyPrefix.count == FirmwareDecompression.lzmaIntelLegacyPrefix else {
                throw Failure.missingLegacyPrefix
            }
            stream = legacyPrefix + (try lzma(bytes, dictionarySize: dictionarySize, effort: effort,
                                              progress: progress))
        case .lzmaX86:
            stream = try lzma(x86Filter(bytes), dictionarySize: dictionarySize, effort: effort, progress: progress)
        case .tiano:
            stream = try tiano(bytes, tiano: true)
        case .efi11:
            stream = try tiano(bytes, tiano: false)
        }
        progress?(encodedShare)
        guard decodes(stream, as: variant, to: bytes) else { throw Failure.roundTripFailed }
        progress?(1)
        return stream
    }

    /// `bytes` compressed the way `original` was: the same variant, the same
    /// LZMA dictionary size, and the same four bytes in front of an Intel legacy
    /// stream. `stream` is the compressed data `original` was decoded from.
    public static func compress(
        _ bytes: [UInt8],
        like original: FirmwareDecompression.Decoded,
        from stream: [UInt8],
        effort: Effort = .normal,
        progress: Progress? = nil
    ) throws -> [UInt8] {
        let prefix = original.variant == .lzmaIntelLegacy
            ? Array(stream.prefix(FirmwareDecompression.lzmaIntelLegacyPrefix))
            : nil
        return try compress(
            bytes,
            as: original.variant,
            dictionarySize: original.dictionarySize ?? defaultDictionarySize,
            legacyPrefix: prefix,
            effort: effort,
            progress: progress
        )
    }

    /// The x86 branch converter run forwards: what an LZMA + x86 section's
    /// stream holds, before it is encoded.
    public static func x86Filter(_ bytes: [UInt8]) -> [UInt8] {
        var filtered = bytes
        filtered.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            clzma_x86_convert(base, buffer.count, 1)
        }
        return filtered
    }

    // MARK: - Encoding

    /// What the C encoder's progress function reaches its caller's closure
    /// through.
    private final class ProgressBox {
        let report: (UInt64) -> Void

        init(report: @escaping (UInt64) -> Void) {
            self.report = report
        }
    }

    /// The LZMA SDK's encoder in EDK2's layout: five property bytes, the size
    /// in eight, the stream with no end mark.
    private static func lzma(_ bytes: [UInt8], dictionarySize: UInt32, effort: Effort,
                             progress: Progress?) throws -> [UInt8] {
        // An empty array has no base address to hand the encoder.
        let input = bytes.isEmpty ? [UInt8(0)] : bytes
        var output = [UInt8](repeating: 0, count: bytes.count + bytes.count / 3 + 256)
        var length = output.count
        let total = Double(max(bytes.count, 1))
        let box = progress.map { report in
            ProgressBox { processed in report(min(Double(processed) / total, 1) * encodedShare) }
        }
        let context = box.map { Unmanaged.passUnretained($0).toOpaque() }
        let result = withExtendedLifetime(box) {
            input.withUnsafeBufferPointer { source in
                output.withUnsafeMutableBufferPointer { destination in
                    clzma_encode(
                        source.baseAddress, bytes.count, destination.baseAddress, &length, dictionarySize,
                        effort == .maximum ? 1 : 0,
                        context,
                        context == nil ? nil : { context, processed in
                            guard let context else { return }
                            Unmanaged<ProgressBox>.fromOpaque(context).takeUnretainedValue().report(processed)
                        }
                    )
                }
            }
        }
        guard result == 0 else { throw Failure.encoderFailed(code: result) }
        return Array(output.prefix(length))
    }

    /// EDK2's compressor keeps its state in file-level statics, so two
    /// encodes at once would write into each other: one at a time.
    private static let tianoLock = NSLock()

    /// EDK2's Tiano or EFI 1.1 compressor: an 8-byte header of compressed and
    /// original size, then the stream. Asked again with the size it says it
    /// needs when the first buffer is too small.
    private static func tiano(_ bytes: [UInt8], tiano: Bool) throws -> [UInt8] {
        tianoLock.lock()
        defer { tianoLock.unlock() }
        let input = bytes.isEmpty ? [UInt8(0)] : bytes
        var capacity = UInt32(bytes.count) * 2 + 256
        for _ in 0..<2 {
            var output = [UInt8](repeating: 0, count: Int(capacity))
            var length = capacity
            let result = input.withUnsafeBufferPointer { source in
                output.withUnsafeMutableBufferPointer { destination in
                    ctiano_encode(source.baseAddress, UInt32(bytes.count),
                                  destination.baseAddress, &length, tiano ? 1 : 0)
                }
            }
            if result == 0 { return Array(output.prefix(Int(length))) }
            guard length > capacity else { throw Failure.encoderFailed(code: result) }
            capacity = length
        }
        throw Failure.encoderFailed(code: 1)
    }

    // MARK: - Checking

    /// Whether `stream` opens, as `variant`, to exactly `bytes`.
    private static func decodes(
        _ stream: [UInt8], as variant: FirmwareDecompression.Variant, to bytes: [UInt8]
    ) -> Bool {
        let limit = UInt64(bytes.count)
        switch variant {
        case .lzma, .lzmaIntelLegacy:
            guard let decoded = try? FirmwareDecompression.lzma(stream, limit: limit) else { return false }
            return decoded.variant == variant && decoded.bytes == bytes
        case .lzmaX86:
            return (try? FirmwareDecompression.lzmaX86(stream, limit: limit))?.bytes == bytes
        case .tiano:
            return (try? FirmwareDecompression.tiano(stream, limit: limit))?.tiano == bytes
        case .efi11:
            return (try? FirmwareDecompression.tiano(stream, limit: limit))?.efi11 == bytes
        }
    }
}
