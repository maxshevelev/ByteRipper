import Foundation
import Localization

/// Panasonic's DMI region, where the firmware of a Toughbook keeps what the
/// factory wrote of the machine (`UEFI_IMAGE_FORMAT.md` §9): the asset tag,
/// a serial, the Windows product key, and records nobody has documented. In
/// the padding inside the BIOS region, on a 4 KiB boundary — declared
/// nowhere, so found by its content: a header, a directory, and records the
/// directory lists.
///
/// ```
/// 0x00  "MEI_" and the model, "MEI_FZ55-2"   (MEI: Matsushita Electric Industrial)
/// 0x28  a model code, "FZ55FZ-52M4"
/// 0x3A  "MEI___CF"
/// 0x80  u16 the directory's length in 8-byte units, this one included;
///       u16 its checksum; u32 0
/// 0x88  {u32 ID, u32 address} per record
/// ```
///
/// An address is where the record is in the CPU's view of the flash — the
/// file offset plus 0xFE000000 on a 32 MiB chip, plus 0xFF800000 on an 8 MiB
/// one — so the block's own address is the first record's rounded down to
/// 4 KiB: the first record lies within the block's first 4 KiB, after the
/// directory. A record is its length, header included, an 8-bit checksum,
/// then its data: a u16 length and the checksum in some records, a u32
/// length, the checksum and three bytes nobody has explained in the others.
/// Records follow one another at the addresses the directory gives, back to
/// back or with a gap. Which form a record has is told by where the next one
/// starts and by its checksum, not by its ID.
///
/// Everything is checksummed the same way — the bytes sum to 0 modulo 256:
/// the header's first 0x80 bytes, the directory from 0x80 to its last slot,
/// and each record over its length. Held on the two dumps read — an FZ-55
/// mk2 and a CF-53 mk1 — for every one of them.
///
/// What the records hold is known for three: 0x02 the asset tag, 0x03 a
/// serial — whether the board's or the machine's is not known — and 0x16
/// the Windows product key. The layout is read off those two dumps, not a
/// published one, and the help says so.
public struct PanasonicDMIArea: Equatable, Sendable {
    /// The block sits on a 4 KiB boundary of the file.
    public static let alignment: UInt64 = 0x1000
    public static let signature: [UInt8] = Array("MEI_".utf8)
    /// How much of the block is the header the checksum at its end covers.
    static let headerSize: UInt64 = 0x80
    static let directoryOffset: UInt64 = 0x80
    static let slotsOffset: UInt64 = 0x88
    /// How much of a record is kept to read its fields from.
    static let recordHeadSize: UInt64 = 0x40

    /// The ID of the record that holds the asset tag.
    public static let assetTagID: UInt32 = 0x02
    /// The ID of the record that holds the serial.
    public static let serialID: UInt32 = 0x03
    /// The ID of the record that holds the Windows product key.
    public static let productKeyID: UInt32 = 0x16

    /// What a record of `id` holds, where that is known; nil for the rest.
    public static func meaning(of id: UInt32) -> LocalizedText? {
        switch id {
        case assetTagID: return L("Asset tag")
        case serialID: return L("Serial")
        case productKeyID: return L("Windows product key")
        default: return nil
        }
    }

    /// The length and the checksum a record's header holds: a u16 and a u8
    /// in a 3-byte header, a u32 and a u8 in an 8-byte one.
    public static func recordHeader(_ bytes: [UInt8]) -> (length: UInt32, checksum: UInt8)? {
        switch bytes.count {
        case 3: return (UInt32(bytes[0]) | UInt32(bytes[1]) << 8, bytes[2])
        case 8: return (u32(bytes, 0), bytes[4])
        default: return nil
        }
    }


    static func u32(_ bytes: [UInt8], _ at: Int) -> UInt32 {
        UInt32(bytes[at]) | UInt32(bytes[at + 1]) << 8 | UInt32(bytes[at + 2]) << 16 | UInt32(bytes[at + 3]) << 24
    }

    /// One record the directory lists.
    public struct Record: Equatable, Sendable {
        public var id: UInt32
        /// Where the directory says it is: in the CPU's view of the flash.
        public var address: UInt32
        /// Where it is in the file: from its length to the end of what the
        /// length counts.
        public var range: Range<UInt64>
        /// 3 where the length is a u16, 8 where it is a u32.
        public var headerSize: UInt64
        /// The checksum byte: the record's bytes sum to 0 with it.
        public var checksum: UInt8
        /// The byte that would make them.
        public var expectedChecksum: UInt8
        public var checksumIsValid: Bool { checksum == expectedChecksum }
        /// The record's first bytes, as far as `recordHeadSize`.
        public var head: [UInt8]

        public var header: Range<UInt64> { range.lowerBound..<(range.lowerBound + headerSize) }
        public var body: Range<UInt64> { header.upperBound..<range.upperBound }

        /// The record's data, as far as `head` holds it.
        var data: ArraySlice<UInt8> { head[min(Int(headerSize), head.count)...] }
    }

    public var offset: UInt64
    /// The header and the directory, as stored.
    public var header: [UInt8]
    /// The records, in file order.
    public var records: [Record]
    /// Whether the header's first 0x80 bytes sum to 0. Which of them is the
    /// checksum is not known.
    public var headerChecksumIsValid: Bool
    /// The directory's checksum, at +0x82, and the byte that would make the
    /// directory sum to 0.
    public var directoryChecksum: UInt8 { header[0x82] }
    public var expectedDirectoryChecksum: UInt8
    public var directoryChecksumIsValid: Bool { directoryChecksum == expectedDirectoryChecksum }

    /// From the header to the end of the last record.
    public var range: Range<UInt64> { offset..<(records.last?.range.upperBound ?? offset + UInt64(header.count)) }

    public init(offset: UInt64, header: [UInt8], records: [Record],
                headerChecksumIsValid: Bool, expectedDirectoryChecksum: UInt8) {
        self.offset = offset
        self.header = header
        self.records = records
        self.headerChecksumIsValid = headerChecksumIsValid
        self.expectedDirectoryChecksum = expectedDirectoryChecksum
    }

    // MARK: - The fields

    /// The model, as the header names it after "MEI_".
    public var model: String { Self.text(header[4..<0x10]) }

    /// The model code at +0x28.
    public var modelCode: String { Self.text(header[0x28..<0x38]) }

    public func record(_ id: UInt32) -> Record? { records.first { $0.id == id } }

    /// Where a record's text starts: at its data, or one byte on where the
    /// data opens with a byte that is not text — the serial's record does,
    /// with 01.
    private static func textStart(_ data: ArraySlice<UInt8>) -> Int {
        guard let first = data.first, !(0x20...0x7E).contains(first), data.count > 1,
              (0x20...0x7E).contains(data[data.startIndex + 1])
        else { return data.startIndex }
        return data.startIndex + 1
    }

    private func text(of id: UInt32) -> (start: UInt64, text: String)? {
        guard let record = record(id) else { return nil }
        let from = Self.textStart(record.data)
        let text = Self.text(record.head[from...])
        return text.isEmpty ? nil : (record.range.lowerBound + UInt64(from), text)
    }

    /// The asset tag, where written.
    public var assetTag: String? { text(of: Self.assetTagID)?.text }

    /// The serial, where written: the record's text up to its line end.
    public var serial: String? { text(of: Self.serialID)?.text }

    /// Where the product key lies in its record — after four u32s and its
    /// length — when it reads as one: five groups of five characters.
    var productKeyRange: Range<UInt64>? {
        guard let record = record(Self.productKeyID), record.headerSize == 8 else { return nil }
        let lengthAt = 0x18
        let keyAt = lengthAt + 4
        guard record.head.count >= keyAt + 29,
              Self.u32(record.head, lengthAt) == 29,
              Self.isProductKey(record.head[keyAt..<(keyAt + 29)])
        else { return nil }
        let start = record.range.lowerBound + UInt64(keyAt)
        return start..<(start + 29)
    }

    /// The Windows product key, where it reads as one.
    public var productKey: String? {
        guard let range = productKeyRange, let record = record(Self.productKeyID) else { return nil }
        let from = Int(range.lowerBound - record.range.lowerBound)
        return String(decoding: record.head[from..<(from + 29)], as: UTF8.self)
    }

    /// The fields the block keeps, in file order, each where it lies in the
    /// file: the rows under the block's and its records'.
    public var fields: [(record: UInt32?, field: DMIField)] {
        func text(_ name: LocalizedText, _ start: UInt64, _ text: String) -> DMIField {
            DMIField(name, range: start..<(start + UInt64(text.utf8.count)), encoding: .ascii)
        }
        var fields: [(UInt32?, DMIField)] = [
            (nil, text(L("Model"), offset + 4, model)),
            (nil, text(L("Model code"), offset + 0x28, modelCode))
        ]
        if let tag = self.text(of: Self.assetTagID) {
            fields.append((Self.assetTagID, text(L("Asset tag"), tag.start, tag.text)))
        }
        if let serial = self.text(of: Self.serialID) {
            fields.append((Self.serialID, text(L("Serial"), serial.start, serial.text)))
        }
        if let range = productKeyRange {
            fields.append((Self.productKeyID, DMIField(L("Windows product key"), range: range, encoding: .ascii)))
        }
        return fields
    }

    /// The run of printable text at the front of `bytes`.
    static func text(_ bytes: ArraySlice<UInt8>) -> String {
        String(decoding: bytes.prefix { (0x20...0x7E).contains($0) }, as: UTF8.self)
    }

    /// `XXXXX-XXXXX-XXXXX-XXXXX-XXXXX`, in capitals and digits.
    static func isProductKey(_ bytes: ArraySlice<UInt8>) -> Bool {
        bytes.enumerated().allSatisfy { index, byte in
            index % 6 == 5 ? byte == 0x2D : ((0x30...0x39).contains(byte) || (0x41...0x5A).contains(byte))
        }
    }

    // MARK: - Finding it

    /// The block at `offset`, when its header starts with the signature and
    /// its directory lists records that chain: each lies where the directory
    /// says, at rising addresses, its length ends it no later than the next
    /// one starts, and the last one ends before `end`. The checksums are not
    /// what finds it: a block whose sums fail is read all the same, and the
    /// details say which fail.
    public static func read(at offset: UInt64, end: UInt64, reader: ImageReader) -> PanasonicDMIArea? {
        guard offset % alignment == 0, offset + slotsOffset <= end,
              let header = reader.bytes(at: offset, count: slotsOffset),
              Array(header[0..<4]) == signature
        else { return nil }
        // The directory's length counts its own first eight bytes.
        let units = UInt64(header[0x80]) | UInt64(header[0x81]) << 8
        let directoryEnd = directoryOffset + 8 * units
        guard units >= 3, directoryEnd <= alignment, offset + directoryEnd <= end,
              let directory = reader.bytes(at: offset + slotsOffset, count: directoryEnd - slotsOffset)
        else { return nil }
        let entries = (0..<Int(units - 1))
            .map { (id: u32(directory, $0 * 8), address: u32(directory, $0 * 8 + 4)) }
            .filter { $0.id != 0 }
        guard entries.count >= 2 else { return nil }
        let base = UInt64(entries[0].address) & ~(alignment - 1)
        let starts = entries.map { offset &+ UInt64($0.address) &- base }
        guard starts[0] >= offset + directoryEnd,
              zip(starts, starts.dropFirst()).allSatisfy({ $0 < $1 }),
              starts.last! < end
        else { return nil }
        var records: [Record] = []
        for (index, entry) in entries.enumerated() {
            let start = starts[index]
            let limit = index + 1 < starts.count ? starts[index + 1] : end
            guard let lengths = reader.bytes(at: start, count: min(8, limit - start)), lengths.count >= 3 else {
                return nil
            }
            // Each form the header may have, where its length fits; the one
            // whose checksum holds, or else the long one.
            var forms: [(header: UInt64, length: UInt64, bytes: [UInt8])] = []
            if lengths.count == 8 {
                let long = UInt64(u32(lengths, 0))
                if long >= 8, start + long <= limit, let bytes = reader.bytes(at: start, count: long) {
                    forms.append((8, long, bytes))
                }
            }
            let short = UInt64(lengths[0]) | UInt64(lengths[1]) << 8
            if short >= 3, start + short <= limit, let bytes = reader.bytes(at: start, count: short) {
                forms.append((3, short, bytes))
            }
            guard let form = forms.first(where: { Checksums.sum8($0.bytes) == 0 }) ?? forms.first else { return nil }
            let checksum = form.bytes[form.header == 8 ? 4 : 2]
            records.append(Record(
                id: entry.id, address: entry.address, range: start..<(start + form.length),
                headerSize: form.header, checksum: checksum,
                expectedChecksum: checksum &- Checksums.sum8(form.bytes),
                head: Array(form.bytes.prefix(Int(recordHeadSize)))))
        }
        let all = header + directory
        return PanasonicDMIArea(
            offset: offset, header: all, records: records,
            headerChecksumIsValid: Checksums.sum8(header[0..<Int(headerSize)]) == 0,
            expectedDirectoryChecksum: all[0x82] &- Checksums.sum8(all[Int(directoryOffset)...]))
    }
}

extension Parser {
    /// `nodes` with every Panasonic DMI block read out of the padding it
    /// lies in, as a row with a row per record — on a 4 KiB boundary of the
    /// file, where the dump read from lays it.
    func readingPanasonicDMIStores(_ nodes: [UEFINode], emptyByte: UInt8) -> [UEFINode] {
        nodes.map { node in
            guard node.kind == .padding else { return node }
            var read = node
            if !node.children.isEmpty {
                read.children = readingPanasonicDMIStores(node.children, emptyByte: emptyByte)
                return read
            }
            guard !node.isErased else { return node }
            let body = node.body
            let step = PanasonicDMIArea.alignment
            var found: [PanasonicDMIArea] = []
            var at = (body.lowerBound + step - 1) / step * step
            while at + PanasonicDMIArea.slotsOffset <= body.upperBound {
                if reader.bytes(at: at, count: 4) == PanasonicDMIArea.signature,
                   let area = PanasonicDMIArea.read(at: at, end: body.upperBound, reader: reader) {
                    found.append(area)
                    at = (area.range.upperBound + step - 1) / step * step
                } else {
                    at += step
                }
            }
            guard !found.isEmpty else { return node }
            var rows: [UEFINode] = []
            var claimed = body.lowerBound
            for area in found {
                rows += padding(from: claimed, to: area.offset, emptyByte: emptyByte)
                rows.append(Self.panasonicDMIRow(area))
                claimed = area.range.upperBound
            }
            read.children = rows + padding(from: claimed, to: body.upperBound, emptyByte: emptyByte)
            return read
        }
    }

    /// The block's row: its header's fields, then a row per record, the
    /// fields a record holds under it.
    static func panasonicDMIRow(_ area: PanasonicDMIArea) -> UEFINode {
        let fields = area.fields
        var row = UEFINode(kind: .panasonicDMIStore, named: L("Panasonic DMI"), range: area.range)
        row.isFixed = true
        row.children = fields.filter { $0.record == nil }.map { $0.field.node(isFixed: true) }
            + area.records.map { record in
                var node = UEFINode(
                    kind: .panasonicDMIRecord,
                    subtype: record.id <= UInt32(UInt8.max) ? UInt8(record.id) : nil,
                    named: L("Record %1$@", String(format: "0x%02X", record.id)),
                    header: record.header,
                    body: record.body,
                    isFixed: true
                )
                node.children = fields.filter { $0.record == record.id }.map { $0.field.node(isFixed: true) }
                return node
            }
        return row
    }
}
