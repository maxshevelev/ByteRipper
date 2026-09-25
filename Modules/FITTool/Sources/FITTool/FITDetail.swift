import Foundation
import Localization
import UEFIImage

/// One label/value row in the detail list.
public struct FITDetailField: Equatable, Sendable {
    public var label: String
    public var value: String
    /// A value that reads as a problem — a checksum that does not check out.
    /// The controller colours just this row's value with it; everything else
    /// stays as it is, the same way the UEFI detail marks its own.
    public var isProblem: Bool

    public init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
        self.isProblem = false
    }

    public init(_ label: String, _ value: String, isProblem: Bool) {
        self.label = label
        self.value = value
        self.isProblem = isProblem
    }
}

/// What the panel says about the selected row: the row's own sixteen bytes,
/// and what its address leads to, read rather than assumed.
///
/// Built in the pure target and tested by `swift test`, so the view controller
/// lays out what this says rather than deciding anything.
public struct FITRowDetail: Equatable, Sendable {
    /// The row's place and type, named the way the zones name it.
    public var title: String
    public var fields: [FITDetailField]

    public static let empty = FITRowDetail(title: "", fields: [])
}

/// Reads a row and says what it is, field by field.
///
/// The entry's own sixteen bytes come straight off the model, and what the row
/// points at was already read when the table was — a microcode header, an
/// Index/IO descriptor, a named region — so this reads nothing new: it only
/// puts what was found into the shape the panel draws.
public enum FITDetail {
    /// `checksumShouldBe` is the validator's word on the table's own checksum
    /// (§8.6) — the one thing about the header row that cannot be read off the
    /// row, and the value the header's Checksum field is coloured by and quotes
    /// when it reads wrong. Nil when the checksum checks out (or is not
    /// checked): the byte is valid then, not a problem.
    public static func build(for row: FITRow, checksumShouldBe: UInt8? = nil, inBackup: Bool = false) -> FITRowDetail {
        let entry = row.entry
        var fields = entryFields(of: entry, checksumShouldBe: checksumShouldBe)
        fields += targetFields(of: row)
        return FITRowDetail(
            // The number the panel shows for the row, counting from one the way
            // the table and the zones do — not the header's zero, which is its
            // place, not its number.
            title: inBackup
                ? L("Backup #%1$@ %2$@", entry.index + 1, FIT.typeName(entry.type))
                : L("#%1$@ %2$@", entry.index + 1, FIT.typeName(entry.type)),
            fields: fields
        )
    }

    // MARK: - The sixteen bytes of the row itself

    private static func entryFields(
        of entry: FITEntry, checksumShouldBe: UInt8?
    ) -> [FITDetailField] {
        // The row's labels read in the reader's language. Every one of them —
        // type, address, size, version, checksum — is a thing the trade has a
        // settled word for in each of them, so none is the kind of term that
        // only survives untranslated. `Address` takes the app-wide
        // translation: «Адрес в памяти» against `Offset`'s «Адрес в файле»,
        // which is the whole distinction a language with one word for both has
        // to make. What stays English is what has no word to take: the
        // microcode header below, read out of Intel's structure and shown in
        // the same English the UEFI panel shows it in.
        //
        // The type leads: it is what the row is, and the title already says it,
        // so the fields open with it rather than with where it sits.
        var fields: [FITDetailField] = [
            .init(L("Type"), "\(FIT.typeName(entry.type)) · \(hex(entry.type, digits: 2))")
        ]
        // Two addresses, side by side: where the entry sits in the dump, and
        // the address its own `Address` field holds. English tells them apart
        // by the two words; a language that has one word for both says which
        // is which, which is why the file one carries a context of its own.
        fields.append(.init(L("Offset", context: "fit"), hex(entry.offset, digits: 8)))
        fields.append(.init(L("Address"), entry.isHeader ? "_FIT_" : hex(entry.address, digits: 8)))
        fields.append(.init(L("Size"), sizeText(entry)))
        fields.append(.init(L("Version"), entry.versionText))
        // The checksum byte is the header's (§5), so it is shown on the header
        // row and on no other — a row that is not the header does not carry it.
        if entry.isHeader {
            // The verdict in brackets translates, the way `Checksums.text`
            // writes the other three, so one row never reads half in one
            // language and half in another.
            //
            // Valid means the byte counts *and* checks out — the same thing
            // "Valid" means everywhere else a checksum is read, so the word
            // can be trusted. A header that says its checksum does not count
            // (the C_V bit, §5) says so in as many words: the byte is not
            // wrong, it is not looked at, and nothing about it is a problem.
            // A wrong byte says what it should be: the `computed` half of the
            // mismatch, which is the value a fix would write back (§8.6).
            fields.append(entry.checksumValid
                ? .init(L("Checksum"),
                        Checksums.text(entry.checksum, valid: checksumShouldBe == nil,
                                       expected: checksumShouldBe.map(UInt64.init)),
                        isProblem: checksumShouldBe != nil)
                : .init(L("Checksum"),
                        L("%1$@ (Not checked)", hex(entry.checksum, digits: 2))))
        }
        return fields
    }

    private static func sizeText(_ entry: FITEntry) -> String {
        // The header's `Size` counts entries, not bytes — the field everyone
        // reads wrong (§4). For the rows that use it, the field is in 16-byte
        // units; what a reader wants is the byte count.
        if entry.isHeader {
            return L("%1$@ rows", entry.size)
        }
        // A row with no size of its own says so in the same word every empty
        // area does.
        if entry.size == 0 { return L("Empty") }
        return size(entry.sizeInBytes)
    }

    // MARK: - What the row points at

    private static func targetFields(of row: FITRow) -> [FITDetailField] {
        switch row.target {
        case .nothing:
            // The header and an empty slot point nowhere by design; the entry
            // fields above are the whole of what there is to say.
            return []
        case .indexIORegisters(let d):
            // The first eight bytes, read as a descriptor of Index/IO
            // registers rather than as the pointer they are shaped like
            // (§7.3). A register, a width and a bit position are all things
            // the trade names in its own language, so these read in it.
            return [
                .init(L("Index register"), hex(d.indexRegister, digits: 4)),
                .init(L("Data register"), hex(d.dataRegister, digits: 4)),
                .init(L("Access width"), d.accessWidth == 1
                    ? L("1 byte") : L("%1$@ bytes", d.accessWidth)),
                .init(L("Bit position"), "\(d.bitPosition)"),
                .init(L("Index"), hex(d.index, digits: 4))
            ]
        case .outsideTheImage:
            return [.init(L("Points at"), L("outside this image"))]
        case .microcode(let header):
            // The same reading the UEFI panel gives a microcode node
            // (`MicrocodeHeader.fields`), so the two say it in the same words.
            return header.fields.map { .init($0.label, $0.value, isProblem: $0.isProblem) }
        case .emptyMicrocodeSlot(let offset):
            return [
                .init(L("Points at"), L("empty slot (FF FF FF FF)")),
                .init(L("Component"), hex(offset, digits: 8))
            ]
        case .bytes(let offset, let description):
            // "Points at" only once something has read there — see
            // `FITDisplay.targetText`. The Component row below says where it
            // is either way.
            var fields: [FITDetailField] = []
            if let description {
                fields.append(.init(L("Points at"), description))
            }
            fields.append(.init(L("Component"), hex(offset, digits: 8)))
            if let length = row.effectiveSize {
                fields.append(.init(L("Length"), size(length)))
            }
            return fields
        }
    }

    // MARK: - Text

    /// A size in bytes, said both ways: hex for the dump, decimal for the mind.
    /// Zero is not worth two spellings — the area holds nothing, and the row
    /// says so.
    private static func size<T: BinaryInteger>(_ bytes: T) -> String {
        let value = UInt64(truncatingIfNeeded: bytes)
        return value == 0 ? L("Empty") : "\(hex(value)) (\(value))"
    }

    private static func hex<T: BinaryInteger>(_ value: T, digits: Int = 0) -> String {
        let text = String(UInt64(truncatingIfNeeded: value), radix: 16, uppercase: true)
        return "0x" + String(repeating: "0", count: max(0, digits - text.count)) + text
    }
}
