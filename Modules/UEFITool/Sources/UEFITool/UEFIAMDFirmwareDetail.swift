import Foundation
import Localization
import UEFIImage

/// What the details say of the AMD PSP's map (`AMDFirmware`): the EFS and
/// the directories it points at, a directory and every entry it lists, a
/// blob and the entries that list it. Read again from the file on each
/// selection — a few kilobytes of headers — since the node keeps only its
/// place and its name.
///
/// Where an entry's blob is a row of the tree, its line leads to the row;
/// where it is something else's bytes — a compressed BIOS image inside a
/// volume, a store across a volume's edge — to its bytes in the dump.
enum UEFIAMDFirmwareDetail {
    static func build(for node: UEFINode, image: UEFIImage, reader: ImageReader,
                      repairs: [ChecksumRepair], in language: AppLanguage) -> (fields: [UEFIDetailField], tables: [UEFIDetailTable]) {
        guard node.space == .file, let firmware = AMDFirmware.read(reader) else { return ([], []) }
        switch node.kind {
        case .amdEFS:
            return efs(firmware, image: image, in: language)
        case .amdDirectory:
            guard let directory = firmware.directories.first(where: { $0.offset == node.header.lowerBound })
            else { return ([], []) }
            return self.directory(directory, in: firmware, image: image, repairs: repairs, in: language)
        case .amdFirmwareEntry:
            return blob(node, in: firmware, image: image, in: language)
        default:
            return ([], [])
        }
    }

    // MARK: - The EFS

    private static func efs(_ firmware: AMDFirmware, image: UEFIImage, in language: AppLanguage) -> ([UEFIDetailField], [UEFIDetailTable]) {
        let fields = [
            UEFIDetailField("Signature", hex(AMDFirmware.efsSignature)),
            UEFIDetailField(L("Flash size", in: language), sizeText(firmware.romSize)),
        ]
        var rows: [[UEFIDetailTable.Cell]] = []
        var targets: [UEFIDetailTable.Target?] = []
        for pointer in firmware.pointers {
            let directory = firmware.directories.first { $0.offset == pointer.target }
            rows.append([.init("+" + hex(pointer.field)), .init(hex(pointer.value)),
                         .init(directory.map { AMDFirmware.directoryName($0).text(in: language) } ?? "")])
            targets.append(directory.flatMap { target(for: $0.range, named: AMDFirmware.directoryName($0).text(in: language), in: image) })
        }
        let table = UEFIDetailTable(
            title: L("Directories", in: language), symbol: "list.bullet.indent",
            columns: [L("Field", in: language), L("Value", in: language), L("Directory", in: language)], rows: rows,
            rowTargets: targets, linkColumn: 1
        )
        return (fields, [table])
    }

    // MARK: - A directory

    private static func directory(_ directory: AMDFirmware.Directory, in firmware: AMDFirmware,
                                  image: UEFIImage, repairs: [ChecksumRepair], in language: AppLanguage)
        -> ([UEFIDetailField], [UEFIDetailTable]) {
        var fields: [UEFIDetailField] = []
        if let signature = directory.kind.signature { fields.append(.init("Signature", signature)) }
        if let stored = directory.storedChecksum {
            let repair = repairs.first { $0.offset == directory.offset + 4 }
            let expected = repair.map { $0.bytes.reversed().reduce(UInt64(0)) { $0 << 8 | UInt64($1) } }
            fields.append(.init("Checksum", Checksums.text(stored, valid: repair == nil, expected: expected, digits: 8).text(in: language),
                                isProblem: repair != nil))
        }
        if let pspID = directory.pspID { fields.append(.init("PSP ID", hex(pspID))) }

        if directory.kind == .slotHeader {
            if let slot = directory.slot { fields.append(.init(L("Slot", in: language), slot)) }
            if let priority = directory.priority { fields.append(.init(L("Priority", in: language), hex(priority))) }
            guard let target = directory.slotTarget,
                  let level2 = firmware.directories.first(where: { $0.offset == target }) else { return (fields, []) }
            let name = AMDFirmware.directoryName(level2).text(in: language)
            let table = UEFIDetailTable(
                title: L("Second level", in: language), symbol: "list.bullet.indent",
                columns: [L("Directory", in: language), L("Location", in: language)],
                rows: [[.init(name), .init(hex(target))]],
                rowTargets: [self.target(for: level2.range, named: name, in: image)]
            )
            return (fields, [table])
        }

        if directory.kind.isCombo {
            fields.append(.init(L("Entries", in: language), "\(directory.comboEntries.count)"))
            var rows: [[UEFIDetailTable.Cell]] = []
            var targets: [UEFIDetailTable.Target?] = []
            for (index, entry) in directory.comboEntries.enumerated() {
                let chosen = entry.resolvedOffset.flatMap { offset in firmware.directories.first { $0.offset == offset } }
                rows.append([.init("\(index)"), .init(hex(entry.id)),
                             .init(entry.resolvedOffset.map(hex) ?? "—"),
                             .init(chosen.map { AMDFirmware.directoryName($0).text(in: language) } ?? "")])
                targets.append(chosen.flatMap { target(for: $0.range, named: AMDFirmware.directoryName($0).text(in: language), in: image) })
            }
            let table = UEFIDetailTable(
                title: L("Directories", in: language), symbol: "list.bullet.indent",
                columns: ["#", entryIDColumn(directory, in: language), L("Location", in: language), L("Directory", in: language)],
                rows: rows, rowTargets: targets, linkColumn: 2
            )
            return (fields, [table])
        }

        fields.append(.init(L("Entries", in: language), "\(directory.entries.count)"))
        fields.append(.init(L("Address mode", in: language), addressModeText(directory.addressMode, in: language)))
        var rows: [[UEFIDetailTable.Cell]] = []
        var targets: [UEFIDetailTable.Target?] = []
        for entry in directory.entries {
            rows.append([
                .init("\(entry.index)"),
                .init(String(format: "%@ (0x%02X)", entry.typeName, entry.type)),
                .init(entry.isValue ? "—" : sizeText(entry.range.map { UInt64($0.count) } ?? UInt64(entry.size))),
                .init(entry.isValue ? "—" : entry.resolvedOffset.map(hex) ?? "—"),
                .init(notes(entry, file: image.size, in: language)),
            ])
            targets.append(entryTarget(entry, in: firmware, image: image, in: language))
        }
        let table = UEFIDetailTable(
            title: L("Entries", in: language), symbol: "list.bullet.rectangle",
            columns: ["#", L("Type", in: language), L("Size", in: language), L("Location", in: language), L("Notes", in: language)],
            rows: rows, rowTargets: targets, linkColumn: 3
        )
        return (fields, [table])
    }

    /// A combo directory's ids are PSP ids, unless its header says chip
    /// family ids.
    private static func entryIDColumn(_ directory: AMDFirmware.Directory, in language: AppLanguage) -> String {
        directory.info == 1 ? L("Chip family ID", in: language) : "PSP ID"
    }

    /// Where an entry leads: the directory it points at, or its blob — a row,
    /// or bytes in the dump.
    private static func entryTarget(_ entry: AMDFirmware.Entry, in firmware: AMDFirmware,
                                    image: UEFIImage, in language: AppLanguage) -> UEFIDetailTable.Target? {
        if entry.pointsAtDirectory, let offset = entry.resolvedOffset,
           let directory = firmware.directories.first(where: { $0.offset == offset }) {
            return target(for: directory.range, named: AMDFirmware.directoryName(directory).text(in: language), in: image)
        }
        guard let range = entry.range else { return nil }
        // The blob the tree reads is the one the smallest entry names.
        let blob = firmware.blobs.first { $0.entry.range?.lowerBound == range.lowerBound }?.entry.range ?? range
        return target(for: blob, named: AMDFirmware.entryName(entry).text(in: language), in: image)
    }

    /// The row that is exactly `range`; else the FFS structure that holds
    /// all of it — the Zlib section a compressed BIOS image sits in — and the
    /// bytes when there is neither.
    static func target(for range: Range<UInt64>, named name: String, in image: UEFIImage) -> UEFIDetailTable.Target {
        let chain = image.nodes(containing: range.lowerBound)
        if let node = chain.last(where: { $0.fileRange == range }) {
            return .node(node.id)
        }
        if let holder = chain.last(where: { node in
            [.section, .file, .volume].contains(node.kind)
                && node.fileRange.map { $0.lowerBound <= range.lowerBound && range.upperBound <= $0.upperBound } == true
        }) {
            return .node(holder.id)
        }
        return .range(range, name: name)
    }

    /// What an entry's flags, instance and destination say, in a few words.
    private static func notes(_ entry: AMDFirmware.Entry, file size: UInt64, in language: AppLanguage) -> String {
        var parts: [String] = []
        if entry.isValue { parts.append(L("value %1$@", in: language, hex(entry.location))) }
        if entry.instance != 0 { parts.append(L("instance %1$@", in: language, "\(entry.instance)")) }
        if entry.subprogram != 0 { parts.append(L("subprogram %1$@", in: language, "\(entry.subprogram)")) }
        if entry.isCompressed {
            parts.append(L("compressed, inflates to %1$@", in: language, hex(entry.size)))
        }
        if entry.isReset { parts.append(L("reset image", in: language)) }
        if entry.isCopy { parts.append(L("copied to memory", in: language)) }
        if entry.isReadOnly { parts.append(L("read-only", in: language)) }
        if entry.isWritable { parts.append(L("writable", in: language)) }
        if let destination = entry.destination, destination != 0xFFFF_FFFF_FFFF_FFFF, destination != 0 {
            parts.append(L("destination %1$@", in: language, hex(destination)))
        }
        if !entry.isValue, entry.range == nil, let offset = entry.resolvedOffset, entry.size > 0,
           offset + UInt64(entry.size) > size {
            parts.append(L("outside the image", in: language))
        }
        return parts.joined(separator: ", ")
    }

    private static func addressModeText(_ mode: AMDFirmware.AddressMode, in language: AppLanguage) -> String {
        switch mode {
        case .physical: return L("Memory-mapped address", in: language)
        case .flashOffset: return L("Offset in the flash", in: language)
        case .directoryRelative: return L("Offset from the directory, or as each entry says", in: language)
        case .slotRelative: return L("Offset from the slot, or as each entry says", in: language)
        }
    }

    // MARK: - A blob

    private static func blob(_ node: UEFINode, in firmware: AMDFirmware, image: UEFIImage, in language: AppLanguage)
        -> ([UEFIDetailField], [UEFIDetailTable]) {
        let start = node.range.lowerBound
        var listings: [(entry: AMDFirmware.Entry, directory: AMDFirmware.Directory)] = []
        for directory in firmware.directories {
            for entry in directory.entries where entry.range?.lowerBound == start && !entry.pointsAtDirectory {
                listings.append((entry, directory))
            }
        }
        guard let first = listings.first else { return ([], []) }
        let entry = first.entry
        var fields: [UEFIDetailField] = [.init(L("Entry type", in: language), String(format: "%@ (0x%02X)", entry.typeName, entry.type))]
        if entry.instance != 0 { fields.append(.init(L("Instance", in: language), "\(entry.instance)")) }
        if entry.isBIOS, entry.subtype != 0 { fields.append(.init(L("Region type", in: language), hex(entry.subtype))) }
        if entry.subprogram != 0 { fields.append(.init(L("Subprogram", in: language), "\(entry.subprogram)")) }
        let flags = notes(entry, file: image.size, in: language)
        if !flags.isEmpty { fields.append(.init(L("Entry flags", in: language), flags)) }
        if entry.isStoredCompressed {
            fields.append(.init(L("Compressed size", in: language), sizeText(UInt64(node.body.count))))
        }
        // A blob the directories give different room says so.
        let sizes = Set(listings.map(\.entry.size))
        if sizes.count > 1 || (sizes.first.map { UInt64($0) != UInt64(node.range.count) } ?? false), !entry.isCompressed {
            fields.append(.init(L("Size in the directories", in: language), sizes.sorted().map { hex($0) }.joined(separator: ", ")))
        }

        var rows: [[UEFIDetailTable.Cell]] = []
        var targets: [UEFIDetailTable.Target?] = []
        for listing in listings {
            let name = AMDFirmware.directoryName(listing.directory).text(in: language)
            rows.append([.init(name), .init("\(listing.entry.index)")])
            targets.append(target(for: listing.directory.range, named: name, in: image))
        }
        let table = UEFIDetailTable(
            title: L("Listed in", in: language), symbol: "list.bullet.indent",
            columns: [L("Directory", in: language), "#"], rows: rows, rowTargets: targets, linkColumn: 0
        )
        return (fields, [table])
    }

    // MARK: - Text

    private static func hex<T: BinaryInteger>(_ value: T) -> String {
        "0x" + String(UInt64(truncatingIfNeeded: value), radix: 16, uppercase: true)
    }

    private static func sizeText(_ value: UInt64) -> String {
        value == 0 ? "Empty" : "\(hex(value)) (\(value))"
    }
}
