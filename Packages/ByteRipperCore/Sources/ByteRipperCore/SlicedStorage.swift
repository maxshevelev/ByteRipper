import Foundation

/// A window onto part of another storage: byte `i` of the slice is byte
/// `range.lowerBound + i` of the base (§21.7).
///
/// What a piece's *source* is, when the piece stands for a stretch of a file
/// rather than the whole of it: a segment split in two leaves two pieces linked
/// to one file at different offsets, and a revert or a comparison against
/// either of them wants that stretch as a storage of its own, without copying
/// its bytes.
///
/// The window is fixed at the offsets it was built with and clamped to the
/// base's size *at read time*, so a base that shrinks underneath (a source file
/// rewritten on disk) short-reads at the end rather than reading someone else's
/// bytes: `size` never exceeds what the base can actually supply.
public struct SlicedStorage: ByteStorage {
    private let base: any ByteStorage
    private let start: UInt64
    private let length: UInt64

    /// The slice of `base` covering `range`, clamped to the base's current size.
    public init(base: any ByteStorage, range: Range<UInt64>) {
        self.base = base
        self.start = range.lowerBound
        self.length = range.upperBound > range.lowerBound ? range.upperBound - range.lowerBound : 0
    }

    public var size: UInt64 {
        let baseSize = base.size
        guard start < baseSize else { return 0 }
        return min(length, baseSize - start)
    }

    public func read(at offset: UInt64, length count: Int) throws -> [UInt8] {
        let available = size
        guard offset < available else { return [] }
        let clamped = min(UInt64(count), available - offset)
        guard clamped > 0 else { return [] }
        return try base.read(at: start + offset, length: Int(clamped))
    }
}
