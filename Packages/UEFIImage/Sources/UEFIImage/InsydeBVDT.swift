import Foundation

/// Insyde's BIOS Version Data Table, the `$BVDT$` block the flash device map
/// names `BIOS Version Data Table` (`UEFI_IMAGE_FORMAT.md` §9).
///
/// No specification describes it; the layout here is what six Insyde dumps
/// agree on. Three strings sit at fixed places, each after a `$`: the BIOS
/// version, the product name and the Insyde kernel version. Further on, a run
/// of `$`-tagged records ends with `$ENDOFBVDT`:
///
/// - `$RDATE` — three BCD bytes, year, month, day, which on every dump at hand
///   is a date that fits the BIOS version.
/// - `$_MSC_VER=` — a 16-bit number, the value of Microsoft's compiler macro
///   of that name: 1600 or 1900 on the dumps, Visual Studio 2010 and 2015.
/// - `$ESRT` — a 32-bit version and a GUID. The GUID is the firmware class of
///   the board's entry in the EFI System Resource Table, the hardware ID
///   (`UEFI\RES_{…}`) Windows Update matches a BIOS capsule against; the
///   version's low byte is the BIOS build number on four of the five boards.
/// - `$BME$` — up to three offset and size pairs in the BIOS region, each
///   followed by a `$`. On the dumps they are the table's own region, one
///   FFSv2 volume exactly, and on one board the EC firmware region; what the
///   firmware or its flash tool does with them is not known.
///
/// `$QUIRK`, on one board, is not read.
///
/// Public because the details panel shows it, and it is a reading of bytes,
/// which belongs here and not in a view.
public struct InsydeBVDT: Equatable, Sendable {
    public var biosVersion: String?
    public var productName: String?
    public var kernelVersion: String?
    /// The `$RDATE` record as `YYYY-MM-DD`, the way a microcode's date reads.
    public var releaseDate: String? = nil
    /// The `$_MSC_VER=` record: the compiler version the firmware was built
    /// with, as Microsoft numbers it.
    public var compilerVersion: UInt16? = nil
    /// The `$ESRT` record's version and firmware class.
    public var esrtVersion: UInt32? = nil
    public var esrtClass: EFIGUID? = nil
    /// The `$BME$` record's ranges, as offsets into the BIOS region.
    public var listedRanges: [Range<UInt64>] = []

    static let signature = Array("$BVDT$".utf8)
    static let end = Array("$ENDOFBVDT".utf8)
    static let dateTag = Array("$RDATE".utf8)
    static let compilerTag = Array("$_MSC_VER=".utf8)
    static let esrtTag = Array("$ESRT".utf8)
    static let rangesTag = Array("$BME$".utf8)
    /// `$BME$` holds no more pairs than this on any dump at hand, and the
    /// next record follows the third.
    static let rangeSlots = 3

    /// Each string field: where its `$` is, and where the next field begins.
    static let biosVersionField: Range<Int> = 0x0D..<0x26
    static let productNameField: Range<Int> = 0x26..<0x40
    static let kernelVersionField: Range<Int> = 0x40..<0x66

    /// The table at the start of `range`, or nil when it does not open with
    /// `$BVDT$`. A field whose `$` is missing, or that holds no text, is nil.
    public static func read(_ range: Range<UInt64>, in reader: ImageReader) -> InsydeBVDT? {
        // The table and its records fit in the first 4 KiB, the size the
        // region has on every dump at hand.
        let length = min(range.count, 0x1000)
        guard let bytes = reader.bytes(at: range.lowerBound, count: UInt64(length)),
              bytes.starts(with: signature)
        else { return nil }

        var table = InsydeBVDT()
        table.biosVersion = string(bytes, biosVersionField)
        table.productName = string(bytes, productNameField)
        table.kernelVersion = string(bytes, kernelVersionField)

        let records = bytes.firstRange(of: end).map { bytes[..<$0.lowerBound] } ?? bytes[...]
        if let tag = records.firstRange(of: dateTag), tag.upperBound + 3 <= records.endIndex {
            let date = Array(records[tag.upperBound..<(tag.upperBound + 3)])
            if date.allSatisfy(isBCD), (1...12).contains(bcd(date[1])), (1...31).contains(bcd(date[2])) {
                table.releaseDate = String(format: "20%02X-%02X-%02X", date[0], date[1], date[2])
            }
        }
        if let value = value(after: compilerTag, count: 2, in: records) {
            table.compilerVersion = UInt16(value[0]) | UInt16(value[1]) << 8
        }
        if let value = value(after: esrtTag, count: 20, in: records) {
            table.esrtVersion = value[0..<4].reversed().reduce(0) { $0 << 8 | UInt32($1) }
            table.esrtClass = EFIGUID(bytes: Array(value[4..<20]))
        }
        if let tag = records.firstRange(of: rangesTag) {
            table.listedRanges = ranges(from: tag.upperBound, in: records)
        }
        return table
    }

    /// The `count` bytes after `tag` among the records, if they are there.
    private static func value(after tag: [UInt8], count: Int, in records: ArraySlice<UInt8>) -> [UInt8]? {
        guard let found = records.firstRange(of: tag), found.upperBound + count <= records.endIndex else { return nil }
        return Array(records[found.upperBound..<(found.upperBound + count)])
    }

    /// `$BME$`'s pairs: a 32-bit offset and size, then a `$` when another
    /// follows. A pair that is erased — a size of all ones — is a slot not in
    /// use, and so is one of size zero.
    private static func ranges(from start: Int, in records: ArraySlice<UInt8>) -> [Range<UInt64>] {
        func dword(_ at: Int) -> UInt64 {
            records[at..<(at + 4)].reversed().reduce(0) { $0 << 8 | UInt64($1) }
        }
        var ranges: [Range<UInt64>] = []
        var at = start
        for slot in 0..<rangeSlots {
            guard at + 8 <= records.endIndex else { break }
            let offset = dword(at), size = dword(at + 4)
            if size != 0, size != 0xFFFF_FFFF, offset < 0xFFFF_0000 {
                ranges.append(offset..<(offset + size))
            }
            at += 8
            guard slot < rangeSlots - 1, at < records.endIndex, records[at] == UInt8(ascii: "$") else { break }
            at += 1
        }
        return ranges
    }

    private static func string(_ bytes: [UInt8], _ field: Range<Int>) -> String? {
        guard field.upperBound <= bytes.count, bytes[field.lowerBound] == UInt8(ascii: "$") else { return nil }
        let text = bytes[(field.lowerBound + 1)..<field.upperBound].prefix { $0 != 0 }
        guard !text.isEmpty, text.allSatisfy({ (0x20..<0x7F).contains($0) }) else { return nil }
        return String(decoding: text, as: UTF8.self).trimmingCharacters(in: .whitespaces)
    }

    private static func isBCD(_ byte: UInt8) -> Bool {
        byte & 0x0F <= 9 && byte >> 4 <= 9
    }

    private static func bcd(_ byte: UInt8) -> Int {
        Int(byte >> 4) * 10 + Int(byte & 0x0F)
    }
}
