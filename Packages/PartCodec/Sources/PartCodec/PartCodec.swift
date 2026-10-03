import Foundation
import Localization

/// Bytes that do not change under the reader, from any thread: the parent a
/// part is decoded from and encoded into.
public protocol PartReader: Sendable {
    var size: UInt64 { get }
    /// Reads `length` bytes at `offset`; throws rather than truncates past the
    /// end.
    func read(at offset: UInt64, length: Int) throws -> [UInt8]
}

extension PartReader {
    public func read(_ range: Range<UInt64>) throws -> [UInt8] {
        try read(at: range.lowerBound, length: Int(range.upperBound - range.lowerBound))
    }
}

/// What a part panel's bytes are to the bytes of the file they came out of,
/// in both directions (`Design/FRAGMENT_PANELS_PLAN.md`,
/// `Design/UEFI/UPDATE_IN_PARENT.md`).
///
/// A part is opened from a range of its parent — a zone, a node of the image,
/// a compressed section, an encoded block — and what the reader studies is
/// not always those bytes as they lie. It may be them as they are (a copy),
/// what they decompress to, or what they decode to. Each of those is one
/// conformance: `decode` makes the panel's bytes out of the source, and
/// `encode` makes the source again out of the panel's bytes when the reader
/// puts the panel back (Update in Parent). The app opens and puts back every
/// part the same way — a zone, a selection, a part a tool-module handed over —
/// and knows nothing about any of them.
///
/// A value, and `Sendable`: the app keeps it with the link for as long as the
/// panel is open and calls it off the main actor — for a part a tool-module
/// opened, long after that tool-module's session has ended. What it needs it
/// carries.
public protocol PartCodec: Sendable {
    /// The panel's bytes, from the parent as it is now.
    func decode(_ parent: PartParent) throws -> [UInt8]

    /// What putting `part` back writes into the parent, or a
    /// `PartRefusal` saying why it cannot be put back. Run off the main
    /// actor unless `isImmediate`.
    func encode(_ part: [UInt8], into parent: PartParent) throws -> PartUpdate

    /// True when `encode` is a matter of microseconds — a copy, an XOR — so
    /// the update is written on the spot rather than behind a progress sheet.
    var isImmediate: Bool { get }

    /// True when `decode` is cheap enough to run on the spot as the part opens
    /// — a slice of the file, an XOR. A body to decompress is decoded off the
    /// main actor and the panel opens when it is ready.
    var decodesImmediately: Bool { get }

    /// True when byte `n` of the panel is byte `n` of the source: a copy, a
    /// block decoded in place. The parent's bookmarks then reach the panel
    /// at their own rows; for bytes that are not the file's — a decompressed
    /// body — there is no such mapping and they do not.
    var keepsOffsets: Bool { get }

    /// What the panel's header says the bytes are, as a badge beside its name
    /// — `LZMA`, `XOR 77`, `Read-only` — so a reader looking at plain text
    /// knows the file holds it otherwise. Nil for a copy: the bytes are the
    /// file's, and there is nothing to say.
    var badge: PartBadge? { get }
}

extension PartCodec {
    public var isImmediate: Bool { true }
    public var decodesImmediately: Bool { true }
    public var keepsOffsets: Bool { true }
    public var badge: PartBadge? { nil }
}

/// The badge a part panel's header carries for its codec.
public struct PartBadge: Equatable, Sendable {
    /// A word or two: what fits in a capsule beside the panel's name.
    public var text: String
    /// The sentence under the pointer: what the panel shows, and what Update
    /// in Parent does with it on the way back.
    public var explanation: String

    public init(_ text: String, explanation: String) {
        self.text = text
        self.explanation = explanation
    }
}

/// The parent a part is decoded from and encoded into: a frozen reading of
/// its whole content, and where in it the part's source is.
public struct PartParent: Sendable {
    public var content: any PartReader
    /// The source's range in `content` — what the link points at.
    public var source: Range<UInt64>
    /// What the parent is called, for a refusal to name it.
    public var name: String
    /// What the part is called there — the zone's name, the section's.
    public var partName: String
    /// Says what a slow `encode` is doing now, and how far it has got.
    public var progress: (@Sendable (_ phase: String?, _ fraction: Double?) -> Void)?

    public init(
        content: any PartReader, source: Range<UInt64>, name: String, partName: String = "",
        progress: (@Sendable (_ phase: String?, _ fraction: Double?) -> Void)? = nil
    ) {
        self.content = content
        self.source = source
        self.name = name
        self.partName = partName
        self.progress = progress
    }

    /// The source's bytes as they are now.
    public func sourceBytes() throws -> [UInt8] {
        try content.read(source)
    }

    /// The whole parent, for a codec whose way back lays out more than the
    /// source.
    public func allBytes() throws -> [UInt8] {
        try content.read(at: 0, length: Int(content.size))
    }
}

/// One run of bytes to write over the parent, and what the reader is told
/// about it.
public struct PartUpdate: Equatable, Sendable {
    public var offset: UInt64
    public var bytes: [UInt8]
    /// Where the source is once the run is written — the same range, unless
    /// the way back laid it out again at another length.
    public var source: Range<UInt64>
    /// Said after the update, above the line about undoing it.
    public var notes: [String]

    public init(offset: UInt64, bytes: [UInt8], source: Range<UInt64>, notes: [String] = []) {
        self.offset = offset
        self.bytes = bytes
        self.source = source
        self.notes = notes
    }

    /// `bytes` over the whole source, which keeps its place.
    public static func overwriting(_ source: Range<UInt64>, with bytes: [UInt8]) -> PartUpdate {
        PartUpdate(offset: source.lowerBound, bytes: bytes, source: source)
    }
}

/// Why a part cannot go back, in the words the user is shown.
public struct PartRefusal: Error, Equatable, Sendable {
    public var title: String
    public var message: String

    public init(title: String, message: String) {
        self.title = title
        self.message = message
    }

    /// The part is not the source's length, and its bytes go back only at
    /// that length: another one would shift every byte after it.
    public static func lengthChanged(
        part partName: String, parent parentName: String, source: Int, now: Int
    ) -> PartRefusal {
        PartRefusal(
            title: L("The length changed"),
            message: L("“%1$@” is %2$@ bytes in %3$@, and this tab is %4$@. A part goes back only at its own length: another length would shift every byte after it, and the file structure may be affected.",
                       partName, "0x" + String(source, radix: 16, uppercase: true), parentName,
                       "0x" + String(now, radix: 16, uppercase: true))
        )
    }
}

/// The source's own bytes: they open as they are and go back as they are, at
/// the same length.
public struct CopyPartCodec: PartCodec {
    public init() {}

    public func decode(_ parent: PartParent) throws -> [UInt8] {
        try parent.sourceBytes()
    }

    public func encode(_ part: [UInt8], into parent: PartParent) throws -> PartUpdate {
        guard part.count == parent.source.count else {
            throw PartRefusal.lengthChanged(part: parent.partName, parent: parent.name,
                                                source: parent.source.count, now: part.count)
        }
        return .overwriting(parent.source, with: part)
    }
}

/// Bytes worked out of the source that nothing here can turn back into it —
/// a variable's text unpacked from a format there is no encoder for. They open
/// as given and are refused on the way back, with the reason.
public struct ReadOnlyPartCodec: PartCodec {
    public var bytes: [UInt8]
    public var title: String
    public var reason: String

    public init(_ bytes: [UInt8], title: String, reason: String) {
        self.bytes = bytes
        self.title = title
        self.reason = reason
    }

    public func decode(_ parent: PartParent) throws -> [UInt8] { bytes }

    public func encode(_ part: [UInt8], into parent: PartParent) throws -> PartUpdate {
        throw PartRefusal(title: title, message: reason)
    }

    public var keepsOffsets: Bool { false }

    public var badge: PartBadge? {
        PartBadge(L("Read-only", context: "part badge"),
                  explanation: L("These bytes were worked out of the file and cannot be put back into it."))
    }
}
