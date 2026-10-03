import Foundation

/// The `LDBG` change log: what the firmware wrote to the store, when, and how
/// much — a record of writes, not a copy of the values.
public struct LDBGLog: Equatable, Sendable {
    public var offset: UInt64
    public var stored: [UInt8]
    /// Where the firmware appends the next entry, from the start of the log.
    public var writeOffset: UInt32
    /// The 24 header bytes after the write offset. Zero on every dump
    /// examined; what they are for is not known.
    public var unknownHeader: [UInt8]
    /// The key the entries were decoded with, or nil when there is nothing to
    /// decode. Upstream uses the first block's key; on the dumps examined both
    /// blocks carry the same one, so which of them the firmware means is not
    /// settled — the key chosen is the one under which the entries read.
    public var key: UInt8?
    public var entries: [LDBGEntry]
    /// What is wrong with the write offset, if anything.
    public var writeOffsetProblem: WriteOffsetProblem?

    public enum WriteOffsetProblem: Equatable, Sendable {
        /// `FFFFFFFF`: the log was erased and nothing has been written since.
        case erased
        /// Before the first entry, or past the end of the log.
        case outOfRange
        /// Not a whole number of entries after the header.
        case misaligned
    }

    public var range: Range<UInt64> { offset..<(offset + UInt64(stored.count)) }

    /// How many entries the log can hold.
    public var capacity: Int {
        (stored.count - LenovoDMIFormat.ldbgHeaderSize) / LenovoDMIFormat.ldbgEntrySize
    }

    /// `candidateKeys` are the keys of the blocks after the log, in order; the
    /// log is read under each, and in the clear, and the reading in which the
    /// most entries look like entries wins.
    public init(offset: UInt64, stored: [UInt8], candidateKeys: [UInt8]) {
        precondition(stored.count >= LenovoDMIFormat.ldbgHeaderSize)
        self.offset = offset
        self.stored = stored
        writeOffset = LE.u32(stored, 0x04)
        unknownHeader = Array(stored[0x08..<LenovoDMIFormat.ldbgHeaderSize])

        let header = LenovoDMIFormat.ldbgHeaderSize
        let size = LenovoDMIFormat.ldbgEntrySize
        let end: Int
        if writeOffset == 0xFFFF_FFFF {
            writeOffsetProblem = .erased
            end = header
        } else if writeOffset < header || Int(writeOffset) > stored.count {
            writeOffsetProblem = .outOfRange
            end = header
        } else {
            writeOffsetProblem = (Int(writeOffset) - header) % size == 0 ? nil : .misaligned
            end = Int(writeOffset)
        }
        let count = (end - header) / size
        guard count > 0 else {
            key = nil
            entries = []
            return
        }

        var keys: [UInt8] = []
        for candidate in candidateKeys + [0] where !keys.contains(candidate) {
            keys.append(candidate)
        }
        var best: (key: UInt8, entries: [LDBGEntry], score: Int)?
        for candidate in keys {
            var read: [LDBGEntry] = []
            for index in 0..<count {
                let start = header + index * size
                let bytes = Array(stored[start..<(start + size)]).xored(with: candidate)
                read.append(LDBGEntry(index: index, offset: offset + UInt64(start), bytes: bytes))
            }
            let score = read.filter(\.looksLikeAnEntry).count
            if best == nil || score > best!.score {
                best = (candidate, read, score)
            }
        }
        key = best?.key
        entries = best?.entries ?? []
    }
}

/// One entry of the change log.
public struct LDBGEntry: Equatable, Sendable {
    public var index: Int
    public var offset: UInt64
    /// The seven timestamp bytes as read: BCD year, BCD century, month, day,
    /// hour, minute, second.
    public var timestampBytes: [UInt8]
    public var operation: UInt8
    public var key: LenovoDMIKey
    /// How many bytes the operation wrote. A SetData of zero bytes is followed
    /// on the dumps examined by the entry being gone from the newer block,
    /// which makes it read as a removal — not confirmed in the firmware.
    public var size: UInt32
    /// Four bytes nobody has explained. Zero on every entry examined.
    public var unknown: [UInt8]

    public var range: Range<UInt64> {
        offset..<(offset + UInt64(LenovoDMIFormat.ldbgEntrySize))
    }

    public enum Operation: UInt8, Sendable {
        case setData = 0x02
        case protect = 0x06
        case unprotect = 0x07
    }

    public var knownOperation: Operation? { Operation(rawValue: operation) }

    init(index: Int, offset: UInt64, bytes: [UInt8]) {
        self.index = index
        self.offset = offset
        timestampBytes = Array(bytes[0..<7])
        operation = bytes[7]
        key = LenovoDMIKey.read(bytes, at: 8)
        size = LE.u32(bytes, 0x18)
        unknown = Array(bytes[0x1C..<0x20])
    }

    /// The timestamp, when its bytes are a date.
    ///
    /// Upstream reads the first two bytes as a 16-bit year "2000 + BCD byte".
    /// On real dumps the second byte is `0x20` on every entry that reads as a
    /// date, and the pair is a BCD century and a BCD year — `22 20` is 2022.
    /// Entries written before the clock was set read as no date at all, and
    /// are shown as their bytes.
    public var timestamp: DateComponents? {
        guard let year = bcd(timestampBytes[0]), let century = bcd(timestampBytes[1]),
              let month = bcd(timestampBytes[2]), (1...12).contains(month),
              let day = bcd(timestampBytes[3]), (1...31).contains(day),
              let hour = bcd(timestampBytes[4]), hour < 24,
              let minute = bcd(timestampBytes[5]), minute < 60,
              let second = bcd(timestampBytes[6]), second < 60
        else { return nil }
        return DateComponents(year: century * 100 + year, month: month, day: day,
                              hour: hour, minute: minute, second: second)
    }

    /// `YYYY-MM-DD hh:mm:ss`, the way the clock wrote it — no time zone is
    /// stored, so none is applied.
    public var timestampText: String? {
        guard let t = timestamp else { return nil }
        func two(_ value: Int?) -> String { String(format: "%02d", value ?? 0) }
        return "\(t.year ?? 0)-\(two(t.month))-\(two(t.day)) \(two(t.hour)):\(two(t.minute)):\(two(t.second))"
    }

    /// An operation the firmware is known to write, under a key whose bytes
    /// are not all one value — what decides which key the log is read with.
    var looksLikeAnEntry: Bool {
        knownOperation != nil
            && Set(key.namespace).count > 1
            && size <= UInt32(LenovoDMIFormat.lenvSize)
    }

    private func bcd(_ byte: UInt8) -> Int? {
        let high = Int(byte >> 4), low = Int(byte & 0x0F)
        guard high < 10, low < 10 else { return nil }
        return high * 10 + low
    }
}
