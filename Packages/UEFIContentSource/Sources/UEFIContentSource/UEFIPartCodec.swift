import Foundation
import Localization
import PartCodec
import UEFIImage

/// A part of an image that the rebuild planner lays out again on the way back
/// (`Design/UEFI/UPDATE_IN_PARENT.md` §6): a node of the file — a volume, a
/// file, a section — or what a compressed section decompressed to, or a node
/// inside that.
///
/// Decoding reads the target's bytes in its space: the file's own for a node
/// of the file, the decompressed buffer for one inside a compressed section.
/// Encoding hands the panel's bytes to the planner, which compresses them again
/// the way the section was, resizes what has to be resized, and refuses with
/// numbers when the result does not fit.
public struct UEFIPartCodec: PartCodec {
    public var target: UEFIRebuild.Target
    /// The compression the bytes came out of — `LZMA`, `Tiano` — for the
    /// badge; nil for a node of the file, which is the file's own bytes.
    public var compression: String?
    /// The buffers the opening tool-module already has decompressed — the
    /// pane's tree's — so opening a body does not decompress it again. Held
    /// until the first decode and let go of then: the panel outlives the tree
    /// they belong to, and a codec holding megabytes of an old tree's buffers
    /// for as long as the panel is open is a leak by another name.
    private let readers: ReadersOnce

    public init(target: UEFIRebuild.Target, compression: String? = nil, readers: SpaceReaders? = nil) {
        self.target = target
        self.compression = compression
        self.readers = ReadersOnce(readers)
    }

    public var isImmediate: Bool { false }
    /// A node of the file is a slice of it; a buffer is decompressed.
    public var decodesImmediately: Bool { target.space == .file }
    /// A node of the file is the file's bytes, at the file's offsets; a
    /// decompressed buffer is not.
    public var keepsOffsets: Bool { target.space == .file }

    /// A decompressed body says what it was compressed with. A node of the
    /// file is the file's bytes, but it goes back through the planner — it may
    /// change length, and the volume around it is laid out again — which the
    /// badge says too.
    public var badge: PartBadge? {
        if target.space == .file {
            return PartBadge(L("Structure", context: "part badge"),
                             explanation: L("A structure of the image. Update in Parent lays the image out again around it, so its length may change."))
        }
        let name = compression ?? L("Decompressed", context: "part badge")
        return PartBadge(name, explanation: L("Decompressed from the file. Update in Parent compresses it again the way the section was compressed."))
    }

    public func decode(_ parent: PartParent) throws -> [UInt8] {
        if target.space == .file {
            return try parent.content.read(target.range ?? parent.source)
        }
        // Without the tree's readers, readers of the parent's own: a space is
        // decompressed from the file along its chain when it is asked for.
        let readers = self.readers.take()
            ?? SpaceReaders(file: ImageReader(PartReaderByteSource(reader: parent.content)))
        guard let reader = readers.reader(for: target.space),
              let bytes = reader.bytes(target.range ?? reader.all)
        else {
            throw PartRefusal(title: L("Those bytes could not be read."),
                                  message: L("A compressed section on the way to the part no longer decompresses."))
        }
        return bytes
    }

    public func encode(_ part: [UInt8], into parent: PartParent) throws -> PartUpdate {
        let file = try parent.allBytes()
        let progress = parent.progress
        let result = UEFIRebuild.plan(part, at: target, in: file, readsProtectedRanges: true) {
            progress?($0.phase, $0.fraction)
        }
        switch result {
        case .failure(let refusal):
            throw PartRefusal(title: L("“%1$@” cannot be put back", parent.partName), message: refusal.message)
        case .success(let plan):
            return PartUpdate(
                offset: plan.offset, bytes: plan.bytes, source: plan.source,
                notes: plan.warnings.isEmpty
                    ? [L("Nothing was written inside a Boot Guard or vendor protected range.")]
                    : plan.warnings
            )
        }
    }
}

/// A value handed over once and let go of.
private final class ReadersOnce: @unchecked Sendable {
    private var readers: SpaceReaders?
    private let lock = NSLock()

    init(_ readers: SpaceReaders?) { self.readers = readers }

    func take() -> SpaceReaders? {
        lock.lock()
        defer { lock.unlock() }
        let taken = readers
        readers = nil
        return taken
    }
}

/// A part's parent, as bytes the parser reads.
struct PartReaderByteSource: ByteSource {
    let reader: any PartReader

    var byteCount: UInt64 { reader.size }

    /// Zeros of the right length on a failed read, for the reason
    /// `ToolContentByteSource` gives: the parser's bounds arithmetic stays
    /// true.
    func bytes(in range: Range<UInt64>) -> [UInt8] {
        (try? reader.read(range)) ?? [UInt8](repeating: 0, count: Int(range.count))
    }
}
