import Foundation
@testable import LenovoDMI

/// A store built byte by byte, laid out the way the real dumps lay theirs out:
/// a log of 32-byte entries, then two `LENV` blocks XORed with one key.
///
/// The values are made up. The dumps this was checked against belong to
/// customers' machines, and their serial numbers, UUIDs and keys stay out of
/// the repository.
struct TestStore {
    struct Entry {
        var key: LenovoDMIKey
        var data: [UInt8]
        var flags: UInt8 = 0
    }

    struct LogEntry {
        /// BCD year, BCD century, month, day, hour, minute, second.
        var timestamp: [UInt8]
        var operation: UInt8
        var key: LenovoDMIKey
        var size: UInt32
    }

    static let otherNamespace: [UInt8] = [
        0x46, 0x8F, 0x44, 0x64, 0x23, 0x6E, 0x88, 0x42,
        0x93, 0x49, 0xFD, 0xD8, 0x87, 0xC4
    ]

    static let serial = Entry(key: .smbios(0x0400), data: Array("PF0TEST1".utf8))
    static let mtm = Entry(key: .smbios(0x0200), data: Array("82XX0000GE".utf8))
    static let uuid = Entry(key: .smbios(0x0500), data: [
        0x36, 0x82, 0x67, 0x2B, 0x1B, 0x3B, 0xED, 0x11,
        0x80, 0xF2, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06
    ])
    static let unknown = Entry(key: .smbios(0x0700), data: [0x19])
    static let foreign = Entry(key: LenovoDMIKey(namespace: otherNamespace, type: 0xE10D),
                               data: [0, 0, 0, 0, 0, 0, 0, 0])

    static let standardEntries = [foreign, serial, uuid, unknown, mtm]

    /// One block's 4 KiB: header, entries encoded with `key` unless
    /// `encode` is false, zeros after them (encoded, so they read as the
    /// key), and the checksum of the body as stored.
    static func block(
        generation: UInt32, key: UInt8, entries: [Entry],
        encode: Bool = true, declared: UInt32? = nil, checksum: UInt16? = nil
    ) -> [UInt8] {
        var body: [UInt8] = []
        for entry in entries {
            body += entry.key.namespace
            body += le16(entry.key.type)
            body += le32(UInt32(entry.data.count))
            body += [entry.flags, 0, 0, 0]
            body += entry.data
        }
        body += [UInt8](repeating: 0, count: Int(LenovoDMIFormat.lenvSize) - 16 - body.count)
        if encode { body = body.map { $0 ^ key } }
        let sum = checksum ?? body.reduce(UInt16(0)) { $0 &+ UInt16($1) }
        var header = Array("LENV".utf8)
        header += le32(generation)
        header += le32(declared ?? UInt32(entries.count))
        header += [0, key]
        header += le16(sum)
        return header + body
    }

    /// The log's 8 KiB: header with the write offset in the clear, entries
    /// encoded with `key`, zeros after them encoded too.
    static func log(_ entries: [LogEntry], key: UInt8, writeOffset: UInt32? = nil) -> [UInt8] {
        var body: [UInt8] = []
        for entry in entries {
            body += entry.timestamp
            body += [entry.operation]
            body += entry.key.namespace
            body += le16(entry.key.type)
            body += le32(entry.size)
            body += [0, 0, 0, 0]
        }
        let offset = writeOffset ?? UInt32(0x20 + body.count)
        body += [UInt8](repeating: 0, count: Int(LenovoDMIFormat.ldbgSize) - 0x20 - body.count)
        var header = Array("LDBG".utf8)
        header += le32(offset)
        header += [UInt8](repeating: 0, count: 24)
        return header + body.map { $0 ^ key }
    }

    static let standardLog = [
        // Written before the clock was set: not a date.
        LogEntry(timestamp: [0xDF, 0x20, 0x00, 0x27, 0xE7, 0x3C, 0x26], operation: 2,
                 key: .smbios(0x0011), size: 1),
        LogEntry(timestamp: [0x15, 0x20, 0x11, 0x15, 0x00, 0x01, 0x08], operation: 2,
                 key: .smbios(0x0500), size: 16),
        LogEntry(timestamp: [0x22, 0x20, 0x06, 0x29, 0x20, 0x30, 0x25], operation: 2,
                 key: .smbios(0x0400), size: 8)
    ]

    /// An image: `before` bytes of FF, the area, `after` bytes of FF.
    static func image(
        log: [UInt8], blocks: [[UInt8]], before: Int = 0x3000, after: Int = 0x1000
    ) -> [UInt8] {
        [UInt8](repeating: 0xFF, count: before) + log + Array(blocks.joined())
            + [UInt8](repeating: 0xFF, count: after)
    }

    static func standardImage(key: UInt8 = 0x7F) -> [UInt8] {
        image(
            log: log(standardLog, key: key),
            blocks: [
                block(generation: 127, key: key, entries: standardEntries),
                block(generation: 126, key: key, entries: Array(standardEntries.dropLast()))
            ]
        )
    }

    /// What a wiped store looks like on the dump examined: both blocks
    /// signed, every header field after the signature zero, the bodies
    /// erased, and the log's write offset erased with them.
    static func wipedImage() -> [UInt8] {
        let blank = Array("LENV".utf8) + [UInt8](repeating: 0, count: 12)
            + [UInt8](repeating: 0xFF, count: Int(LenovoDMIFormat.lenvSize) - 16)
        let log = Array("LDBG".utf8) + [0xFF, 0xFF, 0xFF, 0xFF]
            + [UInt8](repeating: 0, count: 24)
            + [UInt8](repeating: 0xFF, count: Int(LenovoDMIFormat.ldbgSize) - 0x20)
        return image(log: log, blocks: [blank, blank])
    }

    static func le16(_ value: UInt16) -> [UInt8] { [UInt8(value & 0xFF), UInt8(value >> 8)] }
    static func le32(_ value: UInt32) -> [UInt8] {
        (0..<4).map { UInt8((value >> (8 * $0)) & 0xFF) }
    }
}
