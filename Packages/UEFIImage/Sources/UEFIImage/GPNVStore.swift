import Foundation

/// AMI's GPNV store, where ASUS keeps what the factory wrote of the machine
/// (`UEFI_IMAGE_FORMAT.md` §9): the board's serial numbers, the model, the
/// Windows key — what the bench calls the DMI area. A run of records, each
/// written whole after the last, the one before it of the same name marked
/// replaced; nothing is erased until the whole store is. Found on two ASUS
/// laptops, an AMD one inside a volume of its own and an Intel one in the
/// padding after NVRAM. The layout is read off those dumps, not a published
/// one, and the help says so.
///
/// ```
/// 0x00  "GPNV"
/// 0x04  the record's length, header included (UInt16)
/// 0x06  1 for the record in force, 0 for one a later record replaced
/// 0x07  the name, four characters and a NUL: "MFG0", "CNFG", "OA30", "_DMI"
/// 0x0C  the data, to the record's length; what is not written is FF
/// ```
public struct GPNVRecord: Equatable, Sendable {
    public static let signature = Array("GPNV".utf8)
    public static let headerSize: UInt64 = 0x0C
    /// The store sits at the start of the bytes it is found in, or on a 4 KiB
    /// boundary inside them.
    public static let alignment: UInt64 = 0x1000

    public var offset: UInt64
    public var length: UInt64
    public var name: String
    /// The record in force, not one a later record replaced.
    public var isCurrent: Bool

    public var range: Range<UInt64> { offset..<(offset + length) }
    public var header: Range<UInt64> { offset..<(offset + Self.headerSize) }
    public var body: Range<UInt64> { (offset + Self.headerSize)..<range.upperBound }

    /// The record at `offset`, when its header reads as one and its length
    /// ends by `limit`; nil otherwise, saying nothing.
    public static func read(at offset: UInt64, limit: UInt64, in reader: ImageReader) -> GPNVRecord? {
        guard offset + headerSize <= limit,
              let header = reader.bytes(at: offset, count: headerSize),
              Array(header[0..<4]) == signature
        else { return nil }
        let length = UInt64(header[4]) | UInt64(header[5]) << 8
        let state = header[6]
        let name = header[7..<11]
        guard length >= headerSize, offset + length <= limit,
              state <= 1, header[11] == 0,
              name.allSatisfy({ $0 == 0x5F || (0x30...0x39).contains($0) || (0x41...0x5A).contains($0) })
        else { return nil }
        return GPNVRecord(offset: offset, length: length, name: String(decoding: name, as: UTF8.self),
                          isCurrent: state == 1)
    }

    /// The records back to back from `offset`, up to the first bytes that are
    /// not one; empty when there is none at `offset`.
    public static func store(at offset: UInt64, limit: UInt64, in reader: ImageReader) -> [GPNVRecord] {
        var records: [GPNVRecord] = []
        var at = offset
        while let record = read(at: at, limit: limit, in: reader) {
            records.append(record)
            at = record.range.upperBound
        }
        return records
    }

    /// The product key of an `OA30` record: Microsoft's MSDM data — a version,
    /// a data type, the key's length at `0x10` and the key at `0x14`.
    public static func productKey(of body: [UInt8]) -> String? {
        guard body.count >= 0x14 else { return nil }
        let length = Int(body[0x10]) | Int(body[0x11]) << 8
        guard length > 0, 0x14 + length <= body.count else { return nil }
        let key = body[0x14..<(0x14 + length)]
        guard key.allSatisfy({ (0x20...0x7E).contains($0) }) else { return nil }
        return String(decoding: key, as: UTF8.self)
    }

    /// The runs of printable text in a record's data, at least four
    /// characters each, with where each starts in the data. What the fields
    /// between them mean is not known.
    public static func texts(in body: [UInt8]) -> [(offset: Int, text: String)] {
        var found: [(offset: Int, text: String)] = []
        var start: Int?
        for index in 0...body.count {
            let printable = index < body.count && (0x20...0x7E).contains(body[index])
            if printable {
                if start == nil { start = index }
                continue
            }
            if let first = start, index - first >= 4 {
                let text = String(decoding: body[first..<index], as: UTF8.self)
                    .trimmingCharacters(in: .whitespaces)
                if !text.isEmpty { found.append((first, text)) }
            }
            start = nil
        }
        return found
    }
}

extension Parser {
    /// The GPNV store at `offset`, as a row with a row per record, and the
    /// bytes after its last record up to `end`; nil when no record starts there.
    func gpnvStore(at offset: UInt64, to end: UInt64, emptyByte: UInt8) -> [UEFINode]? {
        let records = GPNVRecord.store(at: offset, limit: end, in: reader)
        guard let last = records.last else { return nil }
        var store = UEFINode(kind: .gpnvStore, name: "GPNV", range: offset..<last.range.upperBound)
        store.children = records.map { record in
            UEFINode(
                kind: .gpnvRecord,
                subtype: record.isCurrent ? 1 : 0,
                name: record.name,
                header: record.header,
                body: record.body
            )
        }
        return [store] + padding(from: last.range.upperBound, to: end, emptyByte: emptyByte)
    }

    /// `nodes` with a GPNV store in their written padding read out as a row,
    /// each stretch keeping its place, range and name (§9): at the start of
    /// the stretch, or on a 4 KiB boundary of the file inside it.
    func readingGPNVStores(_ nodes: [UEFINode], emptyByte: UInt8) -> [UEFINode] {
        nodes.map { node in
            guard node.kind == .padding else { return node }
            var read = node
            if !node.children.isEmpty {
                read.children = readingGPNVStores(node.children, emptyByte: emptyByte)
                return read
            }
            guard !node.isErased else { return node }
            let body = node.body
            var at = body.lowerBound
            while at + GPNVRecord.headerSize <= body.upperBound {
                if let rows = gpnvStore(at: at, to: body.upperBound, emptyByte: emptyByte) {
                    read.children = padding(from: body.lowerBound, to: at, emptyByte: emptyByte) + rows
                    return read
                }
                at = (at / GPNVRecord.alignment + 1) * GPNVRecord.alignment
            }
            return node
        }
    }
}
