import Foundation

/// `INSYDE_FLASH_DEVICE_MAP_HEADER` and its entries
/// (`Design/UEFI/BOOT_GUARD_PROTECTED_RANGES.md` §5.3).
enum FlashDeviceMap {
    /// `HFDM`.
    static let signature: UInt32 = 0x4D44_4648
    static let headerSize: UInt64 = 0x1C
    static let checksumOffset = 0x13
    static let baseAddressOffset: UInt64 = 0x14
    /// The one entry layout known: `INSYDE_FLASH_DEVICE_MAP_ENTRY`.
    static let entrySize: UInt32 = 0x54
    static let entryFormat: UInt8 = 0
    static let maxRevision: UInt8 = 4
    /// The region's hash is not checked.
    static let modifiable: UInt32 = 0x1
    /// The entry is not valid — which UEFITool does not look at (§5.3).
    static let ignored: UInt32 = 0x2

    /// Offsets inside an entry.
    static let regionOffsetOffset: UInt64 = 0x20
    static let regionSizeOffset: UInt64 = 0x28
    static let attributesOffset: UInt64 = 0x30
    static let hashOffset: UInt64 = 0x34
}

extension Parser {
    /// A store the raw-area scan found by its signature. Nil when the header
    /// does not hold together — a size that does not fit what is left of the
    /// area, a data offset outside it — which is the scan's cue to keep
    /// looking and no defect.
    ///
    /// The whole store is fixed: it is rebuilt in place whatever its entries
    /// say (`UEFI_IMAGE_FORMAT.md` §11).
    func parseFlashDeviceMap(at offset: UInt64, limit: UInt64) -> UEFINode? {
        guard let size = reader.uint32(at: offset + 4),
              let dataOffset = reader.uint32(at: offset + 8),
              let entrySize = reader.uint32(at: offset + 0x0C),
              let format = reader.uint8(at: offset + 0x10),
              let revision = reader.uint8(at: offset + 0x11),
              UInt64(size) >= FlashDeviceMap.headerSize,
              offset + UInt64(size) <= limit,
              UInt64(dataOffset) >= FlashDeviceMap.headerSize,
              dataOffset <= size
        else { return nil }
        guard revision <= FlashDeviceMap.maxRevision else {
            note(.unknownRevision(.flashDeviceMap, revision), at: offset + 0x11)
            return nil
        }

        // Reported, not required (§5.3).
        if var header = reader.bytes(at: offset, count: FlashDeviceMap.headerSize) {
            let stored = header[FlashDeviceMap.checksumOffset]
            header[FlashDeviceMap.checksumOffset] = 0
            let computed = 0 &- Checksums.sum8(header)
            if computed != stored {
                note(
                    .checksumMismatch(.flashDeviceMap, stored: UInt64(stored), computed: UInt64(computed)),
                    at: offset + UInt64(FlashDeviceMap.checksumOffset)
                )
            }
        }

        let end = offset + UInt64(size)
        let body = (offset + UInt64(dataOffset))..<end
        var entries: [UEFINode] = []
        if entrySize == FlashDeviceMap.entrySize && format == FlashDeviceMap.entryFormat {
            let step = UInt64(entrySize)
            var entry = body.lowerBound
            while entry + step <= end {
                let guid = reader.guid(at: entry)
                entries.append(UEFINode(
                    kind: .flashDeviceMapEntry,
                    name: guid.flatMap(KnownGUIDs.name(of:)) ?? "Flash device map entry",
                    guid: guid,
                    header: entry..<(entry + step),
                    body: (entry + step)..<(entry + step)
                ))
                entry += step
            }
        } else {
            // A layout nobody has described: the store stays a leaf.
            note(.unknownFlashDeviceMapEntries(size: entrySize, format: format), at: offset + 0x0C)
        }

        return UEFINode(
            kind: .flashDeviceMapStore,
            name: "Insyde flash device map",
            header: offset..<body.lowerBound,
            body: body,
            isFixed: true,
            children: entries
        )
    }
}
