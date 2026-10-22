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
/// 0x80  u16, u16 — both 0x0F on the dump read; their meaning is unknown
/// 0x88  {u32 ID, u32 address} per record, to an ID of 0
/// ```
///
/// An address is where the record is in the CPU's view of the flash — on a
/// 32 MiB chip the file offset plus 0xFE000000 — so the block's own address
/// is the first record's rounded down to 4 KiB: the first record lies
/// within the block's first 4 KiB, after the directory. A record starts
/// with its length, header included, and an unknown value: a u16 and a u16
/// in some records, a u32 and a u32 in the others; the next record starts
/// at the next 16-byte boundary. Which form a record has is told by where
/// the next one starts, not by its ID.
///
/// What the records hold is known for three: 0x02 the asset tag, 0x03 a
/// serial — whether the board's or the machine's is not known — and 0x16
/// the Windows product key. The layout is read off one dump of an FZ-55 mk2,
/// not a published one, and the help says so.
public struct PanasonicDMIArea: Equatable, Sendable {
    /// The block sits on a 4 KiB boundary of the file.
    public static let alignment: UInt64 = 0x1000
    public static let signature: [UInt8] = Array("MEI_".utf8)
    /// How much of the block is read as its header: the strings and the
    /// directory.
    static let headerSize: UInt64 = 0x100
    static let directoryOffset = 0x88
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

    /// The length and the unknown value a record's header holds: a u16 and
    /// a u16 in a 4-byte header, a u32 and a u32 in an 8-byte one.
    public static func recordHeader(_ bytes: [UInt8]) -> (length: UInt32, tag: UInt32)? {
        func value(_ from: Int, _ count: Int) -> UInt32 {
            (0..<count).reduce(0) { $0 | UInt32(bytes[from + $1]) << ($1 * 8) }
        }
        switch bytes.count {
        case 4: return (value(0, 2), value(2, 2))
        case 8: return (value(0, 4), value(4, 4))
        default: return nil
        }
    }

    /// One record the directory lists.
    public struct Record: Equatable, Sendable {
        public var id: UInt32
        /// Where the directory says it is: in the CPU's view of the flash.
        public var address: UInt32
        /// Where it is in the file: from its length to the end of what the
        /// length counts.
        public var range: Range<UInt64>
        /// 4 where the length is a u16, 8 where it is a u32.
        public var headerSize: UInt64
        /// The value after the length: a checksum or a tag, nobody knows.
        public var tag: UInt32
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

    /// From the header to the end of the last record.
    public var range: Range<UInt64> { offset..<(records.last?.range.upperBound ?? offset + Self.headerSize) }

    public init(offset: UInt64, header: [UInt8], records: [Record]) {
        self.offset = offset
        self.header = header
        self.records = records
    }

    // MARK: - The fields

    /// The model, as the header names it after "MEI_".
    public var model: String { Self.text(header[4..<0x10]) }

    /// The model code at +0x28.
    public var modelCode: String { Self.text(header[0x28..<0x38]) }

    public func record(_ id: UInt32) -> Record? { records.first { $0.id == id } }

    /// The asset tag, where written.
    public var assetTag: String? {
        record(Self.assetTagID).map { Self.text($0.data) }.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The serial, where written: the record's text up to its line end.
    public var serial: String? {
        record(Self.serialID).map { Self.text($0.data) }.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Where the product key lies in its record — after four u32s and its
    /// length — when it reads as one: five groups of five characters.
    var productKeyRange: Range<UInt64>? {
        guard let record = record(Self.productKeyID) else { return nil }
        let lengthAt = Int(record.headerSize) + 0x10
        let keyAt = lengthAt + 4
        guard record.head.count >= keyAt + 29,
              UInt32(record.head[lengthAt]) | UInt32(record.head[lengthAt + 1]) << 8
                | UInt32(record.head[lengthAt + 2]) << 16 | UInt32(record.head[lengthAt + 3]) << 24 == 29,
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
        func text(_ name: LocalizedText, _ start: UInt64, _ bytes: ArraySlice<UInt8>) -> DMIField {
            let length = UInt64(bytes.prefix { (0x20...0x7E).contains($0) }.count)
            return DMIField(name, range: start..<(start + length), encoding: .ascii)
        }
        var fields: [(UInt32?, DMIField)] = [
            (nil, text(L("Model"), offset + 4, header[4..<0x10])),
            (nil, text(L("Model code"), offset + 0x28, header[0x28..<0x38]))
        ]
        if let record = record(Self.assetTagID), assetTag != nil {
            fields.append((record.id, text(L("Asset tag"), record.body.lowerBound, record.data)))
        }
        if let record = record(Self.serialID), serial != nil {
            fields.append((record.id, text(L("Serial"), record.body.lowerBound, record.data)))
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
    /// says, its length ends it where the next one starts — on the next
    /// 16-byte boundary — and the last one ends before `end`.
    public static func read(at offset: UInt64, end: UInt64, reader: ImageReader) -> PanasonicDMIArea? {
        guard offset % alignment == 0, offset + headerSize <= end,
              let header = reader.bytes(at: offset, count: headerSize),
              Array(header[0..<4]) == signature
        else { return nil }
        func u32(_ bytes: [UInt8], _ at: Int) -> UInt32 {
            UInt32(bytes[at]) | UInt32(bytes[at + 1]) << 8 | UInt32(bytes[at + 2]) << 16 | UInt32(bytes[at + 3]) << 24
        }
        // The directory, to its zero ID; it may run on past the header's
        // 0x100 bytes only as far as the first record.
        var entries: [(id: UInt32, address: UInt32)] = []
        var at = UInt64(directoryOffset)
        while true {
            guard let pair = reader.bytes(at: offset + at, count: 8), at + 8 <= alignment else { return nil }
            let id = u32(pair, 0)
            if id == 0 { break }
            entries.append((id, u32(pair, 4)))
            at += 8
        }
        guard entries.count >= 2 else { return nil }
        let base = UInt64(entries[0].address) & ~(alignment - 1)
        let starts = entries.map { offset + UInt64($0.address) &- base }
        guard starts[0] >= offset + at + 8,
              zip(starts, starts.dropFirst()).allSatisfy({ $0 < $1 }),
              starts.last! < end
        else { return nil }
        var records: [Record] = []
        for (index, entry) in entries.enumerated() {
            let start = starts[index]
            guard let lengths = reader.bytes(at: start, count: 8) else { return nil }
            let long = UInt64(u32(lengths, 0))
            let short = long & 0xFFFF
            let next = index + 1 < starts.count ? starts[index + 1] : nil
            func fits(_ length: UInt64, header: UInt64) -> Bool {
                guard length >= header else { return false }
                if let next { return (start + length + 15) & ~15 == next }
                return start + length <= end
            }
            let headerSize: UInt64
            let length: UInt64
            let tag: UInt32
            if fits(long, header: 8) {
                (headerSize, length, tag) = (8, long, u32(lengths, 4))
            } else if fits(short, header: 4) {
                (headerSize, length, tag) = (4, short, UInt32(long >> 16))
            } else {
                return nil
            }
            let head = reader.bytes(at: start, count: min(length, recordHeadSize)) ?? []
            records.append(Record(id: entry.id, address: entry.address, range: start..<(start + length),
                                  headerSize: headerSize, tag: tag, head: head))
        }
        return PanasonicDMIArea(offset: offset, header: header, records: records)
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
            while at + PanasonicDMIArea.headerSize <= body.upperBound {
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
