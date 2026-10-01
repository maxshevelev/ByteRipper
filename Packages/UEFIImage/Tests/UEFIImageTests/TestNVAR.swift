import Foundation
@testable import UEFIImage

/// AMI NVAR stores, built byte for byte (§9).
///
/// An NVAR store has no header: it is entries back to back, erased space, and
/// a table of GUIDs at the very end, counted backwards. So a store here is a
/// list of entries and a list of GUIDs, and every field of an entry is a
/// parameter — the stores worth testing are the ones with a superseded entry,
/// a chain, a checksum that does not add up.
enum TestNVAR {
    /// An entry: `NVAR`, the size, `next`, the attributes, then — on a valid
    /// entry that is not a later link — the GUID or its index and the name,
    /// then the data and the extended header.
    static func entry(
        attributes: UInt8 = NVAR.valid | NVAR.localGuid | NVAR.asciiName,
        next: UInt32 = NVAR.noNext,
        guid: EFIGUID = TestImage.driverGUID,
        guidIndex: UInt8 = 0,
        name: String = "Setup",
        data: [UInt8] = [0x01, 0x02],
        extended: [UInt8] = []
    ) -> [UInt8] {
        var fields = BinaryWriter()
        if attributes & NVAR.valid != 0 && attributes & NVAR.dataOnly == 0 {
            if attributes & NVAR.localGuid != 0 {
                fields.guid(guid)
            } else {
                fields.u8(guidIndex)
            }
            if attributes & NVAR.asciiName != 0 {
                fields.raw(Array(name.utf8) + [0])
            } else {
                fields.raw(TestNVRAM.ucs2(name))
            }
        }
        fields.raw(data)
        fields.raw(extended)

        var writer = BinaryWriter()
        writer.u32(NVAR.signature)
        writer.u16(UInt16(NVAR.headerSize + fields.count))
        writer.u24(next)
        writer.u8(attributes)
        writer.raw(fields.bytes)
        return writer.bytes
    }

    /// A later link of a chain: no GUID and no name, only data.
    static func dataEntry(next: UInt32 = NVAR.noNext, data: [UInt8], valid: Bool = true) -> [UInt8] {
        entry(attributes: (valid ? NVAR.valid : 0) | NVAR.dataOnly, next: next, data: data)
    }

    /// An entry whose four-byte extended header carries a checksum — the
    /// extended attributes, the checksum, and the header's own size. Right,
    /// unless `wrongBy` says how far off to make it.
    static func checksummedEntry(name: String, data: [UInt8], wrongBy: UInt8 = 0) -> [UInt8] {
        let attributes = NVAR.valid | NVAR.localGuid | NVAR.asciiName | NVAR.extendedHeader
        var bytes = entry(
            attributes: attributes, name: name, data: data,
            extended: [NVAR.extendedChecksum, 0x00, 0x04, 0x00]
        )
        // Over the data and the extended header, the size and the attributes.
        let covered = bytes[(bytes.count - 4 - data.count)...]
        let sum = Checksums.sum8(covered) &+ bytes[4] &+ bytes[5] &+ attributes
        bytes[bytes.count - 3] = (0 &- sum) &+ wrongBy
        return bytes
    }

    /// A store `length` bytes long: the entries, the erase byte, and the GUID
    /// table, whose index 0 is the store's last sixteen bytes.
    static func store(
        _ entries: [[UInt8]],
        guids: [EFIGUID] = [],
        length: Int = 0x100,
        emptyByte: UInt8 = 0xFF
    ) -> [UInt8] {
        var bytes = entries.flatMap { $0 }
        let table = guids.reversed().flatMap(\.bytes)
        bytes += [UInt8](repeating: emptyByte, count: length - bytes.count - table.count)
        return bytes + table
    }

    /// An FFSv2 volume holding one raw file whose body is `body`.
    static func volume(fileGuid: EFIGUID = NvramGuids.nvramNvarStoreFileGuid, body: [UInt8]) -> [UInt8] {
        TestImage.volume(length: 0x400, files: [TestImage.file(guid: fileGuid, body: body)])
    }

    /// An FFSv2 volume holding one freeform file with these sections.
    static func volume(fileGuid: EFIGUID = TestImage.driverGUID, sections: [[UInt8]]) -> [UInt8] {
        TestImage.volume(
            length: 0x400,
            files: [TestImage.sectionedFile(guid: fileGuid, type: 0x02, sections: sections)]
        )
    }
}
