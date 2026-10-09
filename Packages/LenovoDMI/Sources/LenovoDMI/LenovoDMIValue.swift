import Foundation
import Localization
import PartCodec

/// What an entry's bytes say, read the way its type is known to be read.
public enum LenovoDMIValue {
    public enum Reading: Equatable, Sendable {
        case text
        case uuid
        case bytes
        /// The key after the header the ACPI `MSDM` table gives it.
        case windowsKey
    }

    /// The Windows key entry, read: the 20-byte header of the licensing data
    /// in the ACPI `MSDM` table and the key after it.
    ///
    /// The header is a signature and a length. The fields are the MSDM
    /// table's Software Licensing Structure — `version`, `reserved`,
    /// `data_type`, `data_reserved`, `data_length`, each a `UINT32`, then the
    /// data — as Microsoft's "Microsoft Software Licensing Tables (SLIC and
    /// MSDM)" defines it and fwts (`fwts_acpi_table_msdm`, 2015) checks it:
    /// both reserved fields zero, data type 1 for a product key, data length
    /// `0x1D`. The version is 1 on every dump examined; fwts does not check
    /// it. Together that is the 16-byte signature
    /// `01000000 00000000 01000000 00000000`. The length, the last 4
    /// bytes, is the key's: `1D000000` for `XXXXX-XXXXX-XXXXX-XXXXX-XXXXX`.
    /// The key is split off only when both hold; otherwise the entry is shown
    /// as bytes and the panel says which of them did not.
    public struct WindowsKey: Equatable, Sendable {
        public var key: String
        public static let headerSize = 20
        public static let signature: [UInt8] = [1, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0]

        /// What is wrong with an entry that is not a header and a key.
        public enum Problem: Equatable, Sendable {
            /// Shorter than the header.
            case tooShort(Int)
            /// The first 16 bytes are not the signature.
            case signature([UInt8])
            /// The length the header gives against the bytes that follow it.
            case length(declared: UInt32, actual: Int)
            /// The key holds bytes that are not printable.
            case notText
        }

        public init?(_ data: [UInt8]) {
            guard Self.problem(data) == nil else { return nil }
            key = String(decoding: data[Self.headerSize...], as: UTF8.self)
        }

        public static func problem(_ data: [UInt8]) -> Problem? {
            guard data.count >= headerSize else { return .tooShort(data.count) }
            let head = Array(data[..<signature.count])
            guard head == signature else { return .signature(head) }
            let declared = LE.u32(data, 16)
            let actual = data.count - headerSize
            guard declared == UInt32(actual) else { return .length(declared: declared, actual: actual) }
            guard actual > 0, data[headerSize...].allSatisfy({ (0x20...0x7E).contains($0) }) else {
                return .notText
            }
            return nil
        }
    }

    /// The value in one line: text without its padding, a UUID, or hex.
    ///
    /// An entry of a type nobody has documented reads as text when every byte
    /// is printable — most of them are names and numbers — and as hex when it
    /// is not.
    public static func text(of entry: LENVEntry) -> String {
        let reading = entry.knownType?.reading ?? (isText(entry.data) ? .text : .bytes)
        switch reading {
        case .text where isText(entry.data):
            return String(decoding: trimmed(entry.data), as: UTF8.self)
        case .uuid where entry.data.count == 16:
            return uuid(entry.data)
        case .windowsKey:
            return WindowsKey(entry.data)?.key ?? hex(entry.data)
        default:
            return hex(entry.data)
        }
    }

    /// A UUID in the order SMBIOS stores one: the first three fields
    /// little-endian. On the dumps examined that order gives a version-1 UUID
    /// with the RFC variant; the bytes taken as they lie give neither.
    public static func uuid(_ bytes: [UInt8]) -> String {
        precondition(bytes.count == 16)
        let order = [3, 2, 1, 0, 5, 4, 7, 6, 8, 9, 10, 11, 12, 13, 14, 15]
        let digits = order.map { LE.hex(UInt64(bytes[$0]), digits: 2, prefix: false) }
        return [digits[0..<4], digits[4..<6], digits[6..<8], digits[8..<10], digits[10..<16]]
            .map { $0.joined() }
            .joined(separator: "-")
    }

    public static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { LE.hex(UInt64($0), digits: 2, prefix: false) }.joined(separator: " ")
    }

    /// Printable ASCII, then nothing but padding.
    static func isText(_ bytes: [UInt8]) -> Bool {
        let body = trimmed(bytes)
        return !body.isEmpty && body.allSatisfy { (0x20...0x7E).contains($0) }
    }

    /// Without the zeros and spaces after the last character.
    static func trimmed(_ bytes: [UInt8]) -> [UInt8] {
        var end = bytes.count
        while end > 0, bytes[end - 1] == 0 || bytes[end - 1] == 0x20 { end -= 1 }
        return Array(bytes[..<end])
    }

    /// What the panel calls an entry: its known name, or its type for one
    /// nobody has named.
    public static func name(of key: LenovoDMIKey) -> String {
        if let known = LenovoDMIKnownType(key) { return known.name }
        return key.isSMBIOS
            ? L("Unknown SMBIOS entry %1$@", key.typeText)
            : L("Unknown entry %1$@", key.typeText)
    }
}

/// The writes that put a new value into an entry, the way the firmware would
/// find it: encoded with the block's key, with the block's checksum
/// recomputed.
///
/// The value never changes length. `L05SmbiosOverride` builds the SMBIOS
/// tables from these entries partly by fixed offsets, so an entry that grew or
/// shrank would move what comes after it in a way nobody has worked out.
public enum LenovoDMIEdit {
    public enum Refusal: Error, Equatable, Sendable {
        /// The value is not as long as the entry.
        case lengthChanges(expected: Int, got: Int)
        /// No block holds an entry with this key.
        case noSuchEntry
        /// The entry is marked write-protected in a block that holds it.
        case writeProtected(block: Int)
        /// A block holding the entry cannot be read reliably enough to write.
        case blockUnreadable(block: Int)
    }

    /// One write to the file.
    public struct Write: Equatable, Sendable {
        public var offset: UInt64
        public var bytes: [UInt8]
    }

    /// The writes that set the entry filed under `key` to `value` in every
    /// block that holds it — both copies, so the firmware reads the new value
    /// whichever it picks. A block without the entry is left as it is, and the
    /// result says which blocks were written.
    ///
    /// The generation is not touched, and nothing is appended to the change
    /// log: the firmware writes the log when *it* writes, and an entry made up
    /// here would be a record of something the firmware never did.
    public static func set(
        _ key: LenovoDMIKey, to value: [UInt8], in area: LenovoDMIArea
    ) throws -> (writes: [Write], blocks: [Int]) {
        var writes: [Write] = []
        var written: [Int] = []
        for (index, block) in area.blocks.enumerated() {
            guard block.isUsable, let entry = block.entry(key) else { continue }
            guard block.entriesFit else { throw Refusal.blockUnreadable(block: index) }
            guard !entry.isWriteProtected else { throw Refusal.writeProtected(block: index) }
            guard value.count == entry.data.count else {
                throw Refusal.lengthChanges(expected: entry.data.count, got: value.count)
            }
            let encoded = value.xored(with: block.effectiveKey)
            let start = Int(entry.dataRange.lowerBound - block.offset)
            var stored = block.stored
            stored.replaceSubrange(start..<(start + encoded.count), with: encoded)
            let checksum = Array(stored[LenovoDMIFormat.lenvHeaderSize...]).sum16
            writes.append(Write(offset: entry.dataRange.lowerBound, bytes: encoded))
            writes.append(Write(offset: block.offset + 0x0E, bytes: LE.bytes16(checksum)))
            written.append(index)
        }
        guard !written.isEmpty else { throw Refusal.noSuchEntry }
        return (writes, written)
    }
}

/// A whole block in the clear, and the way back.
///
/// The decoded block is the header as stored and the body decoded: what a
/// technician reads in the hex view — the serial number as text — and can
/// edit in place. Putting it back encodes the body again with the key in the
/// header and writes the checksum the encoded body adds up to, so the block
/// that lands in the file is one the firmware reads.
public enum LenovoDMIDecodedBlock {
    /// Whether the block can be opened decoded: signed, holding something,
    /// and stored in a way that was recognised. A block whose entries parse
    /// under neither reading is not decoded on a guess.
    public static func canOpen(_ block: LENVBlock) -> Bool {
        block.hasSignature && !block.isBlank && block.encoding != .undetermined
    }

    /// The block with its body decoded.
    public static func decode(_ block: LENVBlock) -> [UInt8] {
        let header = Array(block.stored[..<LenovoDMIFormat.lenvHeaderSize])
        return header + block.storedBody.xored(with: block.effectiveKey)
    }

    /// What the file gets back for `bytes`, a block in the clear: the body
    /// XORed with the key byte of `bytes`' own header — so a key changed in
    /// the panel is the key the block is written under — unless `encodes` is
    /// false, for a block that was stored in the clear and stays so, and the
    /// checksum of the body as it will be stored.
    public static func encode(_ bytes: [UInt8], encodes: Bool) throws -> [UInt8] {
        guard bytes.count == Int(LenovoDMIFormat.lenvSize) else {
            throw LenovoDMIEdit.Refusal.lengthChanges(expected: Int(LenovoDMIFormat.lenvSize), got: bytes.count)
        }
        let size = LenovoDMIFormat.lenvHeaderSize
        let key = encodes ? bytes[0x0D] : 0
        let body = Array(bytes[size...]).xored(with: key)
        var header = Array(bytes[..<size])
        header.replaceSubrange(0x0E..<0x10, with: LE.bytes16(body.sum16))
        return header + body
    }
}

/// A `LENV` block opened in the clear and put back encoded: the codec Open
/// Decoded Block hands the app.
///
/// Decoding takes the block as the file holds it now and decodes the body;
/// encoding encodes it again with the key in the panel's own header and
/// writes the checksum. Byte `n` of the panel is byte `n` of the block, so the
/// parent's bookmarks reach it.
public struct LenovoDMIBlockCodec: PartCodec {
    /// False for a block that was stored in the clear: it goes back the same
    /// way, with only its checksum recomputed.
    public var encodes: Bool
    public var key: UInt8

    public init(block: LENVBlock) {
        encodes = block.encoding != .plain
        key = block.xorKey
    }

    public func decode(_ parent: PartParent) throws -> [UInt8] {
        let stored = try parent.sourceBytes()
        guard stored.count == Int(LenovoDMIFormat.lenvSize) else {
            throw PartRefusal(title: L("Those bytes could not be read."),
                              message: L("A LENV block is %1$@ bytes, and goes back only at that length.", "0x1000"))
        }
        let block = LENVBlock(offset: parent.source.lowerBound, stored: stored)
        return LenovoDMIDecodedBlock.decode(block)
    }

    public func encode(_ part: [UInt8], into parent: PartParent) throws -> PartUpdate {
        guard part.count == Int(LenovoDMIFormat.lenvSize), parent.source.count == part.count else {
            throw PartRefusal.lengthChanged(part: parent.partName, parent: parent.name,
                                            source: parent.source.count, now: part.count)
        }
        return .overwriting(parent.source, with: try LenovoDMIDecodedBlock.encode(part, encodes: encodes))
    }

    public var badge: PartBadge? {
        guard encodes else {
            return PartBadge(L("Plain", context: "part badge"),
                             explanation: L("A LENV block stored in the clear. Update in Parent recomputes its checksum."))
        }
        return PartBadge("XOR " + String(format: "%02X", key),
                         explanation: L("Decoded from the file. Update in Parent encodes it again with the key in its header and recomputes the checksum."))
    }
}
