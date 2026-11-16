import Foundation
import Localization

/// InsydeH2O's `$DMI` store, where the firmware keeps the values written over
/// its own SMBIOS tables (`UEFI_IMAGE_FORMAT.md` §9): the serial numbers,
/// the UUID, the model, the SKU. The range the flash device map names
/// `SMBIOS Update`; found by its content all the same, on a 4 KiB boundary
/// of the padding inside the BIOS region, as Panasonic's area is.
///
/// ```
/// 0x00  "$DMI"
/// 0x04  records, back to back:
///       u8  SMBIOS structure type
///       u8  the field's offset in the structure
///       u8  FF the record in force, 00 one a later record replaced
///       u16 the record's length, these five bytes included
///       the value: a string without its NUL, or the field's bytes
/// then  FF to the end of the store
/// ```
///
/// Read off five boards: two Huawei (H98M, DA0H9RMBAF0), an Acer Swift
/// SF314-57 (Floris Yebisu) and a Schenker Slim15; Lenovo, Acer and Floris
/// boards keep the store with no record in it. No checksum: every record and
/// the tail held with none.
///
/// The store is a log. Flash turns bits from 1 to 0 without an erase, so a
/// field is written again by appending a record, its third byte left FF, and
/// clearing the third byte of the record it replaces to 00. On every store
/// read each field has exactly one record with FF, its last; the earlier ones
/// read 00 — the DMI tool writes every field again on each run, so most
/// fields read as a pair, and the Schenker's UUID was written with another
/// value before the one in force. That the firmware reads the FF record is
/// what the log implies, not something checked against a running machine's
/// tables; the open questions are listed in `UEFI_IMAGE_FORMAT.md` §9.
public struct InsydeDMIArea: Equatable, Sendable {
    /// The store sits on a 4 KiB boundary of the file.
    public static let alignment: UInt64 = 0x1000
    public static let signature: [UInt8] = Array("$DMI".utf8)
    /// How much of the store, from the signature, must be its records and
    /// then FF: the flash device map gives the H98M's store 4 KiB, and every
    /// store read has at least that much behind its signature.
    public static let minimumSize: UInt64 = 0x1000
    static let recordHeaderSize: UInt64 = 5

    /// One record: a value for one field of one SMBIOS structure.
    public struct Record: Equatable, Sendable {
        /// The SMBIOS structure type: 1 the system, 2 the board, 3 the
        /// chassis, 11 the OEM strings.
        public var type: UInt8
        /// The field's offset in the structure, as SMBIOS lays it out; for
        /// the OEM strings what it counts is not known.
        public var field: UInt8
        /// The third byte: FF while the record is in force, 00 once a later
        /// record of the same field replaced it.
        public var flag: UInt8
        /// Whether the record is the one in force: its flag still FF.
        public var isCurrent: Bool { flag == 0xFF }
        /// From the record's first byte to the end its length gives.
        public var range: Range<UInt64>

        public var header: Range<UInt64> { range.lowerBound..<(range.lowerBound + InsydeDMIArea.recordHeaderSize) }
        public var body: Range<UInt64> { header.upperBound..<range.upperBound }

        public init(type: UInt8, field: UInt8, flag: UInt8, range: Range<UInt64>) {
            self.type = type
            self.field = field
            self.flag = flag
            self.range = range
        }

        /// Whether the value is the system's UUID: 16 bytes, not a string.
        public var isUUID: Bool { type == 1 && field == 0x08 && body.count == 16 }
    }

    public var offset: UInt64
    /// The records, in file order.
    public var records: [Record]

    /// From the signature to the end of the last record.
    public var range: Range<UInt64> {
        offset..<(records.last?.range.upperBound ?? offset + UInt64(Self.signature.count))
    }

    public init(offset: UInt64, records: [Record]) {
        self.offset = offset
        self.records = records
    }

    // MARK: - What a record holds

    /// The SMBIOS field a record writes, by its structure type and offset;
    /// nil for one this list does not name.
    public static func meaning(type: UInt8, field: UInt8) -> LocalizedText? {
        switch (type, field) {
        case (0, 0x04): return L("BIOS vendor")
        case (0, 0x05): return L("BIOS version")
        case (0, 0x08): return L("BIOS release date")
        case (1, 0x04): return L("System manufacturer")
        case (1, 0x05): return L("Product name")
        case (1, 0x06): return L("System version")
        case (1, 0x07): return L("System serial number")
        case (1, 0x08): return L("UUID")
        case (1, 0x19): return L("SKU")
        case (1, 0x1A): return L("Product family")
        case (2, 0x04): return L("Board manufacturer")
        case (2, 0x05): return L("Board name")
        case (2, 0x06): return L("Board version")
        case (2, 0x07): return L("Board serial number")
        case (2, 0x08): return L("Board asset tag")
        case (3, 0x04): return L("Chassis manufacturer")
        case (3, 0x06): return L("Chassis version")
        case (3, 0x07): return L("Chassis serial number")
        case (3, 0x08): return L("Chassis asset tag")
        // At 0x15 only in a chassis structure that lists no contained
        // elements, as the boards read do.
        case (3, 0x15): return L("Chassis SKU")
        case (11, _): return L("OEM string")
        default: return nil
        }
    }

    /// The record's value as one field of its own bytes: the UUID as SMBIOS
    /// stores one, anything else as text.
    public func field(of record: Record) -> DMIField {
        DMIField(Self.name(of: record), range: record.body, encoding: record.isUUID ? .smbiosUUID : .ascii)
    }

    /// What a record is called: the field it writes, or its structure type
    /// and offset where the field is not one this list names.
    public static func name(of record: Record) -> LocalizedText {
        meaning(type: record.type, field: record.field)
            ?? L("Type %1$@, offset %2$@", "\(record.type)", String(format: "0x%02X", record.field))
    }

    /// The record a row of the tree is, read back from its header and body.
    public static func record(of node: UEFINode, reader: ImageReader) -> Record? {
        guard node.kind == .insydeDMIRecord, let header = reader.bytes(node.header), header.count == 5 else {
            return nil
        }
        return Record(type: header[0], field: header[1], flag: header[2], range: node.range)
    }

    /// A record's value: the UUID as SMBIOS stores one, anything else as
    /// text; nil where its bytes are not there.
    public static func value(of record: Record, reader: ImageReader) -> String? {
        reader.bytes(record.body).map { DMIField.text(of: $0, as: record.isUUID ? .smbiosUUID : .ascii) }
    }

    /// The records of each field, in the order each field first appears.
    var byField: [[Record]] {
        var order: [UInt16] = []
        var held: [UInt16: [Record]] = [:]
        for record in records {
            let key = UInt16(record.type) << 8 | UInt16(record.field)
            if held[key] == nil { order.append(key) }
            held[key, default: []].append(record)
        }
        return order.compactMap { held[$0] }
    }

    /// The record of a field in force: the one whose flag is still FF, or the
    /// last where no record or more than one has it — a log the tool left
    /// half written, which no dump read shows.
    static func current(of records: [Record]) -> Record? {
        let current = records.filter(\.isCurrent)
        return current.count == 1 ? current[0] : records.last
    }

    /// One value per field the store writes, in the order each first
    /// appears, each read from the record in force.
    public var fields: [DMIField] {
        byField.compactMap(Self.current(of:)).map(field(of:))
    }

    /// The fields whose records do not mark one record in force: none, or
    /// more than one, with FF. Their value is read from the last record.
    public var fieldsWithoutOneCurrent: [LocalizedText] {
        byField.filter { $0.filter(\.isCurrent).count != 1 }.compactMap(\.first).map(Self.name(of:))
    }

    /// The value of the record in force of `field` of structure `type`, as
    /// text; nil where none writes it.
    public func text(type: UInt8, field: UInt8, reader: ImageReader) -> String? {
        guard let record = Self.current(of: records.filter { $0.type == type && $0.field == field }),
              let bytes = reader.bytes(record.body)
        else { return nil }
        let text = DMIField.text(of: bytes, as: record.isUUID ? .smbiosUUID : .ascii)
        return text.isEmpty ? nil : text
    }

    // MARK: - Finding it

    /// The store at `offset`, when it opens with the signature, its records
    /// chain from there — each at least its header long and ending inside
    /// the store's first 4 KiB — up to a byte FF where the next record would
    /// start, and everything from there to 4 KiB past the signature is FF.
    /// A store with no record, the signature and FF, is one too: the
    /// firmware keeps it so on most boards.
    public static func read(at offset: UInt64, end: UInt64, reader: ImageReader) -> InsydeDMIArea? {
        let storeEnd = offset + minimumSize
        guard offset % alignment == 0, storeEnd <= end,
              let bytes = reader.bytes(at: offset, count: minimumSize),
              Array(bytes[0..<4]) == signature
        else { return nil }
        var records: [Record] = []
        var at = Int(signature.count)
        while at < bytes.count, bytes[at] != 0xFF {
            guard at + Int(recordHeaderSize) <= bytes.count else { return nil }
            let length = Int(bytes[at + 3]) | Int(bytes[at + 4]) << 8
            guard length >= Int(recordHeaderSize), at + length <= bytes.count else { return nil }
            let start = offset + UInt64(at)
            records.append(Record(type: bytes[at], field: bytes[at + 1], flag: bytes[at + 2],
                                  range: start..<(start + UInt64(length))))
            at += length
        }
        guard bytes[at...].allSatisfy({ $0 == 0xFF }) else { return nil }
        return InsydeDMIArea(offset: offset, records: records)
    }
}

extension Parser {
    /// `nodes` with every `$DMI` store read out of the padding it lies in, as
    /// a row with a row per record — on a 4 KiB boundary of the file. The
    /// padding is the range the flash device map names `SMBIOS Update` where
    /// it has one, plain padding otherwise.
    func readingInsydeDMIStores(_ nodes: [UEFINode], emptyByte: UInt8) -> [UEFINode] {
        nodes.map { node in
            guard node.kind == .padding || node.kind == .flashDeviceMapRegion else { return node }
            var read = node
            if !node.children.isEmpty {
                read.children = readingInsydeDMIStores(node.children, emptyByte: emptyByte)
                return read
            }
            guard !node.isErased else { return node }
            let body = node.body
            let step = InsydeDMIArea.alignment
            var found: [InsydeDMIArea] = []
            var at = (body.lowerBound + step - 1) / step * step
            while at + InsydeDMIArea.minimumSize <= body.upperBound {
                if reader.bytes(at: at, count: 4) == InsydeDMIArea.signature,
                   let area = InsydeDMIArea.read(at: at, end: body.upperBound, reader: reader) {
                    found.append(area)
                    at += InsydeDMIArea.minimumSize
                } else {
                    at += step
                }
            }
            guard !found.isEmpty else { return node }
            var rows: [UEFINode] = []
            var claimed = body.lowerBound
            for area in found {
                rows += padding(from: claimed, to: area.offset, emptyByte: emptyByte)
                rows.append(Self.insydeDMIRow(area))
                claimed = area.range.upperBound
            }
            read.children = rows + padding(from: claimed, to: body.upperBound, emptyByte: emptyByte)
            return read
        }
    }

    /// The store's row: a row per record, named by the field it writes —
    /// the row says the value beside the name, the details the structure
    /// type, the offset and the rest of the header.
    static func insydeDMIRow(_ area: InsydeDMIArea) -> UEFINode {
        var row = UEFINode(kind: .insydeDMIStore, named: L("Insyde DMI"), range: area.range)
        row.isFixed = true
        row.children = area.records.map { record in
            UEFINode(
                kind: .insydeDMIRecord,
                subtype: record.type,
                named: InsydeDMIArea.name(of: record),
                header: record.header,
                body: record.body,
                isFixed: true
            )
        }
        return row
    }
}
