import Foundation
import FirmwareCompression

/// A compressed section this parser opens: which ones those are, where the
/// compressed bytes sit, and how they are decoded
/// (`Design/UEFI/COMPRESSED_SECTIONS.md` §2, §3).
///
/// Read from the section's own header rather than from its node, because a
/// buffer evicted from the cache is decoded again from nothing but the offsets
/// in a `ByteSpace` — the nodes that were built from it may be long gone.
enum CompressedSection {
    enum Algorithm: Equatable, Sendable {
        case lzma
        case lzmaX86
        /// Tiano or EFI 1.1: one header for both, told apart after decoding.
        case tiano

        var name: String {
            switch self {
            case .lzma: return "LZMA"
            case .lzmaX86: return "LZMA with x86 filter"
            case .tiano: return "Tiano"
            }
        }
    }

    /// `EFI_GUIDED_SECTION_PROCESSING_REQUIRED` (§6.3).
    static let processingRequired: UInt16 = 0x01

    private static let lzma: Set<EFIGUID> = [
        KnownGUIDs.guid("EE4E5898-3914-4259-9D6E-DC7BD79403CF"),
        KnownGUIDs.guid("0ED85E23-F253-413F-A03C-901987B04397"),    // HP
        KnownGUIDs.guid("BD9921EA-ED91-404A-8B2F-B4D724747C8C")     // Microsoft
    ]
    private static let lzmaX86 = KnownGUIDs.guid("D42AE6BD-1352-4BFB-909A-CA72A6EAE889")
    private static let tiano = KnownGUIDs.guid("A31280AD-481E-41B6-95E8-127F4C984779")
    private static let gzip = KnownGUIDs.guid("1D301FE9-BE79-4353-91C2-D23BC959AE0C")

    /// A compression section's `CompressionType` (§2.1): `0x01` is EDK2's
    /// standard compression — Tiano or EFI 1.1 — `0x02` is what EDK2 calls
    /// customized and means LZMA, `0x86` is LZMA with the x86 filter.
    static func algorithm(compressionType: UInt8) -> Algorithm? {
        switch compressionType {
        case 0x01: return .tiano
        case 0x02: return .lzma
        case 0x86: return .lzmaX86
        default: return nil
        }
    }

    static func algorithm(guid: EFIGUID) -> Algorithm? {
        if lzma.contains(guid) { return .lzma }
        if guid == lzmaX86 { return .lzmaX86 }
        if guid == tiano { return .tiano }
        return nil
    }

    /// Every GUID-defined section whose body is compressed, decoded here or not.
    private static let compressedGUIDs: Set<EFIGUID> = lzma.union([
        lzmaX86, tiano, gzip,
        KnownGUIDs.guid("CE3233F5-2CD6-4D87-9152-4A238BB6D1C4"),    // Zlib (AMD)
        KnownGUIDs.guid("991EFAC0-E260-416B-A4B8-3B153072B804"),    // Zlib (AMD, second)
        KnownGUIDs.guid("3D532050-5CDA-4FD0-879E-0F7F630D5AFB")     // Brotli
    ])

    /// A compression section's algorithm by the name a panel shows.
    static func algorithmName(compressionType: UInt8) -> String {
        switch compressionType {
        case 0x01: return "Tiano"
        case 0x02: return "LZMA"
        case 0x86: return "LZMA with x86 filter"
        default: return String(format: "Compression type 0x%02X", compressionType)
        }
    }

    /// A GUID-defined section's algorithm by the name a panel shows, or nil when
    /// its body is not compressed — a CRC32 or a signed section.
    static func algorithmName(guid: EFIGUID) -> String? {
        guard compressedGUIDs.contains(guid) else { return nil }
        return KnownGUIDs.guidedSection(guid)?.name
    }

    /// The GUID-defined sections whose body is compressed, decoded here or not
    /// — the ones UEFITool expects `PROCESSING_REQUIRED` on (§2.2).
    static func isCompressed(guid: EFIGUID) -> Bool {
        algorithm(guid: guid) != nil || guid == tiano || guid == gzip
    }

    struct Located: Equatable, Sendable {
        /// The compressed bytes, in the space the section header was read in.
        var body: Range<UInt64>
        var algorithm: Algorithm
        /// A compression section's `UncompressedLength`. A GUID-defined one
        /// says nothing, and the stream's own header is all there is.
        var declaredLength: UInt64?
    }

    /// The section whose header starts at `offset`, when it is one this parser
    /// decodes.
    ///
    /// The extended size is taken only when it is larger than a three-byte
    /// size could say — in an FFSv2 volume `0xFFFFFF` is a size, not a marker,
    /// and no FFSv3 section uses the long form for less.
    static func locate(at offset: UInt64, in reader: ImageReader) -> Located? {
        guard let shortSize = reader.uint24(at: offset),
              let type = reader.uint8(at: offset + 3)
        else { return nil }
        var headerSize = Section.headerSize
        var size = UInt64(shortSize)
        if shortSize == Section.extendedSizeMarker,
           let extended = reader.uint32(at: offset + 4), extended > Section.extendedSizeMarker {
            headerSize = Section.extendedHeaderSize
            size = UInt64(extended)
        }
        let (declaredEnd, overflowed) = offset.addingReportingOverflow(size)
        guard !overflowed, size > headerSize else { return nil }
        let end = min(declaredEnd, reader.count)

        switch type {
        case Section.compression:
            let start = offset + headerSize + Section.compressionHeaderSize
            guard start < end,
                  let compressionType = reader.uint8(at: offset + headerSize + 4),
                  let algorithm = algorithm(compressionType: compressionType),
                  let declared = reader.uint32(at: offset + headerSize)
            else { return nil }
            return Located(body: start..<end, algorithm: algorithm, declaredLength: UInt64(declared))

        case Section.guidDefined:
            guard let guid = reader.guid(at: offset + headerSize),
                  let algorithm = algorithm(guid: guid),
                  let dataOffset = reader.uint16(at: offset + headerSize + 16),
                  UInt64(dataOffset) >= headerSize + Section.guidDefinedHeaderSize,
                  offset + UInt64(dataOffset) < end
            else { return nil }
            return Located(
                body: (offset + UInt64(dataOffset))..<end,
                algorithm: algorithm,
                declaredLength: nil
            )

        default:
            return nil
        }
    }

    static func decode(
        _ section: Located,
        in reader: ImageReader,
        limit: UInt64
    ) -> Result<FirmwareDecompression.Decoded, FirmwareDecompression.Failure> {
        guard let bytes = reader.bytes(section.body) else { return .failure(.truncated) }
        do {
            switch section.algorithm {
            case .lzma: return .success(try FirmwareDecompression.lzma(bytes, limit: limit))
            case .lzmaX86: return .success(try FirmwareDecompression.lzmaX86(bytes, limit: limit))
            case .tiano: return .success(chooseTiano(try FirmwareDecompression.tiano(bytes, limit: limit)))
            }
        } catch let failure as FirmwareDecompression.Failure {
            return .failure(failure)
        } catch {
            return .failure(.corrupt)
        }
    }

    /// Which of a Tiano buffer's readings is the one (§3.3): the only one that
    /// decoded, or — both having decoded — the first that reads as a run of
    /// sections, Tiano before EFI 1.1. When neither does, Tiano: it is what
    /// UEFITool keeps too, and the walk over it then says what is wrong.
    static func chooseTiano(_ decoded: FirmwareDecompression.TianoDecoded) -> FirmwareDecompression.Decoded {
        switch (decoded.tiano, decoded.efi11) {
        case let (tiano?, nil):
            return .init(bytes: tiano, variant: .tiano)
        case let (nil, efi11?):
            return .init(bytes: efi11, variant: .efi11)
        case let (tiano?, efi11?):
            guard !readsAsSections(tiano), readsAsSections(efi11) else {
                return .init(bytes: tiano, variant: .tiano)
            }
            return .init(bytes: efi11, variant: .efi11)
        case (nil, nil):
            return .init(bytes: [], variant: .tiano)
        }
    }

    /// Whether a buffer walks as sections without a single complaint — the
    /// pre-parse UEFITool decides between the two readings with.
    static func readsAsSections(_ buffer: [UInt8]) -> Bool {
        guard !buffer.isEmpty else { return false }
        let parser = Parser(reader: ImageReader(buffer), limits: UEFIParser.Limits())
        let nodes = parser.walkSections(
            0..<UInt64(buffer.count), ffsVersion: 3,
            emptyByte: Parser.defaultEmptyByte, depth: 0
        )
        return parser.diagnostics.isEmpty && nodes.contains { $0.kind == .section }
    }
}
