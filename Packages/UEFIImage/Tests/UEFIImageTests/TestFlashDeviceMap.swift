@testable import UEFIImage

/// An Insyde flash device map built byte by byte, for the tests of what the
/// map makes of the padding it names.
enum TestFlashDeviceMap {
    typealias Entry = (type: EFIGUID, offset: UInt64, size: UInt64)

    /// A map whose entries carry the region types given, each `offset` from
    /// `base`.
    static func map(_ entries: [Entry], base: UInt64) -> [UInt8] {
        var body = BinaryWriter()
        for entry in entries {
            body.guid(entry.type)
            body.fill(16, with: 0)                   // RegionId
            body.u64(entry.offset)
            body.u64(entry.size)
            body.u32(FlashDeviceMap.modifiable)
            body.fill(32, with: 0)                   // Hash
        }
        var header = BinaryWriter()
        header.u32(FlashDeviceMap.signature)
        header.u32(UInt32(FlashDeviceMap.headerSize) + UInt32(body.count))
        header.u32(UInt32(FlashDeviceMap.headerSize))
        header.u32(FlashDeviceMap.entrySize)
        header.u8(FlashDeviceMap.entryFormat)
        header.u8(3)                                 // Revision
        header.u8(0)                                 // ExtensionCount
        header.u8(0)                                 // Checksum, filled in below
        header.u64(base)
        var bytes = header.bytes
        bytes[FlashDeviceMap.checksumOffset] = 0 &- Checksums.sum8(bytes)
        return bytes + body.bytes
    }
}
