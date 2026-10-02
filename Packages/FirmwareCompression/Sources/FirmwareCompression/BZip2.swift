import CBZip2

extension FirmwareDecompression {
    /// A bzip2 stream (`BZh…`), as Apple keeps its device overrides in the
    /// system-flags store. Same contract as the other decoders: the whole
    /// buffer or the reason there is none, under the caller's limit.
    ///
    /// bzip2 does not say its size, so the buffer grows until the stream fits
    /// or the limit is reached.
    public static func bzip2(_ data: [UInt8], limit: UInt64) throws -> [UInt8] {
        guard !data.isEmpty else { throw Failure.truncated }
        var capacity = max(UInt64(data.count) * 4, 4096)
        while true {
            capacity = min(capacity, limit)
            var out = [UInt8](repeating: 0, count: Int(capacity))
            var outLength = UInt32(clamping: capacity)
            var input = data
            let status = input.withUnsafeMutableBufferPointer { source in
                out.withUnsafeMutableBufferPointer { target in
                    BZ2_bzBuffToBuffDecompress(
                        target.baseAddress.map { UnsafeMutableRawPointer($0).assumingMemoryBound(to: CChar.self) },
                        &outLength,
                        source.baseAddress.map { UnsafeMutableRawPointer($0).assumingMemoryBound(to: CChar.self) },
                        UInt32(clamping: source.count),
                        0, 0)
                }
            }
            switch status {
            case BZ_OK:
                out.removeSubrange(Int(outLength)...)
                return out
            case BZ_OUTBUFF_FULL:
                guard capacity < limit else { throw Failure.tooLarge(declared: capacity + 1) }
                capacity *= 2
            case BZ_UNEXPECTED_EOF:
                throw Failure.truncated
            default:
                throw Failure.corrupt
            }
        }
    }
}
