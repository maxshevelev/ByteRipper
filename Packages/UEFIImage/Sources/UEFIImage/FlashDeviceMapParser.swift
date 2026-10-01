import Foundation

/// `INSYDE_FLASH_DEVICE_MAP_HEADER` and its entries
/// (`Design/UEFI/BOOT_GUARD_PROTECTED_RANGES.md` §5.3).
public enum FlashDeviceMap {
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

    /// `INSYDE_FLASH_MAP_REGION_VAR_DEFAULT_GUID`: a range of `$VSS` stores
    /// holding the firmware's default variables, outside every volume.
    public static let variableDefaults = KnownGUIDs.guid("D9DDACA2-0816-48F3-ADED-6B71656B248A")
    /// `INSYDE_FLASH_MAP_REGION_BVDT_GUID`: the `$BVDT$` table (`InsydeBVDT`).
    public static let biosVersionDataTable = KnownGUIDs.guid("32415DFC-D106-48C7-9EB5-806C114DD107")
    /// `INSYDE_FLASH_MAP_REGION_EC_GUID`: the embedded controller's firmware.
    public static let ecFirmware = KnownGUIDs.guid("A73EF3BF-33CC-43A9-B39C-A912C7489A57")

    /// What a region of this type is, in UEFITool's words
    /// (`insydeFlashDeviceMapEntryTypeGuidToUString`), or nil for a type it
    /// does not name. The entry's row reads as this: the GUID alone says
    /// nothing a technician can use.
    public static func regionTypeName(_ guid: EFIGUID) -> String? {
        regionTypeNames[guid]
    }

    private static let regionTypeNames: [EFIGUID: String] = {
        let names: [(String, String)] = [
            ("8CC7CC2D-C926-473B-B9D7-B297BB0FCA5F", "Aux Firmware Volume"),
            ("E3D76D56-988A-4D6B-8913-64F2DF1DF6A6", "Boot Firmware Volume"),
            ("32415DFC-D106-48C7-9EB5-806C114DD107", "BIOS Version Data Table"),
            ("A73EF3BF-33CC-43A9-B39C-A912C7489A57", "EC Firmware"),
            ("B78E15D3-F0A5-4248-8E2F-D3157AEF8836", "FTW Backup"),
            ("C8416E04-9934-4079-BE9A-39F8D6028498", "FTW State"),
            ("B5E8E758-A7E6-4C8B-AB85-FF2A959B99BA", "Firmware Volume"),
            ("A36CBFED-0A2F-4A9D-823C-3C498C06DDD1", "Other Firmware Volume"),
            ("F078C1A0-FC52-4C3F-BE1F-D688815A62C0", "Flash Device Map"),
            ("29280631-623B-43E4-BCA1-005214C483A6", "GPNV"),
            ("1AB43FAF-4988-47B9-969B-3E31587A75DE", "License"),
            ("DACFAB69-F977-4784-8AD8-7724A6F4B440", "Logo"),
            ("B49866F8-8CD2-49E4-A16D-B60FBEC31C4B", "Microcode"),
            ("B344EB1A-F97E-4F14-A1E1-7E63BC40C8CE", "MSDM Table"),
            ("5994B592-2F14-48D5-BB40-BD27969C7780", "MultiConfig"),
            ("A42C1051-73B5-41A9-B635-0CC51C8272F8", "ODM"),
            ("2FD91AD6-D8E3-4FD6-B679-3030E86AE57A", "OEM"),
            ("C0027E32-8EE5-4D17-9B28-BA50166C4CB4", "Password"),
            ("B95D2198-8E70-4CDC-937D-9A3F795F9905", "SMBIOS Event Log"),
            ("8964FEDC-6FE7-4E1E-A55E-FF821D71FFCF", "SMBIOS Update"),
            ("773C5374-81D1-4D43-B293-F3D74F181D6B", "Variables"),
            ("D9DDACA2-0816-48F3-ADED-6B71656B248A", "Variable Defaults"),
            ("201D65E5-BE23-4875-80F8-B1D4795E7E08", "Unknown"),
            ("13C8B020-4F27-453B-8F80-1BFCA187380F", "Unused"),
            ("607BF30F-5F2B-4DA2-AEED-56F9BDCD2D21", "USB Option ROM"),
            ("1FD0BACE-6F0A-4085-901E-F6210385CB6F", "DXE Firmware Volume"),
            ("CF1406C5-3FEC-47EB-A6C3-B71A3EE00B95", "PEI Firmware Volume"),
            ("F2A016B6-E814-402E-A395-46D3CF75264A", "Unsigned Firmware Volume"),
            ("00000C00-0000-0000-0000-000000000000", "Factory Copy"),
            ("244A24AF-C124-49A3-B286-ACE1AB31FD25", "Option ROM"),
            ("8C493122-CE49-4504-9250-1B296C49A5C3", "BusDeviceFunction Option ROM"),
            ("1A6047F6-7B12-45E1-A26F-E8DDA55D7256", "Verb Table"),
            ("AD38B3FD-5C53-49FE-A4B3-28EE079D2495", "Lenovo Variable1"),
            ("A63E8136-6933-46A0-B74A-3618A5F7EF04", "Lenovo Variable2"),
            ("3E2DA81C-E401-4B6B-B8A4-5095DA690DDD", "Lenovo EEPROM"),
            ("F392B582-1F08-4E95-B51D-598B19F6993F", "Lenovo Supervisor Password"),
            ("FA01652A-4942-417A-AE1C-B8FA2BD31A84", "Lenovo User Password"),
            ("D1877CDF-4573-4273-A11C-97428E03A734", "Lenovo SLP 2.0"),
            ("CD1C653D-D25D-44D2-BF94-37D9633DE22F", "Lenovo Computrace"),
            ("45C3433E-E013-4F0C-AE37-A9AA0B47C42E", "Lenovo Custom MultiLogo"),
            ("0669D988-1C2C-455F-8BDD-6DA303F4AAC1", "Lenovo Reserved"),
            ("06BFC909-BCEF-4E32-8E64-E909D9F6BBE4", "Lenovo Computrace Volume"),
            ("0978798D-98FA-4A38-BBC5-96F0B4DEC485", "Lenovo Backup IBB"),
            ("C2C749AF-12D6-484A-A39A-81D1C1F04E01", "Lenovo Variable Debug"),
            ("C2C749AF-12D6-484A-A39A-81D1C1F04E02", "Lenovo Variable Sub1"),
            ("C2C749AF-12D6-484A-A39A-81D1C1F04E03", "Lenovo Variable Sub2"),
        ]
        return Dictionary(uniqueKeysWithValues: names.map { (KnownGUIDs.guid($0.0), $0.1) })
    }()
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
                    name: guid.flatMap(FlashDeviceMap.regionTypeName)
                        ?? guid.flatMap(KnownGUIDs.name(of:)) ?? "Flash device map entry",
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

extension Parser {
    /// `nodes` — what a raw-area scan found — with the regions its flash
    /// device maps name read out of the padding (`UEFI_IMAGE_FORMAT.md` §9).
    ///
    /// Insyde's map lays out the whole image, and some of what it names sits
    /// outside every volume with no signature of its own: the EC firmware, the
    /// BIOS version table, the SMBIOS update, the passwords, the default
    /// variables. The scan reads those bytes as padding, and so does UEFITool.
    /// Each such range that lies wholly inside a stretch of padding becomes a
    /// region named by its type, and the padding around it stays padding.
    /// Nothing is searched for: a region is only where the map puts one, and a
    /// range already read as something else — a volume, the NVRAM stores — is
    /// left to what read it.
    ///
    /// A `VAR_DEFAULT` region holds a run of `$VSS` stores — the firmware's
    /// default variables — and is walked the way an NVRAM volume's body is.
    /// The other regions are leaves: what is inside them is read, where it is
    /// read at all, by the region's own type.
    ///
    /// The map gives physical addresses, and this runs before the second pass
    /// has worked out the mapping — so it takes it from a Volume Top File at
    /// the image's tail, as address resolution does first. An image with no
    /// VTF at its tail — a BIOS region followed by another region — keeps the
    /// ranges as padding.
    func readingMapRegions(_ nodes: [UEFINode], emptyByte: UInt8, depth: Int) -> [UEFINode] {
        let maps = nodes.filter { $0.kind == .flashDeviceMapStore }
        guard !maps.isEmpty, let addressDiff = addressDiffFromTail() else { return nodes }

        var regions: [(type: EFIGUID, range: Range<UInt64>)] = []
        for map in maps {
            guard let base = reader.uint64(at: map.header.lowerBound + FlashDeviceMap.baseAddressOffset) else {
                continue
            }
            for entry in map.children where entry.kind == .flashDeviceMapEntry {
                let at = entry.header.lowerBound
                guard let type = entry.guid,
                      let offset = reader.uint64(at: at + FlashDeviceMap.regionOffsetOffset),
                      let size = reader.uint64(at: at + FlashDeviceMap.regionSizeOffset)
                else { continue }
                // The same arithmetic the protected ranges use (§5.3): 32 bits,
                // as the reference does.
                let address = UInt64(UInt32(truncatingIfNeeded: base) &+ UInt32(truncatingIfNeeded: offset))
                guard address >= addressDiff else { continue }
                let start = address - addressDiff
                let range = start..<(start + UInt64(UInt32(truncatingIfNeeded: size)))
                // A board can carry the map twice, and both copies name the
                // same ranges.
                if !range.isEmpty, !regions.contains(where: { $0.type == type && $0.range == range }) {
                    regions.append((type, range))
                }
            }
        }
        // In address order, so where two entries overlap the one that starts
        // first is placed and the other, no longer inside padding, stays out.
        regions.sort { $0.range.lowerBound < $1.range.lowerBound }

        var result = nodes
        for region in regions {
            guard let index = result.firstIndex(where: {
                $0.kind == .padding
                    && $0.range.lowerBound <= region.range.lowerBound
                    && region.range.upperBound <= $0.range.upperBound
            }) else { continue }
            var children: [UEFINode] = []
            if region.type == FlashDeviceMap.variableDefaults {
                let stores = walkNvramVolumeBody(region.range, emptyByte: emptyByte, depth: depth + 1)
                // A region nobody has written holds no stores, and says so by
                // having no children.
                if stores.contains(where: { $0.kind != .padding && $0.kind != .freeSpace }) {
                    children = stores
                }
            }
            let around = result[index].range
            result.replaceSubrange(
                index...index,
                with: padding(from: around.lowerBound, to: region.range.lowerBound, emptyByte: emptyByte)
                    + [UEFINode(
                        kind: .flashDeviceMapRegion,
                        name: FlashDeviceMap.regionTypeName(region.type)
                            ?? KnownGUIDs.name(of: region.type) ?? "Flash device map region",
                        guid: region.type,
                        header: region.range.lowerBound..<region.range.lowerBound,
                        body: region.range,
                        // The map pins it: it is where the map says, or the
                        // firmware does not find it.
                        isFixed: true,
                        isErased: children.isEmpty && reader.isFilled(region.range, with: emptyByte),
                        children: children
                    )]
                    + padding(from: region.range.upperBound, to: around.upperBound, emptyByte: emptyByte)
            )
        }
        return result
    }
}
