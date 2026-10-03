import Foundation

/// One `LENV` block: a plain header, then entries — XORed with the header's
/// key, as every block on the dumps examined is.
public struct LENVBlock: Equatable, Sendable {
    /// Where the block starts in the file.
    public var offset: UInt64
    /// The block's bytes as the file holds them, header included.
    public var stored: [UInt8]

    public var hasSignature: Bool
    /// Higher is newer; 0 is a block the firmware does not use.
    public var generation: UInt32
    /// How many entries the header says follow.
    public var declaredEntries: UInt32
    /// Bit 0 appears to mark the block write-protected. Not set on any dump
    /// examined, so what the firmware does about it is not confirmed.
    public var accessFlag: UInt8
    public var xorKey: UInt8
    public var checksum: UInt16

    /// How the body is stored, decided by which reading parses — not by
    /// upstream's guess from the block's last byte.
    public var encoding: Encoding
    public var entries: [LENVEntry]
    /// True when `declaredEntries` entries were read and every one of them
    /// fits in the block.
    public var entriesFit: Bool

    public enum Encoding: Equatable, Sendable {
        /// The body is XORed with the key. What every live block examined
        /// holds.
        case encrypted
        /// The body is in the clear under a non-zero key — what upstream's
        /// "decrypt" toggle leaves behind. Whether the firmware accepts it is
        /// not known.
        case plain
        /// The key is zero, so the two are the same bytes.
        case keyIsZero
        /// Neither reading parses; the entries shown are what the encrypted
        /// reading gave before it ran out.
        case undetermined
    }

    /// The bytes after the header, as stored.
    public var storedBody: [UInt8] { Array(stored[LenovoDMIFormat.lenvHeaderSize...]) }

    /// The checksum the body adds up to.
    public var computedChecksum: UInt16 { storedBody.sum16 }
    public var checksumIsValid: Bool { computedChecksum == checksum }

    /// A block the firmware can use: signed, with a generation.
    public var isUsable: Bool { hasSignature && generation != 0 }

    /// Signed, with generation, count, key and checksum all zero and nothing
    /// written after the header but erased bytes — a store wiped or never
    /// filled.
    public var isBlank: Bool {
        hasSignature && generation == 0 && declaredEntries == 0
            && storedBody.allSatisfy { $0 == 0xFF || $0 == 0x00 }
    }

    /// The key the body is decoded with: the header's for an encrypted block,
    /// none for one that is already in the clear.
    public var effectiveKey: UInt8 {
        encoding == .plain ? 0 : xorKey
    }

    /// The range the block covers in the file.
    public var range: Range<UInt64> { offset..<(offset + UInt64(stored.count)) }

    public init(offset: UInt64, stored: [UInt8]) {
        precondition(stored.count >= LenovoDMIFormat.lenvHeaderSize)
        self.offset = offset
        self.stored = stored
        hasSignature = Array(stored[0..<4]) == LenovoDMIFormat.lenvSignature
        generation = LE.u32(stored, 0x04)
        declaredEntries = LE.u32(stored, 0x08)
        accessFlag = stored[0x0C]
        xorKey = stored[0x0D]
        checksum = LE.u16(stored, 0x0E)

        let body = Array(stored[LenovoDMIFormat.lenvHeaderSize...])
        let base = offset + UInt64(LenovoDMIFormat.lenvHeaderSize)
        let count = Int(min(declaredEntries, 0x1000))

        if xorKey == 0 {
            let reading = LENVBlock.walk(body, count: count, base: base)
            encoding = reading.fits ? .keyIsZero : .undetermined
            entries = reading.entries
            entriesFit = reading.fits
            return
        }
        let encrypted = LENVBlock.walk(body.xored(with: xorKey), count: count, base: base)
        let clear = LENVBlock.walk(body, count: count, base: base)
        switch (encrypted.fits, clear.fits) {
        case (true, false):
            encoding = .encrypted; entries = encrypted.entries
        case (false, true):
            encoding = .plain; entries = clear.entries
        case (true, true):
            // Both parse — a short block can. What follows the entries is
            // zero in the clear on every block examined, so the reading that
            // leaves zeros behind is the one the firmware wrote.
            if clear.tailIsZero && !encrypted.tailIsZero {
                encoding = .plain; entries = clear.entries
            } else {
                encoding = .encrypted; entries = encrypted.entries
            }
        case (false, false):
            encoding = .undetermined
            entries = encrypted.entries.count >= clear.entries.count
                ? encrypted.entries : clear.entries
        }
        entriesFit = encoding != .undetermined
    }

    /// The entries of `body` read one after another, until `count` have been
    /// read or one does not fit.
    static func walk(
        _ body: [UInt8], count: Int, base: UInt64
    ) -> (entries: [LENVEntry], fits: Bool, tailIsZero: Bool) {
        var entries: [LENVEntry] = []
        var position = 0
        for index in 0..<count {
            guard position + LenovoDMIFormat.lenvEntryHeaderSize <= body.count else {
                return (entries, false, false)
            }
            let size = Int(LE.u32(body, position + 0x10))
            let dataStart = position + LenovoDMIFormat.lenvEntryHeaderSize
            guard size <= body.count - dataStart else { return (entries, false, false) }
            // The free space after the last entry is zeros, and zeros read as
            // an entry of no bytes under a key of no bytes. A count that runs
            // into them has run out of entries, not found more.
            guard size > 0 || body[position..<dataStart].contains(where: { $0 != 0 }) else {
                return (entries, false, false)
            }
            entries.append(LENVEntry(
                index: index,
                offset: base + UInt64(position),
                key: LenovoDMIKey.read(body, at: position),
                flags: body[position + 0x14],
                unknown1: body[position + 0x15],
                unknown2: LE.u16(body, position + 0x16),
                data: Array(body[dataStart..<(dataStart + size)])
            ))
            position = dataStart + size
        }
        let tailIsZero = body[position...].allSatisfy { $0 == 0 }
        return (entries, true, tailIsZero)
    }

    /// The entry filed under `key`, if this block has one.
    public func entry(_ key: LenovoDMIKey) -> LENVEntry? {
        entries.first { $0.key == key }
    }
}

/// One entry of a `LENV` block, decoded.
public struct LENVEntry: Equatable, Sendable {
    /// Its place in the block, from zero.
    public var index: Int
    /// Where its header starts in the file.
    public var offset: UInt64
    public var key: LenovoDMIKey
    /// Bit 0 appears to mark the entry write-protected; the log's Protect and
    /// Unprotect operations would be what sets and clears it.
    public var flags: UInt8
    /// Two fields nobody has explained. Zero on every entry examined.
    public var unknown1: UInt8
    public var unknown2: UInt16
    /// The value, decoded.
    public var data: [UInt8]

    public var isWriteProtected: Bool { flags & 1 != 0 }

    /// The entry's header and data, in the file.
    public var range: Range<UInt64> { offset..<dataRange.upperBound }
    /// Just the value, in the file.
    public var dataRange: Range<UInt64> {
        let start = offset + UInt64(LenovoDMIFormat.lenvEntryHeaderSize)
        return start..<(start + UInt64(data.count))
    }

    public var knownType: LenovoDMIKnownType? { LenovoDMIKnownType(key) }

    public init(
        index: Int, offset: UInt64, key: LenovoDMIKey, flags: UInt8,
        unknown1: UInt8, unknown2: UInt16, data: [UInt8]
    ) {
        self.index = index
        self.offset = offset
        self.key = key
        self.flags = flags
        self.unknown1 = unknown1
        self.unknown2 = unknown2
        self.data = data
    }
}
