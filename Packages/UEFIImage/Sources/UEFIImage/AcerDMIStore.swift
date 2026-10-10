import Foundation
import Localization

/// Acer's DMI region, where the firmware keeps the machine's identity
/// (`UEFI_IMAGE_FORMAT.md` §9): the system serial number, the service tag,
/// the UUID, the model. What the bench calls the DMI area. An 8 KiB block on
/// a 4 KiB boundary, in the padding inside the BIOS region: it is no region
/// of the descriptor, no map region, and it lies at no fixed offset — the
/// board's BIOS layout sets where, and the block is found by its content.
///
/// ```
/// 0x00  the system serial, 22 alphanumerics starting with "N"
/// 0x30  a flag the factory writes per build
/// 0x3C  06 FF FF FF
/// 0x40  "Acer"
/// 0x50  the service tag, 22 alphanumerics starting with "NB"
/// 0x70  the UUID, 16 bytes
/// 0x80  the model
/// 0xA0  the asset tag, where written
/// 0xC0  the product name
/// 0xF3  02
/// 0x128 or 0x130  a copy of the UUID's last six bytes
/// ```
///
/// Everything else in the block is padding — FF or 00. The block has no
/// checksum: none was found over the dumps it was read from, and the copy of
/// the UUID's tail is not a checksum — it goes stale when the UUID is
/// changed after. The layout is read off those dumps, not a published one,
/// and the help says so.
public struct AcerDMIArea: Equatable, Sendable {
    public static let size: UInt64 = 0x2000
    /// The block sits at the start of the bytes it is found in, or on a
    /// 4 KiB boundary inside them.
    public static let alignment: UInt64 = 0x1000
    /// The block's signature, at +0x3C: the constant 06, three FF, "Acer".
    public static let signature: [UInt8] = [0x06, 0xFF, 0xFF, 0xFF] + Array("Acer".utf8)
    public static let signatureOffset: UInt64 = 0x3C

    public var offset: UInt64
    /// The block's 8 KiB, as stored.
    public var stored: [UInt8]

    public var range: Range<UInt64> { offset..<(offset + Self.size) }

    public init(offset: UInt64, stored: [UInt8]) {
        self.offset = offset
        self.stored = stored
    }

    // MARK: - The fields

    /// The system serial: 22 alphanumerics, what the sticker says.
    public var systemSerial: String { String(decoding: stored[0..<0x16], as: UTF8.self) }

    /// The service tag: 22 alphanumerics.
    public var serviceTag: String { String(decoding: stored[0x50..<0x66], as: UTF8.self) }

    /// The UUID, as stored: the first two words little-endian, the rest as
    /// they read — the way SMBIOS writes one.
    public var uuid: [UInt8] { Array(stored[0x70..<0x80]) }

    /// The UUID, spelled the way the bench spells it: the first three groups
    /// read back the way SMBIOS stores them, the rest as-is.
    public var uuidText: String {
        func group(_ from: Int, _ count: Int, reversed: Bool) -> String {
            let bytes = Array(stored[0x70 + from..<0x70 + from + count])
            let ordered = reversed ? bytes.reversed() : bytes
            return ordered.map { String(format: "%02X", $0) }.joined()
        }
        return "\(group(0, 4, reversed: true))-\(group(4, 2, reversed: true))-\(group(6, 2, reversed: false))-\(group(8, 2, reversed: false))-\(group(10, 6, reversed: false))"
    }

    /// The model, as far as it is written.
    public var model: String { text(from: 0x80) }

    /// The asset tag, where written; nil over its padding.
    public var assetTag: String? {
        let text = text(from: 0xA0)
        return text.isEmpty ? nil : text
    }

    /// The product name, as far as it is written.
    public var productName: String { text(from: 0xC0) }

    /// The manufacturing code the factory wrote at the block's end — a run
    /// of decimal digits, at +0x690 or +0x6A0 — where it is there. A
    /// cleaning tool has zeroed some of it in some dumps.
    public var manufacturingCode: String? {
        for offset in [0x690, 0x6A0] {
            let digits = stored[offset...].prefix(while: { (0x30...0x39).contains($0) })
            if digits.count >= 4 { return String(decoding: digits, as: UTF8.self) }
        }
        return nil
    }

    /// Whether `text` holds `pattern` at `start`, counting from the front;
    /// false when `text` does not run that far.
    private static func holds(_ text: String, _ pattern: String, at start: Int) -> Bool {
        let characters = Array(text)
        guard characters.count >= start + pattern.count else { return false }
        return Array(characters[start..<(start + pattern.count)]) == Array(pattern)
    }

    /// The run of printable text from `offset`, to its first FF or NUL.
    private func text(from offset: Int) -> String {
        var end = offset
        while end < stored.count, stored[end] != 0xFF, stored[end] != 0x00,
              (0x20...0x7E).contains(stored[end]) {
            end += 1
        }
        return String(decoding: stored[offset..<end], as: UTF8.self)
    }

    // MARK: - What reads wrong

    /// What reads wrong in the block. The factory blocks pass all of it; a
    /// cleaned or tampered one does not.
    public var findings: [AcerDMIFinding] {
        var found: [AcerDMIFinding] = []
        if !Self.holds(systemSerial, "00", at: 7) || !Self.holds(systemSerial, "3400", at: 18) {
            found.append(.serialPattern)
        }
        if !Self.holds(serviceTag, "1100", at: 5) || !Self.holds(serviceTag, "3400", at: 18) {
            found.append(.serviceTagPattern)
        }
        let uuid = uuid
        if uuid[6] >> 4 != 1 {
            found.append(.uuidVersion)
        }
        if uuid[8] & 0x80 == 0 {
            found.append(.uuidVariant)
        }
        if stored[0xF3] != 0x02 {
            found.append(.constantWrong)
        }
        let tail = Array(uuid[10..<16])
        let copy = Array(stored[0x130..<0x136])
        let legacyCopy = Array(stored[0x128..<0x12E])
        if copy != tail && legacyCopy != tail {
            let isBlank: ([UInt8]) -> Bool = { $0.allSatisfy { $0 == 0xFF || $0 == 0x00 } }
            found.append(isBlank(copy) && isBlank(legacyCopy) ? .tailCopyErased : .tailCopyStale)
        }
        return found
    }

    // MARK: - The checks a wiped or tampered block fails

    /// The block `stored` holds, when the checks a wiped or tampered block
    /// fails all pass: the signature at +0x3C, a 4 KiB-aligned start, a
    /// system serial that reads as one, a service tag that reads as one, and
    /// padding everywhere the fields are not.
    public static func found(stored: [UInt8], offset: UInt64) -> AcerDMIArea? {
        guard stored.count == Int(size),
              offset % alignment == 0,
              Array(stored[Int(signatureOffset)..<Int(signatureOffset) + signature.count]) == signature,
              isSerial(stored[0..<0x16]),
              isServiceTag(stored[0x50..<0x66]),
              isSparse(stored)
        else { return nil }
        return AcerDMIArea(offset: offset, stored: stored)
    }

    /// The system serial: 22 alphanumerics, the first of them "N".
    private static func isSerial(_ bytes: ArraySlice<UInt8>) -> Bool {
        isAlnum(bytes) && bytes.first == 0x4E
    }

    /// The service tag: 22 alphanumerics, the first two of them "NB".
    private static func isServiceTag(_ bytes: ArraySlice<UInt8>) -> Bool {
        isAlnum(bytes) && Array(bytes.prefix(2)) == Array("NB".utf8)
    }

    private static func isAlnum(_ bytes: ArraySlice<UInt8>) -> Bool {
        bytes.allSatisfy {
            (0x30...0x39).contains($0) || (0x41...0x5A).contains($0) || (0x61...0x7A).contains($0)
        }
    }

    /// Where the block keeps its fields, the union over the dumps read from:
    /// outside these stretches, every byte is padding — FF or 00.
    static let dataWindows: [(offset: Int, length: Int)] = [
        (0x00, 0x20),
        (0x30, 0x20),
        (0x50, 0x20),
        (0x70, 0x30),
        (0xA0, 0x20),
        (0xC0, 0x20),
        (0xEB, 1),
        (0xEC, 1),
        (0xEE, 1),
        (0xF3, 1),
        (0xF4, 1),
        (0xF6, 1),
        (0xF8, 1),
        (0xFB, 1),
        (0x128, 0xE),
        (0x140, 0xE),
        (0x690, 0x46)
    ]

    private static func isSparse(_ stored: [UInt8]) -> Bool {
        var covered = [Bool](repeating: false, count: Int(size))
        for window in dataWindows {
            for index in window.offset..<(window.offset + window.length) {
                covered[index] = true
            }
        }
        return stored.enumerated().allSatisfy { index, byte in
            covered[index] || byte == 0xFF || byte == 0x00
        }
    }
}

/// Something about the block a technician should know before trusting it.
public enum AcerDMIFinding: Equatable, Sendable {
    /// The factory serials read "00" at offset 7 and "3400" at the end.
    case serialPattern
    /// The factory service tags read "1100" at offset 5 and "3400" at the
    /// end.
    case serviceTagPattern
    /// The factory UUIDs are version 1.
    case uuidVersion
    /// The factory UUIDs are variant 1: the top bit of their ninth byte is
    /// set.
    case uuidVariant
    /// The constant 02 at +0xF3 reads as something else.
    case constantWrong
    /// The copy of the UUID's last six bytes is erased.
    case tailCopyErased
    /// The copy of the UUID's last six bytes is there, but it does not read
    /// as the UUID's last six. It is a copy, not a checksum: it went stale
    /// when the UUID was changed after.
    case tailCopyStale

    /// A problem, as opposed to something worth knowing.
    public var isProblem: Bool {
        self != .tailCopyErased
    }

    public var text: String {
        switch self {
        case .serialPattern:
            return L("The serial does not hold the factory pattern: the factory ones read 00 at offset 7 and 3400 at the end.")
        case .serviceTagPattern:
            return L("The service tag does not hold the factory pattern: the factory ones read 1100 at offset 5 and 3400 at the end.")
        case .uuidVersion:
            return L("The UUID is not a version 1 one, as the factory ones are.")
        case .uuidVariant:
            return L("The UUID's variant bit is not set, as it is on the factory ones. A cleaned or tampered UUID is the usual reason.")
        case .constantWrong:
            return L("The constant at +0xF3 is not 02.")
        case .tailCopyErased:
            return L("The copy of the UUID's last six bytes is erased. It is a copy, not a checksum, so nothing checks wrong because of it.")
        case .tailCopyStale:
            return L("The copy of the UUID's last six bytes does not read as the UUID's last six. It is a copy, not a checksum: it went stale when the UUID was changed after.")
        }
    }
}

extension Parser {
    /// `nodes` with every Acer DMI block read out as a row: out of the
    /// padding it lies in, or out of the flash-device-map region that labels
    /// it "Unused" where the Insyde map carves it out of the padding — on a
    /// 4 KiB boundary of the file, where the dumps read from lay them.
    func readingAcerDMIStores(_ nodes: [UEFINode], emptyByte: UInt8) -> [UEFINode] {
        nodes.map { node in
            guard node.kind == .padding || node.kind == .flashDeviceMapRegion else { return node }
            var read = node
            if !node.children.isEmpty {
                read.children = readingAcerDMIStores(node.children, emptyByte: emptyByte)
                return read
            }
            guard !node.isErased else { return node }
            let body = node.body
            let step = AcerDMIArea.alignment
            var found: [UInt64] = []
            var at = (body.lowerBound + step - 1) / step * step
            while at + AcerDMIArea.size <= body.upperBound {
                let signatureAt = at + AcerDMIArea.signatureOffset
                if reader.bytes(at: signatureAt, count: UInt64(AcerDMIArea.signature.count))
                    == AcerDMIArea.signature,
                   let stored = reader.bytes(at: at, count: AcerDMIArea.size),
                   AcerDMIArea.found(stored: stored, offset: at) != nil {
                    found.append(at)
                }
                at += step
            }
            guard !found.isEmpty else { return node }
            var rows: [UEFINode] = []
            var claimed = body.lowerBound
            for start in found {
                rows += padding(from: claimed, to: start, emptyByte: emptyByte)
                var row = UEFINode(kind: .acerDMIStore, name: L("Acer DMI"), range: start..<(start + AcerDMIArea.size))
                row.isFixed = true
                rows.append(row)
                claimed = start + AcerDMIArea.size
            }
            read.children = rows + padding(from: claimed, to: body.upperBound, emptyByte: emptyByte)
            return read
        }
    }
}
