import Foundation

/// Something wrong with the image, reported rather than thrown.
///
/// A dump off a real flash chip almost always has one structure that does not
/// match the specification (§11), so a parser that throws on the first one
/// parses nothing anyone owns. Every level here collects and carries on, and
/// what it collects is the interesting half of the output: the reason to open a
/// tool-module on an image is usually that something in it is already wrong.
///
/// A diagnostic locates itself by offset and not by node id, because it is
/// raised while the node is still being built — and an offset is the better
/// answer anyway: `UEFIImage.nodes(containing:)` turns it back into the node,
/// and the dump can put the caret on it.
public struct UEFIDiagnostic: Equatable, Sendable {
    public enum Severity: Sendable {
        /// The value is wrong but the parse went on.
        case warning
        /// Parsing this level stopped here.
        case error
    }

    /// The structure being read when the trouble showed up.
    public enum Structure: String, Sendable {
        case capsuleHeader
        case flashDescriptor
        case volumeHeader
        case volumeExtendedHeader
        case volumeBody
        case fileHeader
        case fileBody
        case sectionHeader
        case sectionBody
        case microcodeHeader
        case resetVector
        /// An NVRAM store: the VSS / VSS2 / FTW and the rest that make up an
        /// NVRAM volume body (§9).
        case nvramStore
        /// An Intel Boot Guard Boot Policy Manifest
        /// (`BOOT_GUARD_PROTECTED_RANGES.md` §4).
        case bootPolicy
        /// A Phoenix or AMI vendor hash table (§5).
        case vendorHashFile
        /// An Insyde H2O Flash Device Map (§5.3).
        case flashDeviceMap
    }

    public enum Kind: Equatable, Sendable {
        /// The image ends before the structure does.
        case truncated(Structure)
        /// A size field of zero, which would loop forever if believed (§11).
        case zeroSize(Structure)
        case checksumMismatch(Structure, stored: UInt64, computed: UInt64)
        case sizeMismatch(Structure, stored: UInt64, computed: UInt64)
        /// A volume whose file system GUID is not one we parse; its body is
        /// kept whole rather than read as FFS (§3.4).
        case unknownFileSystem(EFIGUID)
        case unknownType(Structure, UInt8)
        /// A tree deep enough to be a loop rather than an image (§11).
        case recursionLimit
        /// A Volume Top File was found but cannot anchor the image — it ends
        /// past the top of the address space (§5.7). Not having one at all is
        /// no diagnostic: a partial dump of a BIOS region or an EC has no VTF
        /// and is not defective for it. `UEFIImage.addressDiff` being nil says
        /// everything there is to say about that.
        case addressesUnknown
        /// Two flash regions covering the same bytes: a descriptor nobody can
        /// trust (§2.2).
        case overlappingRegions
        /// A compressed section this parser decodes did not decode
        /// (`COMPRESSED_SECTIONS.md` §3.5): the data ended first, or is not the
        /// algorithm's. The section is kept whole.
        case decompressionFailed(algorithm: String, truncated: Bool)
        /// A compressed section declares more than `UEFIParser.Limits` lets a
        /// parse allocate. Kept whole, never allocated.
        case decompressedTooLarge(algorithm: String, declared: UInt64)
        /// A compression section's `UncompressedLength` is not the size that
        /// came out of it.
        case decompressedSizeMismatch(stored: UInt64, computed: UInt64)
        /// A compressed GUID-defined section without `PROCESSING_REQUIRED` in
        /// its attributes (§6.3).
        case processingRequiredNotSet
        /// A protected range, or the manifest naming it, is not in this image
        /// (`BOOT_GUARD_PROTECTED_RANGES.md` §3). Dropped, never used
        /// unconverted.
        case protectedRangeOutsideImage(String)
        /// A list names a range the image cannot place: a physical address
        /// with no Volume Top File, or no DXE Core volume to start from (§9.2).
        case protectedRangeNotPlaced(String)
        /// The bytes of a protected range do not hash to the stored digest
        /// (§6). A warning for every kind: for the IBB the reference
        /// implementation never makes the comparison (§6.1).
        case protectedRangeHashMismatch(String)
        /// A digest stored with an algorithm this tool does not compute.
        case unsupportedHashAlgorithm(UInt16)
        /// An AMI hash table of a size no known version has (§5.2).
        case unknownVendorHashFileSize(UInt64)
        /// A structure of a revision later than any this parser reads; it is
        /// skipped.
        case unknownRevision(Structure, UInt8)
        /// A flash device map whose entries are of a size or format nobody has
        /// described; the store is kept whole.
        case unknownFlashDeviceMapEntries(size: UInt32, format: UInt8)

        public var severity: Severity {
            switch self {
            case .truncated, .zeroSize, .recursionLimit:
                return .error
            case .checksumMismatch, .sizeMismatch, .unknownFileSystem,
                 .unknownType, .addressesUnknown, .overlappingRegions,
                 .decompressionFailed, .decompressedTooLarge,
                 .decompressedSizeMismatch, .processingRequiredNotSet,
                 .protectedRangeOutsideImage, .protectedRangeNotPlaced,
                 .protectedRangeHashMismatch, .unsupportedHashAlgorithm,
                 .unknownVendorHashFileSize, .unknownRevision,
                 .unknownFlashDeviceMapEntries:
                return .warning
            }
        }
    }

    /// Where a diagnostic raised inside a compressed section really is: an
    /// offset in the buffer that section decompresses to.
    public struct InnerLocation: Equatable, Sendable {
        public var space: ByteSpace
        public var offset: UInt64

        public init(space: ByteSpace, offset: UInt64) {
            self.space = space
            self.offset = offset
        }
    }

    public var kind: Kind
    /// Where in the image, absolute. For a diagnostic raised inside a
    /// compressed section, the outermost compressed section's header — the
    /// bytes of the file that hold the trouble, and the most the dump can show
    /// (`COMPRESSED_SECTIONS.md` §5.3).
    public var offset: UInt64
    /// Where inside, when the trouble is in a decompressed buffer.
    public var inside: InnerLocation?

    public init(_ kind: Kind, at offset: UInt64, inside: InnerLocation? = nil) {
        self.kind = kind
        self.offset = offset
        self.inside = inside
    }

    public var severity: Severity { kind.severity }

    /// One line, for a tool-module's own list. The host never sees these — where
    /// a tool-module's diagnostics go is its panel (`Design/TOOL_MODULES_PLAN.md`).
    public var message: String {
        guard let inside else { return kindMessage }
        return kindMessage + " (at \(hex(inside.offset)) in what the compressed section at "
            + "\(hex(offset)) decompresses to)"
    }

    private var kindMessage: String {
        switch kind {
        case .truncated(let structure):
            return "\(structure.label) runs past the end of the image"
        case .zeroSize(let structure):
            return "\(structure.label) has a size of zero"
        case .checksumMismatch(let structure, let stored, let computed):
            return "\(structure.label) checksum is \(hex(stored)), computed \(hex(computed))"
        case .sizeMismatch(let structure, let stored, let computed):
            return "\(structure.label) size is \(hex(stored)), computed \(hex(computed))"
        case .unknownFileSystem(let guid):
            return "unknown volume file system \(guid)"
        case .unknownType(let structure, let code):
            return "unknown \(structure.label) type \(hex(UInt64(code)))"
        case .recursionLimit:
            return "nesting is too deep to be an image"
        case .addressesUnknown:
            return "the volume top file ends past the top of the address space"
        case .overlappingRegions:
            return "this flash region overlaps the one before it"
        case .decompressionFailed(let algorithm, let truncated):
            return truncated
                ? "\(algorithm) data ends before it has decompressed"
                : "\(algorithm) data does not decompress"
        case .decompressedTooLarge(let algorithm, let declared):
            return "\(algorithm) data says it decompresses to \(hex(declared)) bytes, "
                + "more than a parse allocates"
        case .decompressedSizeMismatch(let stored, let computed):
            return "compressed section says it decompresses to \(hex(stored)) bytes, "
                + "it came to \(hex(computed))"
        case .processingRequiredNotSet:
            return "compressed GUID-defined section does not have PROCESSING_REQUIRED set"
        case .protectedRangeOutsideImage(let name):
            return "\(name) lies outside the image"
        case .protectedRangeNotPlaced(let name):
            return "\(name) cannot be placed: the image has no volume top file to map its address, "
                + "or no DXE Core volume for it to start at"
        case .protectedRangeHashMismatch(let name):
            return "\(name) does not match its hash: with the protection active, the image may refuse to boot"
        case .unsupportedHashAlgorithm(let algorithm):
            return "\(TCGHash.name(algorithm)) digests are not computed by this tool"
        case .unknownVendorHashFileSize(let size):
            return "AMI vendor hash table of \(hex(size)) bytes is of no known version"
        case .unknownRevision(let structure, let revision):
            return "\(structure.label) revision \(hex(UInt64(revision))) is later than any this parser reads"
        case .unknownFlashDeviceMapEntries(let size, let format):
            return "Insyde flash device map entries of \(hex(UInt64(size))) bytes in format "
                + "\(hex(UInt64(format))) are of no known layout"
        }
    }

    /// This diagnostic — raised at an offset in `space` by a parser that only
    /// knew the buffer it was reading — located the way every diagnostic is:
    /// at bytes of the file, with the inside offset kept.
    func located(in space: ByteSpace) -> UEFIDiagnostic {
        guard let outermost = space.outermostSection else { return self }
        return UEFIDiagnostic(kind, at: outermost, inside: InnerLocation(space: space, offset: offset))
    }

    private func hex(_ value: UInt64) -> String {
        "0x" + String(value, radix: 16, uppercase: true)
    }
}

extension UEFIDiagnostic.Structure {
    var label: String {
        switch self {
        case .capsuleHeader: return "capsule header"
        case .flashDescriptor: return "flash descriptor"
        case .volumeHeader: return "volume header"
        case .volumeExtendedHeader: return "volume extended header"
        case .volumeBody: return "volume body"
        case .fileHeader: return "file header"
        case .fileBody: return "file body"
        case .sectionHeader: return "section header"
        case .sectionBody: return "section body"
        case .microcodeHeader: return "microcode header"
        case .resetVector: return "reset vector"
        case .nvramStore: return "NVRAM store"
        case .bootPolicy: return "Boot Policy Manifest"
        case .vendorHashFile: return "vendor hash table"
        case .flashDeviceMap: return "Insyde flash device map"
        }
    }
}
