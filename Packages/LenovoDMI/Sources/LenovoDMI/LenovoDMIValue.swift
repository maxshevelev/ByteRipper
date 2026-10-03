import Foundation
import Localization

/// What an entry's bytes say, read the way its type is known to be read.
public enum LenovoDMIValue {
    public enum Reading: Equatable, Sendable {
        case text
        case uuid
        case bytes
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
/// find it: encrypted with the block's key, with the block's checksum
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
