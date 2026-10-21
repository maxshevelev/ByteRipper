import Foundation
import Localization

/// Where Apple's firmware keeps the machine's identity (`UEFI_IMAGE_FORMAT.md`
/// §9): in the SysF store, the `Fsys` variables of the NVRAM, not in a block
/// of its own. What the bench knows as the serial number, the configuration
/// code and the order number of a Mac.
///
/// ```
/// ssn   the system serial number      ("C02QMDJVG940")
/// hwc   the configuration code        ("G940", the end of the serial: four
///                                      characters, three on an 11-character one)
/// son   the sales order number        ("MJVE2D/", the model's order number)
/// ```
///
/// The board's own serial, the MLB, is no variable of this store: it is in the
/// names of the calibration variables beside them, each named by the MLB and
/// a suffix (`C02542600KXG91TANMAC-1`), and is read from the prefix they
/// share.
///
/// The layout is read off four Mac dumps — a MacBook Air, a MacBook Pro 13
/// (A1708) and two MacBook Pro 15 of 2010 and 2011 — and nothing is
/// published. The two older boards keep an 11-character serial with a
/// three-character code, and no calibration variables, so no MLB is read
/// from them.
public struct AppleDMIArea: Equatable, Sendable {
    public static let serialName = "ssn"
    public static let configCodeName = "hwc"
    public static let orderNumberName = "son"
    /// The variables of the store that hold a value of the area.
    public static let identityNames: Set<String> = [serialName, configCodeName, orderNumberName]
    /// The length of the MLB on every board read from.
    public static let boardSerialLength = 17

    /// The SysF store the fields are read from.
    public var store: Range<UInt64>
    public var serialNumber: String?
    public var configCode: String?
    public var orderNumber: String?
    public var boardSerial: String?
    /// The store marks the copy of the serial invalid, and keeps no current one.
    public var isDeleted: Bool
    /// The entries of the store each value is read from — the copies that
    /// stand, and for the MLB the first variable named by it — where the
    /// store has them.
    public var serialEntry: Range<UInt64>?
    public var configCodeEntry: Range<UInt64>?
    public var orderNumberEntry: Range<UInt64>?
    public var boardSerialEntry: Range<UInt64>?

    public init(store: Range<UInt64>, serialNumber: String? = nil, configCode: String? = nil,
                orderNumber: String? = nil, boardSerial: String? = nil, isDeleted: Bool = false) {
        self.store = store
        self.serialNumber = serialNumber
        self.configCode = configCode
        self.orderNumber = orderNumber
        self.boardSerial = boardSerial
        self.isDeleted = isDeleted
    }

    /// The values, in the order a Mac's own tools list them, each with the
    /// entry it is read from.
    public var values: [(name: LocalizedText, value: String?, entry: Range<UInt64>?)] {
        [
            (L("Serial number"), serialNumber, serialEntry),
            (L("Configuration code"), configCode, configCodeEntry),
            (L("Sales order number"), orderNumber, orderNumberEntry),
            (L("MLB (board serial)"), boardSerial, boardSerialEntry),
        ]
    }

    /// What a technician should know before trusting the fields.
    public var findings: [AppleDMIFinding] {
        var found: [AppleDMIFinding] = []
        if isDeleted { found.append(.deletedCopy) }
        if let serial = serialNumber, let code = configCode, serial.count >= code.count,
           !serial.hasSuffix(code) {
            found.append(.configCodeIsNotTheSerialsEnd)
        }
        if let serial = serialNumber, let board = boardSerial, serial.prefix(3) != board.prefix(3) {
            found.append(.serialIsNotTheBoardsLocation)
        }
        return found
    }

    // MARK: - Reading

    /// One variable of a SysF store as it is stored: its name, read from the
    /// bytes — a copy marked invalid is named Invalid on the node — and its
    /// value.
    struct Variable {
        var name: String
        var isValid: Bool
        var data: Range<UInt64>
        var entry: Range<UInt64>
    }

    static func variables(in store: UEFINode, reader: ImageReader) -> [Variable] {
        store.children.compactMap { entry in
            guard entry.kind == .sysFEntry, entry.header.count >= 3,
                  let flags = reader.uint8(at: entry.header.lowerBound),
                  let nameBytes = reader.bytes(at: entry.header.lowerBound + 1,
                                               count: UInt64(flags & NVRAM.sysfNameLengthMask))
            else { return nil }
            let name = String(decoding: nameBytes.prefix(while: { $0 != 0 }), as: UTF8.self)
            return Variable(name: name, isValid: flags & NVRAM.sysfInvalidFlag == 0, data: entry.body,
                            entry: entry.range)
        }
    }

    /// The copy that stands for a variable: the current one, or the last one
    /// where the store keeps none.
    private static func standing(_ name: String, in variables: [Variable]) -> Variable? {
        let mine = variables.filter { $0.name == name }
        return mine.last(where: \.isValid) ?? mine.last
    }

    /// The text of a variable, to its first NUL; nil where it is empty or is
    /// not printable ASCII.
    private static func text(_ variable: Variable?, reader: ImageReader) -> String? {
        guard let variable else { return nil }
        return text(in: variable.data, reader: reader)
    }

    /// The text a SysF entry holds, the same way: what its row says beside
    /// its name.
    public static func text(of entry: UEFINode, reader: ImageReader) -> String? {
        guard entry.kind == .sysFEntry else { return nil }
        return text(in: entry.body, reader: reader)
    }

    private static func text(in data: Range<UInt64>, reader: ImageReader) -> String? {
        guard let bytes = reader.bytes(data) else { return nil }
        let text = bytes.prefix(while: { $0 != 0 })
        guard !text.isEmpty, text.allSatisfy({ (0x20...0x7E).contains($0) }) else { return nil }
        return String(decoding: text, as: UTF8.self)
    }

    /// The MLB: the prefix of `boardSerialLength` alphanumerics that at least
    /// two variables' names share, the most shared one where there are
    /// several.
    static func boardSerial(in variables: [Variable]) -> String? {
        var counts: [String: Int] = [:]
        for variable in variables {
            let name = Array(variable.name.utf8)
            guard name.count > boardSerialLength else { continue }
            let prefix = name.prefix(boardSerialLength)
            guard prefix.allSatisfy({
                (0x30...0x39).contains($0) || (0x41...0x5A).contains($0)
            }) else { continue }
            counts[String(decoding: prefix, as: UTF8.self), default: 0] += 1
        }
        return counts.filter { $0.value >= 2 }.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key
    }

    /// Apple's identity as `store` holds it; nil when it is no SysF store, or
    /// holds none of the fields.
    public static func read(store: UEFINode, reader: ImageReader) -> AppleDMIArea? {
        guard store.kind == .sysFStore, store.space == .file,
              reader.uint32(at: store.range.lowerBound) == NVRAM.appleSysfSignature
        else { return nil }
        let variables = variables(in: store, reader: reader)
        let serial = standing(serialName, in: variables)
        let configCode = standing(configCodeName, in: variables)
        let orderNumber = standing(orderNumberName, in: variables)
        let board = boardSerial(in: variables)
        var area = AppleDMIArea(
            store: store.range,
            serialNumber: text(serial, reader: reader),
            configCode: text(configCode, reader: reader),
            orderNumber: text(orderNumber, reader: reader),
            boardSerial: board,
            isDeleted: serial.map { !$0.isValid } ?? false
        )
        area.serialEntry = serial?.entry
        area.configCodeEntry = configCode?.entry
        area.orderNumberEntry = orderNumber?.entry
        area.boardSerialEntry = board.flatMap { prefix in variables.first { $0.name.hasPrefix(prefix) }?.entry }
        guard area.serialNumber != nil || area.configCode != nil || area.orderNumber != nil
                || area.boardSerial != nil
        else { return nil }
        return area
    }
}

/// Something about Apple's identity a technician should know before trusting
/// it.
public enum AppleDMIFinding: Equatable, Sendable {
    /// The store marks the serial invalid, and keeps no current copy.
    case deletedCopy
    /// The configuration code is the end of the serial; here it is not.
    case configCodeIsNotTheSerialsEnd
    /// The serial and the board's serial begin with the same three
    /// characters, the place of manufacture; here they do not.
    case serialIsNotTheBoardsLocation

    public var text: LocalizedText {
        switch self {
        case .deletedCopy:
            return L("The store marks the serial invalid and keeps no current copy. The value is whole; where the firmware takes it from on such a board, the dump does not show.")
        case .configCodeIsNotTheSerialsEnd:
            return L("The configuration code is not the end of the serial, as it is on a Mac's own. The serial was written without its code, or is a placeholder.")
        case .serialIsNotTheBoardsLocation:
            return L("The serial does not begin as the board's serial does. On a Mac's own both begin with the code of the factory; the serial was changed, or came over from another machine.")
        }
    }
}
