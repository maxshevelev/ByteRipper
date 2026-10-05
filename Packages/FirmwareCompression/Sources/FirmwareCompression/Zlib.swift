import zlib

extension FirmwareDecompression {
    /// A zlib stream with its two-byte header, as AMD's Zlib section holds it
    /// after its own 0x100-byte header (`COMPRESSED_SECTIONS.md` §3.4) —
    /// `inflateInit2(15)`, as the reference decodes it. Same contract as the
    /// other decoders: the whole buffer or the reason there is none, under the
    /// caller's limit.
    ///
    /// zlib does not say its size, so the buffer grows as the stream gives
    /// more. A stream that stops before its end mark is truncated, not short:
    /// a section read from half a volume reports damage that is not there.
    /// What follows the end mark is not looked at, as the reference does not.
    public static func zlib(_ data: [UInt8], limit: UInt64) throws -> Decoded {
        guard !data.isEmpty else { throw Failure.truncated }
        var stream = z_stream()
        guard inflateInit2_(&stream, 15, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw Failure.corrupt
        }
        defer { inflateEnd(&stream) }

        var output: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 1 << 16)
        var input = data
        var overLimit = false
        let status: Int32 = input.withUnsafeMutableBufferPointer { source in
            stream.next_in = source.baseAddress
            stream.avail_in = uInt(source.count)
            while true {
                let (status, produced) = chunk.withUnsafeMutableBufferPointer { target in
                    stream.next_out = target.baseAddress
                    stream.avail_out = uInt(target.count)
                    let status = inflate(&stream, Z_NO_FLUSH)
                    return (status, target.count - Int(stream.avail_out))
                }
                guard UInt64(output.count + produced) <= limit else {
                    overLimit = true
                    return status
                }
                output += chunk.prefix(produced)
                // The output has room every time round, so `Z_BUF_ERROR`
                // means one thing here: the input ran out first.
                guard status == Z_OK else { return status }
            }
        }
        if overLimit { throw Failure.tooLarge(declared: limit + 1) }
        switch status {
        case Z_STREAM_END:
            return Decoded(bytes: output, variant: .zlib)
        case Z_BUF_ERROR:
            throw Failure.truncated
        default:
            throw Failure.corrupt
        }
    }
}

extension FirmwareCompression {
    /// zlib at its best level, the level AMD's streams are written at (their
    /// header says `78 DA`); there is nothing slower to fall back to.
    static func zlib(_ bytes: [UInt8]) throws -> [UInt8] {
        var length = compressBound(uLong(bytes.count))
        var output = [UInt8](repeating: 0, count: Int(length))
        // An empty array has no base address to hand the encoder.
        let input = bytes.isEmpty ? [UInt8(0)] : bytes
        let result = input.withUnsafeBufferPointer { source in
            output.withUnsafeMutableBufferPointer { destination in
                compress2(destination.baseAddress, &length, source.baseAddress, uLong(bytes.count),
                          Z_BEST_COMPRESSION)
            }
        }
        guard result == Z_OK else { throw Failure.encoderFailed(code: result) }
        return Array(output.prefix(Int(length)))
    }
}
