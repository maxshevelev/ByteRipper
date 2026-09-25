import Foundation

/// `INTEL_MICROCODE_HEADER` (§7.1).
///
/// Microcode is what the FIT table mostly points at, so recognising it is not
/// a luxury here: a tool-module editing FIT needs to know whether the address
/// in an entry lands on a microcode image, on an empty slot, or on nothing at
/// all — which is the whole of §11 of `FIT_TABLE_FORMAT.md`.
enum Microcode {
    static let headerSize: UInt64 = 0x30
    /// `HeaderType`, and the dword the raw scan looks for.
    static let headerType: UInt32 = 1
    static let loaderRevision: UInt32 = 1
    static let maxSize: UInt32 = 0xFF_FFFF
    /// A `DataSize` of zero means 2000 bytes, which the specification wrote
    /// down once and never repeated.
    static let defaultDataSize: UInt32 = 2000

    /// Every check of `intelMicrocodeHeaderValid`, all of them required — the
    /// dword `0x00000001` is far too common for any subset to do.
    static func headerIsValid(
        headerType: UInt32,
        loaderRevision: UInt32,
        dataSize: UInt32,
        totalSize: UInt32,
        year: UInt16,
        month: UInt8,
        day: UInt8
    ) -> Bool {
        guard headerType == Microcode.headerType,
              loaderRevision == Microcode.loaderRevision,
              dataSize % 4 == 0,
              dataSize <= maxSize,
              totalSize >= dataSize,
              totalSize <= maxSize
        else { return false }
        return isValidBCDDay(day) && isValidBCDMonth(month) && isValidBCDYear(year)
    }

    /// The date is packed BCD, and it is the only field in this header with
    /// enough structure to reject a false positive on its own.
    static func isValidBCDDay(_ day: UInt8) -> Bool {
        switch day {
        case 0x01...0x09, 0x10...0x19, 0x20...0x29, 0x30...0x31: return true
        default: return false
        }
    }

    static func isValidBCDMonth(_ month: UInt8) -> Bool {
        switch month {
        case 0x01...0x09, 0x10...0x12: return true
        default: return false
        }
    }

    static func isValidBCDYear(_ year: UInt16) -> Bool {
        switch year {
        case 0x1990...0x1999, 0x2000...0x2009, 0x2010...0x2019,
             0x2020...0x2029, 0x2030...0x2039, 0x2040...0x2049:
            return true
        default:
            return false
        }
    }
}

/// A microcode header that checked out, read back as values.
///
/// Public because a FIT table's entries point at these, and the tool-module
/// that edits FIT has to show which processor and which revision an entry
/// leads to. Reading them there instead would be §7.1 written down twice.
public struct MicrocodeHeader: Equatable, Sendable {
    public var offset: UInt64
    public var updateRevision: UInt32
    /// The date, as the packed BCD it is stored in.
    public var year: UInt16
    public var month: UInt8
    public var day: UInt8
    public var processorSignature: UInt32
    public var checksum: UInt32
    public var platformIDs: UInt32
    public var dataSize: UInt32
    public var totalSize: UInt32
    /// Whether the image's dwords, this field included, sum to zero (§7.1) —
    /// the check the loader runs, so a panel can say the checksum counts or not.
    public var checksumIsCorrect: Bool
    /// The value the checksum field would have to hold for the image's dwords
    /// to sum to zero — what a fix writes when the field is wrong. Nil when the
    /// image cannot be read whole, where there is no answer to give.
    public var computedChecksum: UInt32?
    /// `MetadataSize` (offset 0x24). Reserved, and zero, in every image made
    /// before the field was defined.
    public var metadataSize: UInt32
    /// The extended signature table behind the data, which an update carries
    /// when it fits more than one processor; nil when there is none.
    public var extendedTable: MicrocodeExtendedTable?

    public static let size: UInt64 = 0x30

    /// Reads a header and puts it through every check of §7.1. Nil means these
    /// bytes are not microcode — which is the usual answer, since the dword
    /// this starts with is `0x00000001`.
    public static func read(at offset: UInt64, in reader: ImageReader) -> MicrocodeHeader? {
        guard let headerType = reader.uint32(at: offset),
              let updateRevision = reader.uint32(at: offset + 0x04),
              let year = reader.uint16(at: offset + 0x08),
              let day = reader.uint8(at: offset + 0x0A),
              let month = reader.uint8(at: offset + 0x0B),
              let processorSignature = reader.uint32(at: offset + 0x0C),
              let checksum = reader.uint32(at: offset + 0x10),
              let loaderRevision = reader.uint32(at: offset + 0x14),
              let platformIDs = reader.uint32(at: offset + 0x18),
              let dataSize = reader.uint32(at: offset + 0x1C),
              let totalSize = reader.uint32(at: offset + 0x20),
              totalSize != 0,
              Microcode.headerIsValid(
                  headerType: headerType,
                  loaderRevision: loaderRevision,
                  dataSize: dataSize,
                  totalSize: totalSize,
                  year: year, month: month, day: day
              )
        else { return nil }

        // The image's dwords, the checksum field included, must sum to zero
        // (§7.1). The range is the whole image as `totalSize` declares it; a
        // truncated or ragged one has no zero sum, so it reads as not counting —
        // and, having no sum, has no value to say it should be.
        let sum = Checksums.sum32(
            of: offset..<(offset + UInt64(totalSize)), in: reader
        )
        let data = dataSize == 0 ? Microcode.defaultDataSize : dataSize

        return MicrocodeHeader(
            offset: offset,
            updateRevision: updateRevision,
            year: year, month: month, day: day,
            processorSignature: processorSignature,
            checksum: checksum,
            platformIDs: platformIDs,
            dataSize: dataSize,
            totalSize: totalSize,
            checksumIsCorrect: sum == 0,
            computedChecksum: sum.map { checksum &- $0 },
            metadataSize: reader.uint32(at: offset + 0x24) ?? 0,
            extendedTable: MicrocodeExtendedTable.read(
                at: offset + Microcode.headerSize + UInt64(data),
                end: offset + UInt64(totalSize),
                in: reader
            )
        )
    }

    /// Header and data together, as `TotalSize` gives it.
    public var range: Range<UInt64> { offset..<(offset + UInt64(totalSize)) }

    /// `2019-07-15`, unpacked from the BCD. The fields are already known to be
    /// valid BCD, or this header would not exist.
    public var date: String {
        String(format: "%04X-%02X-%02X", year, month, day)
    }

    /// The processor signature the way a CPUID is looked up — `806EA`, bare.
    public static func cpuid(_ signature: UInt32) -> String {
        String(signature, radix: 16, uppercase: true)
    }

    /// What the header says, row by row — the one reading the FIT panel shows
    /// for the microcode an entry points at and the UEFI panel shows for a
    /// microcode node, so the two name and spell every field alike.
    public var fields: [MicrocodeField] {
        fields(checksumIsCorrect: checksumIsCorrect, expectedChecksum: computedChecksum)
    }

    /// The same rows, with the checksum's verdict given by the caller — a panel
    /// whose word on checksums is a list of repairs keeps that word here too.
    public func fields(checksumIsCorrect: Bool, expectedChecksum: UInt32?) -> [MicrocodeField] {
        var fields = [
            MicrocodeField("CPUID", Self.cpuid(processorSignature)),
            MicrocodeField("Processor", Self.processorText(processorSignature)),
            // "Update revision", so it does not read as the same thing as a FIT
            // entry's own Version.
            MicrocodeField("Update revision", Self.hex(updateRevision)),
            MicrocodeField("Date", date),
            MicrocodeField("Platform IDs", Self.hex(platformIDs)),
            MicrocodeField("Platforms", Self.platformsText(platformIDs)),
            // Zero is not an empty update: the specification reads it as 2000
            // bytes, and the row says so rather than "Empty".
            MicrocodeField("Data size", dataSize == 0
                ? "0 — read as \(Self.size(Microcode.defaultDataSize))"
                : Self.size(dataSize)),
            MicrocodeField("Total size", Self.size(totalSize))
        ]
        if metadataSize != 0 {
            fields.append(MicrocodeField("Metadata size", Self.size(metadataSize)))
        }
        if let table = extendedTable {
            fields.append(MicrocodeField(
                "Extended signatures",
                table.signatures.isEmpty ? "None"
                    : table.signatures.map { Self.cpuid($0.processorSignature) }.joined(separator: ", ")
            ))
            fields.append(MicrocodeField(
                "Extended checksum",
                Checksums.text(table.checksum, valid: table.checksumIsCorrect,
                               expected: table.computedChecksum.map(UInt64.init), digits: 8),
                isProblem: !table.checksumIsCorrect
            ))
            if table.declaredSize != table.availableSize {
                fields.append(MicrocodeField(
                    "Extended table",
                    "\(table.count) signatures take \(Self.size(table.declaredSize)), "
                        + "the image leaves \(Self.size(table.availableSize))",
                    isProblem: true
                ))
            }
        }
        // The image's dword checksum, distinct from a FIT header's checksum
        // byte: whether the image sums to zero, and what the dword should be
        // when it does not (§7.1).
        fields.append(MicrocodeField(
            "Image checksum",
            Checksums.text(checksum, valid: checksumIsCorrect,
                           expected: expectedChecksum.map(UInt64.init), digits: 8),
            isProblem: !checksumIsCorrect
        ))
        return fields
    }

    /// The processor a signature names, the way CPUID leaf 1 is read: the
    /// family and model with their extended parts folded in — `0x806EA` is
    /// family 0x6, model 0x8E, stepping 0xA.
    public static func processorText(_ signature: UInt32) -> String {
        let stepping = signature & 0xF
        let model = (signature >> 4) & 0xF
        let family = (signature >> 8) & 0xF
        let type = (signature >> 12) & 0x3
        let extendedModel = (signature >> 16) & 0xF
        let extendedFamily = (signature >> 20) & 0xFF
        let displayFamily = family == 0xF ? family + extendedFamily : family
        let displayModel = family == 0x6 || family == 0xF ? extendedModel << 4 | model : model
        var text = "Family \(hex(displayFamily)), model \(hex(displayModel)), stepping \(hex(stepping))"
        if type != 0 { text += ", type \(type)" }
        return text
    }

    /// Which platforms an update is for: each set bit of the platform IDs is
    /// one value of the processor's `MSR_IA32_PLATFORM_ID` bits 52–50.
    public static func platformsText(_ platformIDs: UInt32) -> String {
        let bits = (0..<32).filter { platformIDs & (1 << $0) != 0 }
        return bits.isEmpty ? "None" : bits.map(String.init).joined(separator: ", ")
    }

    private static func hex<T: BinaryInteger>(_ value: T) -> String {
        "0x" + String(UInt64(truncatingIfNeeded: value), radix: 16, uppercase: true)
    }

    /// `0x40 (64)`: hex for the dump, decimal for the mind.
    private static func size<T: BinaryInteger>(_ value: T) -> String {
        value == 0 ? "Empty" : "\(hex(value)) (\(value))"
    }
}

/// The extended signature table an update carries behind its data when it
/// fits more than one processor: a count, a checksum, and for each further
/// processor its signature, platform IDs and checksum (Intel SDM, vol. 3,
/// "Microcode Update").
public struct MicrocodeExtendedTable: Equatable, Sendable {
    public struct Signature: Equatable, Sendable {
        public var processorSignature: UInt32
        public var platformIDs: UInt32
        /// The checksum the update would carry with this signature in the
        /// header instead.
        public var checksum: UInt32
    }

    public var offset: UInt64
    public var count: UInt32
    public var checksum: UInt32
    /// Whether the table's dwords, this checksum included, sum to zero.
    public var checksumIsCorrect: Bool
    /// The value the checksum would have to hold; nil when the table the
    /// count declares does not fit in the image.
    public var computedChecksum: UInt32?
    /// As many signatures as the count declares and the image has room for.
    public var signatures: [Signature]
    /// What the count says the table takes — 20 bytes and 12 per signature —
    /// and what the image's total size leaves for it.
    public var declaredSize: UInt64
    public var availableSize: UInt64

    static let headerSize: UInt64 = 20
    static let entrySize: UInt64 = 12

    /// The table between the end of the data and the end of the image; nil
    /// when there is no room for one, or its count is zero — bytes behind the
    /// data that list no processor are not a table.
    static func read(at offset: UInt64, end: UInt64, in reader: ImageReader) -> MicrocodeExtendedTable? {
        guard end >= offset + headerSize,
              let count = reader.uint32(at: offset), count != 0,
              let checksum = reader.uint32(at: offset + 4)
        else { return nil }
        let available = end - offset
        let declared = headerSize + UInt64(count) * entrySize
        let listed = min(UInt64(count), (available - headerSize) / entrySize)
        var signatures: [Signature] = []
        for index in 0..<listed {
            let at = offset + headerSize + index * entrySize
            guard let signature = reader.uint32(at: at),
                  let platformIDs = reader.uint32(at: at + 4),
                  let entryChecksum = reader.uint32(at: at + 8)
            else { break }
            signatures.append(Signature(processorSignature: signature, platformIDs: platformIDs,
                                        checksum: entryChecksum))
        }
        let sum = declared <= available ? Checksums.sum32(of: offset..<(offset + declared), in: reader) : nil
        return MicrocodeExtendedTable(
            offset: offset, count: count, checksum: checksum,
            checksumIsCorrect: sum == 0,
            computedChecksum: sum.map { checksum &- $0 },
            signatures: signatures,
            declaredSize: declared, availableSize: available
        )
    }
}

/// One row of a microcode header's reading (`MicrocodeHeader.fields`).
public struct MicrocodeField: Equatable, Sendable {
    public var label: String
    public var value: String
    /// A value that reads as a problem — a checksum that does not add up.
    public var isProblem: Bool

    public init(_ label: String, _ value: String, isProblem: Bool = false) {
        self.label = label
        self.value = value
        self.isProblem = isProblem
    }
}

extension Parser {
    /// One microcode image. Nil when the header does not check out, which
    /// leaves no diagnostic — `0x00000001` appears everywhere.
    func parseMicrocode(at offset: UInt64, limit: UInt64) -> UEFINode? {
        guard offset + Microcode.headerSize <= limit,
              let header = MicrocodeHeader.read(at: offset, in: reader)
        else { return nil }

        var end = header.range.upperBound
        if end > limit {
            note(.truncated(.microcodeHeader), at: offset + 0x20)
            end = limit
        }
        verifyMicrocodeChecksum(at: offset, end: end)

        return UEFINode(
            kind: .microcode,
            name: String(
                format: "Microcode %X, revision %X",
                header.processorSignature,
                header.updateRevision
            ),
            header: offset..<(offset + Microcode.headerSize),
            body: (offset + Microcode.headerSize)..<end,
            // Whatever FIT points at must not move (§11), and the FIT table
            // points at microcode. Deciding that here saves every tool-module
            // that reads this tree from having to.
            isFixed: true
        )
    }

    /// The whole image, dwords, sums to zero (§7.1).
    private func verifyMicrocodeChecksum(at offset: UInt64, end: UInt64) {
        guard (end - offset) % 4 == 0,
              let sum = Checksums.sum32(of: offset..<end, in: reader),
              sum != 0,
              let stored = reader.uint32(at: offset + 0x10)
        else { return }
        note(
            .checksumMismatch(
                .microcodeHeader,
                stored: UInt64(stored),
                computed: UInt64(stored &- sum)
            ),
            at: offset + 0x10
        )
    }
}
