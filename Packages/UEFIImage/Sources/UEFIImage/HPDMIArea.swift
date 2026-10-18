import Foundation
import Localization

/// Where HP's firmware keeps the machine's identity (`UEFI_IMAGE_FORMAT.md`
/// §9): NVRAM variables in the main VSS2 store, not a block of their own.
/// What HP BIOS Configuration Utility (BCU) reports and writes as Serial
/// Number, SKU Number, Product Family, CT Number, Product Name, System UUID,
/// Build ID, Feature Byte and Asset Tracking Number.
///
/// ```
/// HP_MUD       20AB3EB1-…  430 bytes, UTF-16, each field NUL-padded
///   0x000  the serial number            ("5CD4432P9B")
///   0x042  the SKU                      ("B8AL7E8#ABD")
///   0x0A4  the product family           ("103C_5336AN HP EliteBook")
///   0x106  the CT number                ("PTXNK028JK100B")
///   0x124  the product name             ("HP EliteBook 645 14 inch G11 Notebook PC")
///   0x19E  the UUID, 16 bytes, as SMBIOS stores one
/// BuildId      20AB3EB1-…  UTF-16      ("24WWROBZ602#SABD#DABD")
/// FactoryConfig 20AB3EB1-… UTF-16      the feature byte, ".XX" at its end
/// HP_TAGS      FB3B9ECE-…  UTF-16      the asset tracking number at 0x000
/// ```
///
/// The variable names are HP's own: a driver of the firmware lists `HP_MUD`,
/// `BuildId`, `FactoryConfig` and `FactoryConfigFlags` under the one GUID.
/// The layout of `HP_MUD` is read off the dumps of HP EliteBooks of 2023–2025
/// (AMD and Intel), not a published one, and the help says so. The rest of
/// `HP_TAGS` — 324 bytes, of which the asset tracking number takes the first
/// field — was blank in every dump, and is not read.
///
/// On three of the four boards the store marks every copy of `HP_MUD`
/// deleted and keeps no current one, yet the copy is whole: the area is read
/// from the last copy where there is no current one, and says so.
public struct HPDMIArea: Equatable, Sendable {
    /// The GUID HP's factory variables are written under.
    public static let factoryGuid = EFIGUID("20AB3EB1-3C8F-4A4C-B87E-372426066D97")!
    /// The GUID HP's Setup settings are written under, `HP_TAGS` among them.
    public static let settingsGuid = EFIGUID("FB3B9ECE-4ABA-4933-B49D-B4D67D892351")!
    public static let mudName = "HP_MUD"
    /// The size of `HP_MUD` on every board read from; another size is a
    /// layout nobody has read.
    public static let mudSize = 0x1AE

    /// The `HP_MUD` entry the fields are read from.
    public var entry: Range<UInt64>
    /// Its value, `mudSize` bytes.
    public var mud: [UInt8]
    /// The store marks the entry deleted, and holds no current copy.
    public var isDeleted: Bool
    public var buildID: String?
    public var featureByte: String?
    public var assetTag: String?

    public init(entry: Range<UInt64>, mud: [UInt8], isDeleted: Bool,
                buildID: String? = nil, featureByte: String? = nil, assetTag: String? = nil) {
        self.entry = entry
        self.mud = mud
        self.isDeleted = isDeleted
        self.buildID = buildID
        self.featureByte = featureByte
        self.assetTag = assetTag
    }

    // MARK: - The fields

    /// Where each text of `HP_MUD` sits, the field it is NUL-padded to.
    static let serialField = 0x000..<0x042
    static let skuField = 0x042..<0x0A4
    static let familyField = 0x0A4..<0x106
    static let ctNumberField = 0x106..<0x124
    static let productNameField = 0x124..<0x19E
    static let uuidField = 0x19E..<0x1AE

    public var serialNumber: String { Self.text(mud[Self.serialField]) ?? "" }
    public var sku: String { Self.text(mud[Self.skuField]) ?? "" }
    public var productFamily: String { Self.text(mud[Self.familyField]) ?? "" }
    public var ctNumber: String { Self.text(mud[Self.ctNumberField]) ?? "" }
    public var productName: String { Self.text(mud[Self.productNameField]) ?? "" }

    /// The UUID, spelled the way the bench spells it: the first three groups
    /// read back the way SMBIOS stores them, the rest as-is.
    public var uuidText: String { EFIGUID(bytes: Array(mud[Self.uuidField])).description }

    /// What a technician should know before trusting the fields.
    public var findings: [HPDMIFinding] {
        var found: [HPDMIFinding] = []
        if isDeleted { found.append(.deletedCopy) }
        if let assetTag, assetTag != serialNumber { found.append(.assetTagIsNotTheSerial) }
        return found
    }

    // MARK: - Reading

    /// The UTF-16 text a field holds, to its first NUL; nil where a unit is
    /// not printable ASCII — no field read from has held anything else.
    static func text(_ bytes: ArraySlice<UInt8>) -> String? {
        var units: [UInt16] = []
        var index = bytes.startIndex
        while index + 1 < bytes.endIndex {
            let unit = UInt16(bytes[index]) | UInt16(bytes[index + 1]) << 8
            if unit == 0 { break }
            guard (0x20...0x7E).contains(unit) else { return nil }
            units.append(unit)
            index += 2
        }
        return String(decoding: units, as: UTF16.self)
    }

    /// Whether `mud` reads as an `HP_MUD` value: the size of the layout, a
    /// serial number, and printable text or NUL in every text field.
    static func isMUD(_ mud: [UInt8]) -> Bool {
        guard mud.count == mudSize, let serial = text(mud[serialField]), !serial.isEmpty else { return false }
        return [skuField, familyField, ctNumberField, productNameField].allSatisfy { text(mud[$0]) != nil }
    }

    /// One copy of a variable in a store: its entry, and the variable read
    /// from it — marked or not, since a marked entry is named Invalid.
    struct Copy {
        var entry: UEFINode
        var variable: VSSVariable
        var name: String
    }

    /// Every VSS entry of `store` read as a variable, in store order.
    static func copies(in store: UEFINode, reader: ImageReader) -> [Copy] {
        guard store.kind == .vssStore || store.kind == .vss2Store else { return [] }
        return store.children.compactMap { entry in
            guard entry.kind == .vssEntry,
                  let variable = VSSVariable.read(entry, inVss2: store.kind == .vss2Store, reader: reader),
                  let name = variable.decodedName(reader: reader)
            else { return nil }
            return Copy(entry: entry, variable: variable, name: name)
        }
    }

    /// The copy that stands for the variable: the current one, or the last
    /// one where the store keeps none.
    static func standing(_ name: String, _ guid: EFIGUID, in copies: [Copy]) -> Copy? {
        let mine = copies.filter { $0.name == name && $0.variable.vendorGuid == guid }
        return mine.last(where: { $0.variable.isValid }) ?? mine.last
    }

    /// HP's identity as `store` holds it; nil when it holds no `HP_MUD` that
    /// reads as one.
    public static func read(store: UEFINode, reader: ImageReader) -> HPDMIArea? {
        let copies = copies(in: store, reader: reader)
        guard let mud = standing(mudName, factoryGuid, in: copies),
              let value = reader.bytes(mud.variable.data), isMUD(value)
        else { return nil }
        func textOf(_ name: String, _ guid: EFIGUID, field: Range<Int>? = nil) -> String? {
            guard let copy = standing(name, guid, in: copies),
                  let bytes = reader.bytes(copy.variable.data)
            else { return nil }
            let window = field.map { bytes[$0.clamped(to: 0..<bytes.count)] } ?? bytes[...]
            guard let text = text(window), !text.isEmpty else { return nil }
            return text
        }
        return HPDMIArea(
            entry: mud.entry.range,
            mud: value,
            isDeleted: !mud.variable.isValid,
            buildID: textOf("BuildId", factoryGuid),
            featureByte: textOf("FactoryConfig", factoryGuid),
            assetTag: textOf("HP_TAGS", settingsGuid, field: 0..<0xA2)
        )
    }

    /// Whether `entry` is the `HP_MUD` copy the area of `store` is read from.
    public static func isAreaEntry(_ entry: UEFINode, in store: UEFINode, reader: ImageReader) -> Bool {
        guard entry.kind == .vssEntry, entry.guid == factoryGuid else { return false }
        return read(store: store, reader: reader)?.entry == entry.range
    }
}

/// Something about HP's identity a technician should know before trusting it.
public enum HPDMIFinding: Equatable, Sendable {
    /// The store marks the copy deleted, and keeps no current one.
    case deletedCopy
    /// The asset tracking number is not the serial number, which HP writes
    /// there by default.
    case assetTagIsNotTheSerial

    public var text: LocalizedText {
        switch self {
        case .deletedCopy:
            return L("The store marks this copy deleted and keeps no current one. The values are whole, and on most HP boards read so far the store holds them this way; where the firmware takes them from on such a board, the dump does not show.")
        case .assetTagIsNotTheSerial:
            return L("The asset tracking number is not the serial number. HP writes the serial number there by default: the owner set another value, or it came over from another machine.")
        }
    }
}
