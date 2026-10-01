import Foundation

/// Insyde's BIOS Version Data Table, the `$BVDT$` block the flash device map
/// names `BIOS Version Data Table` (`UEFI_IMAGE_FORMAT.md` §9).
///
/// No specification describes it; the layout here is what five Insyde dumps
/// agree on. Three strings sit at fixed places, each after a `$`: the BIOS
/// version, the product name and the Insyde kernel version. Further on, a run
/// of `$`-tagged records ends with `$ENDOFBVDT`; of those only `$RDATE` is
/// read — three BCD bytes, year, month, day, which on every dump at hand is a
/// date that fits the BIOS version. The rest (`$BME$`, `$_MSC_VER=`, `$ESRT`,
/// `$QUIRK`) is not read.
///
/// Public because the details panel shows it, and it is a reading of bytes,
/// which belongs here and not in a view.
public struct InsydeBVDT: Equatable, Sendable {
    public var biosVersion: String?
    public var productName: String?
    public var kernelVersion: String?
    /// The `$RDATE` record as `YYYY-MM-DD`, the way a microcode's date reads.
    public var releaseDate: String?

    static let signature = Array("$BVDT$".utf8)
    static let end = Array("$ENDOFBVDT".utf8)
    static let dateTag = Array("$RDATE".utf8)

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
        return table
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
