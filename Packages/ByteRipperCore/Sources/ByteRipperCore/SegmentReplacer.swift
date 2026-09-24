import Foundation

/// Errors thrown by `SegmentReplacer`.
///
/// The presentation layer maps these to user-facing alerts (§16, §21.6). A
/// length mismatch is the one refusal the swap makes: the donor must match the
/// piece's length exactly, and making it an insert-and-shift is a decision, not a
/// default.
public enum SegmentReplaceError: Error, Equatable, Sendable {
    /// The donor's length differs from the piece's. Both sizes are named so the
    /// caller can say what it expected and what it got.
    case lengthMismatch(pieceLength: UInt64, donorLength: UInt64)
}

/// What a swap did to the document's length (§21.6, §21.7), so the caller can
/// move the partition's boundaries with it. A same-length swap reports
/// `.none` — the cuts do not move.
public enum SegmentReplaceOutcome: Equatable, Sendable {
    /// The donor matched the piece: bytes changed, no offset did.
    case none
    /// The donor was longer: `length` bytes were inserted at `at`, the piece's
    /// old end, and everything after shifted right.
    case inserted(at: UInt64, length: UInt64)
    /// The donor was shorter: `range` was removed from the piece's tail, and
    /// everything after shifted left.
    case deleted(range: Range<UInt64>)
}

/// Replaces one piece's bytes with the contents of a donor (§21.6).
///
/// The donor is read in bounded slices and each slice is written to the document
/// with `overwrite`; the whole swap is one undo transaction (an edit group), so
/// it undoes as one step and the donor is never loaded whole into RAM. This is
/// the read-side mirror of `SegmentWriter` (which streams pieces *out* to files):
/// `SegmentWriter` generalises the single-file atomic write, this one generalises
/// the single `overwrite` into a chunked swap.
///
/// A same-length overwrite moves no cut (§21.2): the document's size is
/// unchanged, so the segment partition's boundaries do not shift. A swap that
/// is *allowed* to change the length (Revert Segment, §21.7, and a replace the
/// user agreed to resize) writes the stretch both sides have in place and adds
/// or removes the difference at the piece's tail, so the cuts after it move by
/// exactly that much and no cut inside the piece is disturbed.
public enum SegmentReplacer {
    /// The read/write step; matches `SegmentWriter`'s 1 MiB so a large piece is
    /// streamed rather than loaded whole into RAM.
    static let chunkSize = 1024 * 1024

    /// Overwrites `range` with the donor's bytes, in chunks, as one transaction.
    ///
    /// Throws `lengthMismatch` when `donor.size != range.count` and
    /// `allowingLengthChange` is false, before anything is written — making a
    /// mismatch an insert-and-shift is a decision, so the caller asks for it by
    /// name. A failure part-way through the chunks rolls the partial edit
    /// group back (reverting the ops collected so far, recording no transaction)
    /// and rethrows, so a failed swap leaves the document exactly as it was.
    @discardableResult
    public static func replace(
        range: Range<UInt64>,
        in document: BinaryDocument,
        withContentsOf donor: any ByteStorage,
        allowingLengthChange: Bool = false
    ) throws -> SegmentReplaceOutcome {
        let length = range.upperBound - range.lowerBound
        let donorLength = donor.size
        guard allowingLengthChange || donorLength == length else {
            throw SegmentReplaceError.lengthMismatch(pieceLength: length, donorLength: donorLength)
        }
        guard length > 0 || donorLength > 0 else { return .none }

        // The stretch both sides have: written in place, wherever the lengths
        // end up. What is left over is the tail — added after it, or cut off
        // it — and it is the only part that moves an offset.
        let common = min(length, donorLength)
        var outcome = SegmentReplaceOutcome.none

        document.beginEditGroup()
        do {
            var target = range.lowerBound
            let end = range.lowerBound + common
            var source = UInt64(0)
            while target < end {
                let step = min(UInt64(chunkSize), end - target)
                let bytes = try donor.read(at: source, length: Int(step))
                // A short read means the donor shrank under us. Breaking out
                // here would commit HALF a swap as one transaction and call it a
                // success: the piece would hold the donor's first chunks and the
                // document's own bytes after them.
                guard bytes.count == Int(step) else { throw StorageError.readFailed }
                try document.overwrite(range: target..<(target + UInt64(bytes.count)), with: bytes)
                target += UInt64(bytes.count)
                source += UInt64(bytes.count)
            }
            if donorLength > length {
                // The donor's tail goes in at the piece's old end, in the same
                // bounded chunks, so a long donor is never held whole in RAM.
                var at = range.upperBound
                var source = common
                while source < donorLength {
                    let step = min(UInt64(chunkSize), donorLength - source)
                    let bytes = try donor.read(at: source, length: Int(step))
                    guard bytes.count == Int(step) else { throw StorageError.readFailed }
                    try document.insert(at: at, bytes: bytes)
                    at += UInt64(bytes.count)
                    source += UInt64(bytes.count)
                }
                outcome = .inserted(at: range.upperBound, length: donorLength - length)
            } else if donorLength < length {
                let tail = (range.lowerBound + donorLength)..<range.upperBound
                try document.delete(range: tail)
                outcome = .deleted(range: tail)
            }
        } catch {
            // A mid-stream failure: revert the partial group and record nothing,
            // so the document is left exactly as it was.
            try? document.cancelEditGroup()
            throw error
        }
        document.endEditGroup()
        return outcome
    }
}
