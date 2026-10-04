import Foundation

/// A structure the FIT points at that a board keeps outside every volume
/// (`UEFI_IMAGE_FORMAT.md` §9): the table itself, the Startup ACM, the Boot
/// Guard Key Manifest and Boot Policy.
///
/// The CPU finds them by address, so a vendor is free to put them anywhere,
/// and some put them in the padding between volumes, or in the body of a pad
/// file. The scan reads those bytes as padding, as UEFITool does. The FIT says
/// where each one starts, and its own header how long it is — the FIT's size
/// field, which for a manifest gives the same length in bytes, is not trusted
/// for it.
public struct FITComponent: Equatable, Sendable {
    /// By the FIT type that names it; the table is the header row's type.
    public enum Kind: UInt8, Equatable, Sendable, CaseIterable {
        case table = 0x00
        case startupACM = 0x02
        case keyManifest = 0x0B
        case bootPolicy = 0x0C

        public var name: String {
            switch self {
            case .table: return "FIT"
            case .startupACM: return "Startup ACM"
            case .keyManifest: return "Boot Guard Key Manifest"
            case .bootPolicy: return "Boot Guard Boot Policy"
            }
        }
    }

    public var kind: Kind
    public var range: Range<UInt64>

    public init(kind: Kind, range: Range<UInt64>) {
        self.kind = kind
        self.range = range
    }

    /// `__KEYM__`.
    static let keyManifestID: UInt64 = 0x5F5F_4D59_454B_5F5F
    static let acmModuleType: UInt16 = 0x0002
    static let intelVendor: UInt32 = 0x8086
    /// Larger than any of them is: a length past it is not a length.
    static let largestManifest: UInt64 = 0x1_0000
    static let largestACM: UInt64 = 0x10_0000

    /// Every component the FIT of the image in `reader` names, in file order,
    /// given where the image sits in the address space — and, when the image
    /// keeps a Top Swap copy, the same components in the copy.
    public static func all(in reader: ImageReader, addressDiff: UInt64) -> [FITComponent] {
        func offset(_ address: UInt64) -> UInt64? {
            guard address >= addressDiff, address - addressDiff < reader.count else { return nil }
            return address - addressDiff
        }
        guard let pointer = offset(TopSwapCopy.fitPointerAddress),
              let tableAddress = reader.uint32(at: pointer).map(UInt64.init),
              let table = offset(tableAddress),
              let tableLength = length(of: .table, at: table, in: reader)
        else { return [] }

        var found = [FITComponent(kind: .table, range: table..<(table + tableLength))]
        for row in stride(from: table + FITComponent.rowSize, to: table + tableLength, by: Int(FITComponent.rowSize)) {
            guard let type = reader.uint8(at: row + 0x0E).flatMap({ Kind(rawValue: $0 & 0x7F) }),
                  type != .table,
                  let start = reader.uint64(at: row).flatMap(offset),
                  let length = length(of: type, at: start, in: reader)
            else { continue }
            let component = FITComponent(kind: type, range: start..<(start + length))
            if !found.contains(component) { found.append(component) }
        }

        // The copy names the top block's addresses, so its components are the
        // top block's, moved down by the block's size.
        if let copy = TopSwapCopy.find(
            pointerOffset: pointer, pointerAddress: tableAddress, table: table..<(table + tableLength), in: reader
        ) {
            for component in found where copy.top.contains(component.range.lowerBound) {
                let start = copy.swap(component.range.lowerBound)
                if length(of: component.kind, at: start, in: reader) == UInt64(component.range.count) {
                    found.append(FITComponent(kind: component.kind, range: start..<(start + UInt64(component.range.count))))
                }
            }
        }
        return found.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    static let rowSize: UInt64 = 16

    /// How long the component of `kind` at `offset` says it is, or nil when
    /// what is there is not one.
    static func length(of kind: Kind, at offset: UInt64, in reader: ImageReader) -> UInt64? {
        let length: UInt64?
        switch kind {
        case .table:
            guard reader.uint64(at: offset) == TopSwapCopy.fitSignature,
                  let rows = reader.uint24(at: offset + 8), rows > 0
            else { return nil }
            length = UInt64(rows) * rowSize
        case .startupACM:
            guard reader.uint16(at: offset) == acmModuleType,
                  reader.uint32(at: offset + 0x10) == intelVendor,
                  let dwords = reader.uint32(at: offset + 0x18),
                  UInt64(dwords) * 4 <= largestACM
            else { return nil }
            length = UInt64(dwords) * 4
        case .keyManifest:
            length = keyManifestLength(at: offset, in: reader)
        case .bootPolicy:
            length = bootPolicyLength(at: offset, in: reader)
        }
        guard let length, length > 0, reader.has(offset..<(offset + length)) else { return nil }
        return length
    }

    /// v1: the header, one hash, the key and signature. v2: the key and
    /// signature at the offset the header gives.
    private static func keyManifestLength(at offset: UInt64, in reader: ImageReader) -> UInt64? {
        guard reader.uint64(at: offset) == keyManifestID, let version = reader.uint8(at: offset + 8) else { return nil }
        let keySignature: UInt64
        if version < BootPolicy.v2MinVersion {
            guard let hashLength = reader.uint16(at: offset + 0x0E) else { return nil }
            keySignature = 0x10 + UInt64(hashLength)
        } else {
            guard let at = reader.uint16(at: offset + 0x0C) else { return nil }
            keySignature = UInt64(at)
        }
        return manifestLength(keySignature, at: offset, in: reader)
    }

    /// v2: the key and signature at the offset the header gives. v1 has no
    /// such offset and no element sizes: its elements are stepped over by what
    /// each is known to hold, up to the `__PMSG__` that ends them.
    private static func bootPolicyLength(at offset: UInt64, in reader: ImageReader) -> UInt64? {
        guard reader.uint64(at: offset) == BootPolicy.structureID,
              let version = reader.uint8(at: offset + 8)
        else { return nil }
        if version >= BootPolicy.v2MinVersion {
            guard let at = reader.uint16(at: offset + 0x0C) else { return nil }
            return manifestLength(UInt64(at), at: offset, in: reader)
        }
        var element = offset + BootPolicy.v1HeaderSize
        for _ in 0..<BootPolicy.maxElements {
            guard element - offset < largestManifest, let id = reader.uint64(at: element) else { return nil }
            let body = element + BootPolicy.v1ElementHeaderSize
            switch id {
            case BootPolicy.ibbs:
                guard let segments = reader.uint8(at: body + 0x7B) else { return nil }
                element = body + 0x7C + UInt64(segments) * BootPolicy.segmentSize
            case BootPolicy.pmda:
                guard let entries = reader.uint32(at: body + 6),
                      let entrySize: UInt64 = reader.uint32(at: body + 2).flatMap({ [1: 0x28, 2: 0x2C][$0] })
                else { return nil }
                element = body + 0x0A + UInt64(entries) * entrySize
            case BootPolicy.pmsg:
                return manifestLength(body - offset, at: offset, in: reader)
            default:
                return nil
            }
        }
        return nil
    }

    /// A manifest ends with its key and signature (`KEY_AND_SIGNATURE`): a
    /// version and key id, the public key — version, size in bits, exponent,
    /// modulus — then the scheme and the signature — version, size in bits,
    /// hash algorithm, the signature itself.
    private static func manifestLength(_ keySignature: UInt64, at offset: UInt64, in reader: ImageReader) -> UInt64? {
        let at = offset + keySignature
        guard let keyBits = reader.uint16(at: at + 4), keyBits > 0, keyBits % 8 == 0,
              let signatureBits = reader.uint16(at: at + 13 + UInt64(keyBits) / 8),
              signatureBits > 0, signatureBits % 8 == 0
        else { return nil }
        let length = keySignature + 17 + UInt64(keyBits) / 8 + UInt64(signatureBits) / 8
        return length <= largestManifest ? length : nil
    }
}

/// What a component's header says, as far as this tool reads it
/// (`UEFI_IMAGE_FORMAT.md` §9): the fields UEFITool shows for it.
public enum FITComponentHeader: Equatable, Sendable {
    /// The number of rows, the header row among them.
    case table(rows: UInt32)
    /// `date` as the ACM stores it, BCD `yyyy-mm-dd`.
    case acm(subtype: UInt16, headerVersion: UInt32, chipsetID: UInt16, date: String, svn: UInt16)
    case keyManifest(version: UInt8, kmVersion: UInt8, svn: UInt8, id: UInt8)
    case bootPolicy(version: UInt8, revision: UInt8, svn: UInt8, acmSVN: UInt8)

    public static func read(_ kind: FITComponent.Kind, at offset: UInt64, in reader: ImageReader) -> FITComponentHeader? {
        switch kind {
        case .table:
            return reader.uint24(at: offset + 8).map { .table(rows: $0) }
        case .startupACM:
            guard let subtype = reader.uint16(at: offset + 2),
                  let headerVersion = reader.uint32(at: offset + 8),
                  let chipset = reader.uint16(at: offset + 0x0C),
                  let day = reader.uint8(at: offset + 0x14),
                  let month = reader.uint8(at: offset + 0x15),
                  let year = reader.uint16(at: offset + 0x16),
                  let svn = reader.uint16(at: offset + 0x1C)
            else { return nil }
            let date = String(format: "%04X-%02X-%02X", year, month, day)
            return .acm(subtype: subtype, headerVersion: headerVersion, chipsetID: chipset, date: date, svn: svn)
        case .keyManifest:
            // v2 moves the fields past the key signature's offset and three
            // reserved bytes.
            guard let version = reader.uint8(at: offset + 8) else { return nil }
            let fields = offset + (version < BootPolicy.v2MinVersion ? 9 : 0x11)
            guard let kmVersion = reader.uint8(at: fields),
                  let svn = reader.uint8(at: fields + 1),
                  let id = reader.uint8(at: fields + 2)
            else { return nil }
            return .keyManifest(version: version, kmVersion: kmVersion, svn: svn, id: id)
        case .bootPolicy:
            guard let version = reader.uint8(at: offset + 8) else { return nil }
            let fields = offset + (version < BootPolicy.v2MinVersion ? 0x0A : 0x0E)
            guard let revision = reader.uint8(at: fields),
                  let svn = reader.uint8(at: fields + 1),
                  let acmSVN = reader.uint8(at: fields + 2)
            else { return nil }
            return .bootPolicy(version: version, revision: revision, svn: svn, acmSVN: acmSVN)
        }
    }

    /// The ACM's module subtype, by the names UEFITool gives them.
    public static func acmSubtypeName(_ subtype: UInt16) -> String? {
        switch subtype {
        case 0: return "TXT"
        case 1: return "Startup"
        case 3: return "Boot Guard"
        default: return nil
        }
    }
}

extension Parser {
    /// What the FIT of the image this parser reads names, worked out once:
    /// every raw area the parser scans asks.
    var fitComponents: [FITComponent] {
        if let cached = fitComponentsCache { return cached }
        let found = addressDiffFromTail().map { FITComponent.all(in: reader, addressDiff: $0) } ?? []
        fitComponentsCache = found
        return found
    }

    /// `nodes` with every structure the FIT names that lies wholly inside a
    /// stretch of padding read out of it (`UEFI_IMAGE_FORMAT.md` §9), the way
    /// the flash device map's regions are. Like those, this runs before the
    /// second pass has the mapping, so it takes it from a Volume Top File at
    /// the image's tail; an image with no VTF at its tail keeps its padding.
    func readingFITComponents(_ nodes: [UEFINode], emptyByte: UInt8) -> [UEFINode] {
        guard nodes.contains(where: { $0.kind == .padding }) else { return nodes }
        var result = nodes
        for component in fitComponents {
            let node = UEFINode(
                kind: .fitComponent,
                subtype: component.kind.rawValue,
                name: component.kind.name,
                header: component.range.lowerBound..<component.range.lowerBound,
                body: component.range,
                // The FIT names it by address: moved, it is not found.
                isFixed: true
            )
            result = placingInPadding(node, in: result, emptyByte: emptyByte, accepts: { !$0.isErased }) ?? result
        }
        return result
    }
}
