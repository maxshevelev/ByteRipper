import Foundation

/// The bytes of every space a tree's nodes can be in (`ByteSpace`): the file,
/// and what the compressed sections opened so far decompress to.
///
/// What a consumer of `UEFIImage` reads a node's bytes through. A node's
/// ranges are in its own space, so its header is read from that space and from
/// nowhere else — the file's reader handed a buffer offset reads unrelated
/// bytes without a word of complaint.
public struct SpaceReaders: Sendable {
    public let file: ImageReader
    let buffers: DecompressedBuffers
    let limit: UInt64

    /// Over `file`, with buffers of its own — for an image no lazy tree built:
    /// a test's, or a one-off parse's.
    public init(file: ImageReader, limits: UEFIParser.Limits = .init()) {
        self.init(file: file, buffers: DecompressedBuffers(), limit: limits.maxDecompressedSize)
    }

    init(file: ImageReader, buffers: DecompressedBuffers, limit: UInt64) {
        self.file = file
        self.buffers = buffers
        self.limit = limit
    }

    /// A reader of `space`, or nil when a compressed section on the way in
    /// does not decode. It may decode: a buffer the cache let go of is decoded
    /// again from the file, so a caller on the main actor asks for a space it
    /// has recently read, not for one it is guessing at.
    public func reader(for space: ByteSpace) -> ImageReader? {
        try? buffers.reader(for: space, file: file, limit: limit).get()
    }
}
