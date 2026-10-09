import Foundation
import Localization
import UEFIImage

// help: panel.uefi.variable-value
/// How a variable's value reads (`NvramValue`): in a tree row, after the
/// variable's name, and in full in the detail list — each as its type. Text
/// as text, in quotes; a number in decimal, with its hex where the two
/// differ; a boot entry by its description; a path in the spec's text form.
public enum NvramValueText {
    /// The longest value a row shows before it cuts the rest off.
    static let rowLimit = 80
    /// The most bytes the detail list spells out of a value it cannot read.
    static let detailByteLimit = 256

    /// The most bytes a row spells out of a value it cannot read otherwise.
    static let rowByteLimit = 8

    /// The row: `BootOrder = 0003, 2001`, `Lang = "eng"`, `WRDD = 00 50 41`,
    /// `Setup (1686 bytes)`. Just the name for an empty value.
    public static func row(_ name: String, _ value: NvramValue, bytes: [UInt8]) -> String {
        if value.content == .bytes, bytes.count <= rowByteLimit {
            return "\(name) = \(hexBytes(bytes))"
        }
        guard let text = short(value) else {
            return value.content == .empty ? name : L("%1$@ (%2$@ bytes)", name, "\(bytes.count)")
        }
        return "\(name) = \(text.count > rowLimit ? text.prefix(rowLimit) + "…" : text)"
    }

    /// The value in a row's words; nil where it is only bytes too many to
    /// spell, or nothing at all.
    static func short(_ value: NvramValue) -> String? {
        switch value.content {
        case .empty:
            return nil
        case .number(let number, _):
            return numberText(number)
        case .optionList(let numbers):
            return numbers.map { String(format: "%04X", $0) }.joined(separator: ", ")
        case .optionNumber(let number):
            return String(format: "Boot%04X", number)
        case .text(let text, _):
            // A line break would break the row.
            return "\"" + text.map { $0.isNewline || $0 == "\t" ? " " : String($0) }.joined() + "\""
        case .devicePath(let path):
            return path
        case .loadOption(let option):
            return option.description.isEmpty ? option.devicePath : option.description
        case .signatures(let lists):
            return signaturesText(lists)
        case .hardwareErrorRecord:
            return L("Hardware error record")
        case .bytes:
            return nil
        }
    }

    /// The fields the detail list gives the value: the value whole, what it
    /// was read as and by what, and the parts of a load option.
    public static func fields(_ value: NvramValue, bytes: [UInt8]) -> [UEFIDetailField] {
        var fields: [UEFIDetailField] = []
        switch value.content {
        case .empty:
            fields.append(.init(L("Value"), L("Empty")))
        case .optionList(let numbers):
            fields.append(.init(L("Value"), numbers.map { String(format: "Boot%04X", $0) }.joined(separator: ", ")))
        case .text(let text, _):
            fields.append(.init(L("Value"), text))
        case .loadOption(let option):
            fields.append(.init(L("Value"), option.description))
            fields.append(.init("Load option attributes", bits(option.attributes)))
            fields.append(.init(L("Device path"), option.devicePath ?? L("Not readable")))
            if option.optionalDataSize > 0 {
                fields.append(.init(L("Optional data"), L("%1$@ bytes", "\(option.optionalDataSize)")))
            }
        case .bytes, .hardwareErrorRecord:
            fields.append(.init(L("Value"), hexBytes(bytes)))
        case .number, .optionNumber, .devicePath, .signatures:
            fields.append(.init(L("Value"), short(value) ?? ""))
        }
        fields.append(.init(L("Read as"), L("%1$@ — %2$@", kindText(value), basisText(value.basis))))
        return fields
    }

    /// The signatures of a database one row each — a certificate by its
    /// subject — except hashes, which are counted per list: a `dbx` holds
    /// hundreds, and none of them reads as anything.
    public static func signaturesTable(_ value: NvramValue) -> UEFIDetailTable? {
        guard case .signatures(let lists) = value.content else { return nil }
        var rows: [[UEFIDetailTable.Cell]] = []
        for list in lists {
            let type = list.typeName ?? list.type.description
            if list.isCertificates {
                for signature in list.signatures {
                    rows.append([.init(type), .init(signature.subject ?? L("No name")),
                                 .init(signature.owner.description)])
                }
            } else {
                let owners = Set(list.signatures.map(\.owner))
                rows.append([.init(type), .init(L("Entries: %1$@", "\(list.signatures.count)")),
                             .init(owners.count == 1 ? owners.first!.description : L("Several"))])
            }
        }
        return UEFIDetailTable(title: L("Signatures"), symbol: "checkmark.seal",
                               columns: [L("Type"), L("Subject"), L("Owner")], rows: rows)
    }

    // MARK: - Words

    /// A number in decimal, and in hex as well where the two read
    /// differently: `1`, `300 (0x12C)`.
    static func numberText(_ number: UInt64) -> String {
        number < 10 ? "\(number)" : "\(number) (0x\(String(number, radix: 16, uppercase: true)))"
    }

    /// One certificate by its subject; anything more counted by type, in the
    /// order the database lists them: `X.509: 3, SHA-256: 371`.
    private static func signaturesText(_ lists: [NvramValue.SignatureList]) -> String {
        let all = lists.flatMap(\.signatures)
        if all.count == 1, let list = lists.first(where: { !$0.signatures.isEmpty }), list.isCertificates,
           let subject = all[0].subject {
            return subject
        }
        var counts: [(String, Int)] = []
        for list in lists {
            let type = list.typeName ?? list.type.description
            if let index = counts.firstIndex(where: { $0.0 == type }) {
                counts[index].1 += list.signatures.count
            } else {
                counts.append((type, list.signatures.count))
            }
        }
        return counts.map { "\($0.0): \($0.1)" }.joined(separator: ", ")
    }

    private static func kindText(_ value: NvramValue) -> String {
        switch value.content {
        case .empty: return L("No value")
        case .number(_, let size): return L("%1$@-bit number", "\(size * 8)")
        case .optionList: return L("List of boot entries")
        case .optionNumber: return L("Boot entry number")
        case .text(_, .ascii): return L("ASCII text")
        case .text(_, .ucs2): return L("UCS-2 text")
        case .devicePath: return L("Device path")
        case .loadOption: return L("Boot entry")
        case .signatures: return L("Signature database")
        case .hardwareErrorRecord: return L("Hardware error record")
        case .bytes: return L("Bytes")
        }
    }

    private static func basisText(_ basis: NvramValue.Basis) -> String {
        switch basis {
        case .specification: return L("as the UEFI specification defines the variable")
        case .name: return L("by its name, which the UEFI specification defines; the GUID is a vendor's")
        case .attributes: return L("by its attributes")
        case .content: return L("guessed from the bytes")
        }
    }

    /// `EFI_LOAD_OPTION`'s attribute bits, in the spec's words.
    private static func bits(_ attributes: UInt32) -> String {
        var words: [String] = []
        if attributes & 0x1 != 0 { words.append("Active") }
        if attributes & 0x2 != 0 { words.append("ForceReconnect") }
        if attributes & 0x8 != 0 { words.append("Hidden") }
        if attributes & 0x1F00 == 0x100 { words.append("App") }
        let hex = "0x" + String(attributes, radix: 16, uppercase: true)
        return words.isEmpty ? hex : "\(hex) (\(words.joined(separator: ", ")))"
    }

    /// Bytes as a dump prints them, up to `detailByteLimit`.
    static func hexBytes(_ bytes: [UInt8]) -> String {
        let shown = bytes.prefix(detailByteLimit).map { String(format: "%02X", $0) }.joined(separator: " ")
        guard bytes.count > detailByteLimit else { return shown }
        return L("%1$@ … (%2$@ bytes in all)", shown, "\(bytes.count)")
    }
}
