import CryptoKit
import Foundation

/// A run of the file whose hash something checks at boot
/// (`Design/UEFI/BOOT_GUARD_PROTECTED_RANGES.md` §2): change a byte inside it
/// and the check fails, whatever the tree around it says.
public struct ProtectedRange: Equatable, Sendable {
    /// Where the list that named the range came from (§2).
    public enum Kind: Equatable, Sendable, CaseIterable {
        /// A Boot Policy IBB segment: checked by the processor and the ACM
        /// before the firmware runs.
        case ibb
        /// The Boot Policy's post-IBB hash, over the DXE root volume (§3).
        case postIbb
        /// An entry of the Microsoft PMDA element in the Boot Policy.
        case pmda
        case phoenix
        case amiV1
        case amiV2
        case amiV3
        case insyde

        /// The one kind the ACM checks before the first instruction of the
        /// BIOS; every other kind is checked by the firmware itself (§1).
        public var isIBB: Bool { self == .ibb }

        public var name: String {
            switch self {
            case .ibb: return "Boot Guard IBB segment"
            case .postIbb: return "Boot Guard post-IBB range"
            case .pmda: return "Microsoft PMDA entry"
            case .phoenix: return "Phoenix vendor hash range"
            case .amiV1: return "AMI vendor hash range (v1)"
            case .amiV2: return "AMI vendor hash range (v2)"
            case .amiV3: return "AMI vendor hash range (v3)"
            case .insyde: return "Insyde flash device map range"
            }
        }
    }

    /// A stored digest, by its TCG algorithm id (§4.4).
    public struct Digest: Equatable, Sendable {
        public var algorithm: UInt16
        public var bytes: [UInt8]

        public init(algorithm: UInt16, bytes: [UInt8]) {
            self.algorithm = algorithm
            self.bytes = bytes
        }

        public var algorithmName: String { TCGHash.name(algorithm) }
    }

    /// What hashing the range's bytes said (§6).
    public enum Verdict: Equatable, Sendable {
        case matches
        case mismatch
        /// Stored with an algorithm this tool does not compute — SM3, or an id
        /// it does not know. The range is still a range.
        case unsupported(algorithm: UInt16)
        /// Not hashed: the range, or one hashed together with it, could not be
        /// placed in this image, or the list stored no digest.
        case unchecked
    }

    public var kind: Kind
    /// Half-open, in file offsets. Nil when the list names the range but the
    /// image cannot place it — no Volume Top File for a physical address, or
    /// no DXE Core volume to start from (§9.2).
    public var range: Range<UInt64>?
    /// Usually one. A v2 IBB carries a digest per algorithm (§4.3).
    public var digests: [Digest]
    /// Where the list that named it is in the file.
    public var source: Range<UInt64>
    public var verdict: Verdict

    public init(
        kind: Kind,
        range: Range<UInt64>?,
        digests: [Digest] = [],
        source: Range<UInt64>,
        verdict: Verdict = .unchecked
    ) {
        self.kind = kind
        self.range = range
        self.digests = digests
        self.source = source
        self.verdict = verdict
    }
}

/// Every protected range an image names, and what hashing them found
/// (`BOOT_GUARD_PROTECTED_RANGES.md` §9.1).
public struct ProtectedRanges: Equatable, Sendable {
    /// What an edit to a run of the file breaks (§7.3), strongest first.
    public enum Protection: Equatable, Sendable {
        /// Entirely within the union of the IBB ranges.
        case ibb
        /// Entirely within the union of all ranges.
        case protected
        /// Overlaps a range without lying inside the union.
        case partial
    }

    /// In the order the lists were read: the Boot Policy's, then the vendor
    /// hash files' in the order of the tree.
    public var ranges: [ProtectedRange]
    /// OBB digests a v2 Boot Policy names. Nothing in the manifest says where
    /// the OBB is, so they are noted and not placed (§4.5).
    public var obbDigests: [ProtectedRange.Digest]
    /// What the reading had to complain about.
    public var diagnostics: [UEFIDiagnostic]

    public init(
        ranges: [ProtectedRange] = [],
        obbDigests: [ProtectedRange.Digest] = [],
        diagnostics: [UEFIDiagnostic] = []
    ) {
        self.ranges = ranges
        self.obbDigests = obbDigests
        self.diagnostics = diagnostics
    }

    /// Whether the image names any protection at all.
    public var isEmpty: Bool { ranges.isEmpty && obbDigests.isEmpty }

    /// §7.3: against the union of the ranges, so that neither their order nor
    /// a node spanning two adjacent segments changes the answer.
    public func protection(of range: Range<UInt64>) -> Protection? {
        guard !range.isEmpty else { return nil }
        let placed = ranges.compactMap(\.range)
        guard placed.contains(where: { $0.overlaps(range) }) else { return nil }
        let ibb = ranges.filter { $0.kind.isIBB }.compactMap(\.range)
        if Self.union(ibb).contains(where: { $0.encloses(range) }) { return .ibb }
        if Self.union(placed).contains(where: { $0.encloses(range) }) { return .protected }
        return .partial
    }

    /// A node's protection: by its bytes of the file, or — for a node inside a
    /// compressed section, whose offsets mean nothing in the file — by the
    /// outermost compressed section that holds it.
    public func protection(of node: UEFINode, in image: UEFIImage) -> Protection? {
        Self.fileRange(holding: node, in: image).flatMap(protection(of:))
    }

    /// The ranges that share a byte with `range`, in list order.
    public func ranges(touching range: Range<UInt64>) -> [ProtectedRange] {
        ranges.filter { $0.range?.overlaps(range) ?? false }
    }

    public func ranges(touching node: UEFINode, in image: UEFIImage) -> [ProtectedRange] {
        Self.fileRange(holding: node, in: image).map(ranges(touching:)) ?? []
    }

    /// The placed ranges as the rebuild planner takes them: a change inside
    /// the IBB is refused, one inside anything else is warned about.
    public var rebuildRanges: [UEFIRebuild.ProtectedRange] {
        ranges.compactMap { range in
            range.range.map {
                UEFIRebuild.ProtectedRange(
                    kind: range.kind.isIBB ? .ibb : .vendorHash, range: $0, name: range.kind.name
                )
            }
        }
    }

    /// The file bytes a node's protection is decided by.
    static func fileRange(holding node: UEFINode, in image: UEFIImage) -> Range<UInt64>? {
        if let range = node.fileRange { return range }
        guard let outermost = node.space.outermostSection,
              let section = image.innermostNode(containing: outermost),
              section.header.lowerBound == outermost
        else { return nil }
        return section.fileRange
    }

    /// Sorted, disjoint, with touching ranges joined.
    static func union(_ ranges: [Range<UInt64>]) -> [Range<UInt64>] {
        var merged: [Range<UInt64>] = []
        for range in ranges.filter({ !$0.isEmpty }).sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = merged.last, range.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    /// Reads every list an image carries: the Boot Policy through the FIT
    /// (§4), and the Phoenix and AMI hash files among the image's files of the
    /// file (§5) — then hashes what they name (§6).
    ///
    /// Reads what `image` has materialized. The DXE root volume is found only
    /// when the branch holding the DXE Core is open, so a caller that wants a
    /// post-IBB range placed opens the compressed sections first.
    public static func read(_ image: UEFIImage, readers: SpaceReaders) -> ProtectedRanges {
        let reading = ProtectedRangeReading(image: image, file: readers.file)
        reading.readBootPolicies()
        reading.readVendorHashFiles()
        reading.readFlashDeviceMaps()
        return reading.finish()
    }
}

extension Range where Bound == UInt64 {
    /// Whether `other` lies entirely inside this range.
    fileprivate func encloses(_ other: Range<UInt64>) -> Bool {
        lowerBound <= other.lowerBound && other.upperBound <= upperBound
    }
}

/// The TCG algorithm ids the manifests store (§4.4), and hashing with them.
public enum TCGHash {
    public static let sha1: UInt16 = 0x0004
    public static let sha256: UInt16 = 0x000B
    public static let sha384: UInt16 = 0x000C
    public static let sha512: UInt16 = 0x000D
    public static let null: UInt16 = 0x0010
    public static let sm3: UInt16 = 0x0012

    public static func name(_ algorithm: UInt16) -> String {
        switch algorithm {
        case sha1: return "SHA-1"
        case sha256: return "SHA-256"
        case sha384: return "SHA-384"
        case sha512: return "SHA-512"
        case null: return "NULL"
        case sm3: return "SM3"
        default: return String(format: "algorithm 0x%04X", algorithm)
        }
    }

    /// The digest of `ranges` concatenated, or nil when the algorithm is not
    /// one CryptoKit computes — SM3 is in no system library, and the project
    /// takes no third-party code (§9.1) — or a range is not in the image.
    static func digest(of ranges: [Range<UInt64>], in reader: ImageReader, algorithm: UInt16) -> [UInt8]? {
        switch algorithm {
        case sha1: return hash(Insecure.SHA1(), ranges, reader)
        case sha256: return hash(SHA256(), ranges, reader)
        case sha384: return hash(SHA384(), ranges, reader)
        case sha512: return hash(SHA512(), ranges, reader)
        default: return nil
        }
    }

    /// In chunks: a DXE volume is megabytes.
    private static func hash<Function: HashFunction>(
        _ function: Function, _ ranges: [Range<UInt64>], _ reader: ImageReader
    ) -> [UInt8]? {
        var function = function
        for range in ranges {
            guard reader.has(range) else { return nil }
            reader.forEachChunk(of: range, size: 1 << 20) { chunk in
                chunk.withUnsafeBytes { function.update(bufferPointer: $0) }
                return true
            }
        }
        return Array(function.finalize())
    }
}

/// The constants of §4 and §10.
enum BootPolicy {
    /// Where the pointer to the FIT is (`FIT_TABLE_FORMAT.md` §2).
    static let fitPointerAddress: UInt64 = 0xFFFF_FFC0
    /// `_FIT_   `.
    static let fitSignature: UInt64 = 0x2020_205F_5449_465F
    static let fitEntrySize: UInt64 = 16
    static let fitType: UInt8 = 0x0C

    static let structureID: UInt64 = 0x5F5F_5042_4341_5F5F    // __ACBP__
    static let ibbs: UInt64 = 0x5F5F_5342_4249_5F5F           // __IBBS__
    static let pmda: UInt64 = 0x5F5F_4144_4D50_5F5F           // __PMDA__
    static let pmsg: UInt64 = 0x5F5F_4753_4D50_5F5F           // __PMSG__
    static let v2MinVersion: UInt8 = 0x20

    static let v1HeaderSize: UInt64 = 0x10
    static let v1ElementHeaderSize: UInt64 = 9
    static let v2HeaderSize: UInt64 = 0x14
    static let v2ElementHeaderSize: UInt64 = 0x0C
    static let segmentSize: UInt64 = 0x0C
    static let hashV1Size: UInt64 = 0x24

    /// More elements than any manifest has: a list that goes on is a loop.
    static let maxElements = 64

    static let phoenixSignature: UInt64 = 0x4C42_5448_5341_4824  // $HASHTBL
    static let vendorEntrySize: UInt64 = 0x28
}

/// One read of the lists. A class because every list appends to the same
/// groups and diagnostics, as `Parser` does.
final class ProtectedRangeReading {
    /// The ranges one digest covers: an IBB's segments, an AMI v3 table's
    /// four — or a single range. One verdict for all of them (§6).
    private struct Group {
        var kind: ProtectedRange.Kind
        var members: [Range<UInt64>?] = []
        var digests: [ProtectedRange.Digest]
        var source: Range<UInt64>
        /// A member was dropped as outside the image, so the bytes the digest
        /// was taken over are not all here.
        var incomplete = false
        /// AMI v3 hashes its ranges in file order, whatever the table's order.
        var hashedInFileOrder = false
    }

    private enum Placement {
        case placed(Range<UInt64>)
        /// An erased or unused slot, not a range (§2).
        case unused
        case outside
        /// A physical address with no Volume Top File to map it.
        case unmapped
    }

    private let image: UEFIImage
    private let file: ImageReader
    private let nodes: [UEFINode]
    private var groups: [Group] = []
    private var obbDigests: [ProtectedRange.Digest] = []
    private var diagnostics: [UEFIDiagnostic] = []

    init(image: UEFIImage, file: ImageReader) {
        self.image = image
        self.file = file
        self.nodes = image.allNodes
    }

    private func note(_ kind: UEFIDiagnostic.Kind, at offset: UInt64) {
        diagnostics.append(UEFIDiagnostic(kind, at: offset))
    }

    // MARK: - The Boot Policy (§4)

    /// Every FIT row of type `0x0C`. The table's own validation is the FIT
    /// tool-module's; this is one read of the rows (§9.1).
    func readBootPolicies() {
        guard let pointer = image.offset(forAddress: BootPolicy.fitPointerAddress),
              let tableAddress = file.uint32(at: pointer),
              let table = image.offset(forAddress: UInt64(tableAddress)),
              file.uint64(at: table) == BootPolicy.fitSignature,
              let declared = file.uint24(at: table + 8)
        else { return }
        let rows = min(UInt64(declared), (file.count - table) / BootPolicy.fitEntrySize)
        guard rows > 1 else { return }
        for index in 1..<rows {
            let row = table + index * BootPolicy.fitEntrySize
            guard let type = file.uint8(at: row + 0x0E), type & 0x7F == BootPolicy.fitType,
                  let address = file.uint64(at: row)
            else { continue }
            guard let manifest = image.offset(forAddress: address) else {
                note(.protectedRangeOutsideImage("Boot Policy Manifest"), at: row)
                continue
            }
            guard file.uint64(at: manifest) == BootPolicy.structureID,
                  let version = file.uint8(at: manifest + 8)
            else {
                note(.truncated(.bootPolicy), at: manifest)
                continue
            }
            if version < BootPolicy.v2MinVersion {
                bootPolicyV1(at: manifest)
            } else {
                bootPolicyV2(at: manifest)
            }
        }
    }

    /// §4.2. An element has no size, so an unknown one ends the reading.
    private func bootPolicyV1(at manifest: UInt64) {
        var offset = manifest + BootPolicy.v1HeaderSize
        for _ in 0..<BootPolicy.maxElements {
            guard let id = file.uint64(at: offset) else { return note(.truncated(.bootPolicy), at: offset) }
            let body = offset + BootPolicy.v1ElementHeaderSize
            switch id {
            case BootPolicy.ibbs:
                guard let postIbb = hashV1(at: body + 0x2F),
                      let ibb = hashV1(at: body + 0x57),
                      let count = file.uint8(at: body + 0x7B),
                      let segments = segments(at: body + 0x7C, count: Int(count), limit: file.count)
                else { return note(.truncated(.bootPolicy), at: offset) }
                let end = body + 0x7C + UInt64(count) * BootPolicy.segmentSize
                addIBB(segments, digests: [ibb], source: offset..<end)
                addPostIBB(postIbb, source: offset..<end)
                offset = end
            case BootPolicy.pmda:
                guard let version = file.uint32(at: body + 2), let count = file.uint32(at: body + 6) else {
                    return note(.truncated(.bootPolicy), at: offset)
                }
                let entrySize: UInt64
                switch version {
                case 1: entrySize = 0x28
                case 2: entrySize = 0x2C
                default: return note(.unknownType(.bootPolicy, UInt8(truncatingIfNeeded: version)), at: body + 2)
                }
                let entries = body + 0x0A
                guard let span = file.range(at: entries, count: UInt64(count) * entrySize) else {
                    return note(.truncated(.bootPolicy), at: offset)
                }
                for index in 0..<UInt64(count) {
                    let entry = entries + index * entrySize
                    // Version 1 stores a bare SHA-256, version 2 a `HASH_V1`.
                    let stored: ProtectedRange.Digest? = version == 1
                        ? file.bytes(at: entry + 8, count: 32).map {
                            ProtectedRange.Digest(algorithm: TCGHash.sha256, bytes: $0)
                        }
                        : hashV1(at: entry + 8)
                    guard let base = file.uint32(at: entry), let size = file.uint32(at: entry + 4),
                          let digest = stored
                    else { return note(.truncated(.bootPolicy), at: entry) }
                    addSingle(.pmda, physical(base, size), digest: digest, source: entry..<(entry + entrySize))
                }
                offset = span.upperBound
            default:
                // `__PMSG__` is always last; anything else cannot be stepped over.
                return
            }
        }
    }

    /// §4.3. Elements carry their size, so unknown ones are stepped over.
    private func bootPolicyV2(at manifest: UInt64) {
        var offset = manifest + BootPolicy.v2HeaderSize
        for _ in 0..<BootPolicy.maxElements {
            guard let id = file.uint64(at: offset), let total = file.uint16(at: offset + 0x0A) else {
                return note(.truncated(.bootPolicy), at: offset)
            }
            if total == 0 || id == BootPolicy.pmsg { return }
            guard UInt64(total) >= BootPolicy.v2ElementHeaderSize,
                  let element = file.range(at: offset, count: UInt64(total))
            else { return note(.truncated(.bootPolicy), at: offset) }
            let body = offset + BootPolicy.v2ElementHeaderSize
            switch id {
            case BootPolicy.ibbs:
                guard ibbsV2(body: body, element: element) else { return note(.truncated(.bootPolicy), at: offset) }
            case BootPolicy.pmda:
                guard pmdaV2(body: body, element: element) else { return note(.truncated(.bootPolicy), at: offset) }
            default:
                break
            }
            offset = element.upperBound
        }
    }

    private func ibbsV2(body: UInt64, element: Range<UInt64>) -> Bool {
        let limit = element.upperBound
        var cursor = body + 0x30
        guard let postIbb = hashV2(&cursor, limit: limit),
              fits(cursor, 8, limit),
              let count = file.uint16(at: cursor + 6)
        else { return false }
        cursor += 8    // IbbEntryPoint, IbbDigestsSize, NumIbbDigests
        var digests: [ProtectedRange.Digest] = []
        for _ in 0..<count {
            guard let digest = hashV2(&cursor, limit: limit) else { return false }
            digests.append(digest)
        }
        guard let obb = hashV2(&cursor, limit: limit),
              fits(cursor, 4, limit),
              let segmentCount = file.uint8(at: cursor + 3),
              let segments = segments(at: cursor + 4, count: Int(segmentCount), limit: limit)
        else { return false }
        addIBB(segments, digests: digests, source: element)
        addPostIBB(postIbb, source: element)
        if !Self.isUniform(obb.bytes) { obbDigests.append(obb) }
        return true
    }

    private func pmdaV2(body: UInt64, element: Range<UInt64>) -> Bool {
        let limit = element.upperBound
        guard fits(body, 0x0C, limit),
              let version = file.uint32(at: body + 4),
              let count = file.uint32(at: body + 8)
        else { return false }
        guard version == 3 else {
            note(.unknownType(.bootPolicy, UInt8(truncatingIfNeeded: version)), at: body + 4)
            return true
        }
        var entry = body + 0x0C
        for _ in 0..<count {
            guard fits(entry, 0x14, limit),
                  let base = file.uint32(at: entry + 4),
                  let size = file.uint32(at: entry + 8),
                  let entrySize = file.uint16(at: entry + 0x0C),
                  UInt64(entrySize) >= 0x14
            else { return false }
            var cursor = entry + 0x10
            guard let digest = hashV2(&cursor, limit: limit) else { return false }
            addSingle(.pmda, physical(base, size), digest: digest, source: entry..<(entry + UInt64(entrySize)))
            entry += UInt64(entrySize)
        }
        return true
    }

    private func hashV1(at offset: UInt64) -> ProtectedRange.Digest? {
        guard let algorithm = file.uint16(at: offset),
              let size = file.uint16(at: offset + 2),
              let bytes = file.bytes(at: offset + 4, count: 32)
        else { return nil }
        return .init(algorithm: algorithm, bytes: Array(bytes.prefix(Int(size))))
    }

    private func hashV2(_ cursor: inout UInt64, limit: UInt64) -> ProtectedRange.Digest? {
        guard fits(cursor, 4, limit),
              let algorithm = file.uint16(at: cursor),
              let size = file.uint16(at: cursor + 2),
              fits(cursor + 4, UInt64(size), limit),
              let bytes = file.bytes(at: cursor + 4, count: UInt64(size))
        else { return nil }
        cursor += 4 + UInt64(size)
        return .init(algorithm: algorithm, bytes: bytes)
    }

    private func segments(
        at offset: UInt64, count: Int, limit: UInt64
    ) -> [(flags: UInt16, base: UInt32, size: UInt32)]? {
        guard fits(offset, UInt64(count) * BootPolicy.segmentSize, limit) else { return nil }
        return (0..<UInt64(count)).compactMap { index in
            let segment = offset + index * BootPolicy.segmentSize
            guard let flags = file.uint16(at: segment + 2),
                  let base = file.uint32(at: segment + 4),
                  let size = file.uint32(at: segment + 8)
            else { return nil }
            return (flags, base, size)
        }
    }

    private func fits(_ offset: UInt64, _ count: UInt64, _ limit: UInt64) -> Bool {
        guard let range = file.range(at: offset, count: count) else { return false }
        return range.upperBound <= limit
    }

    /// Segments with `Flags == 0` make up the IBB; the rest are non-IBB and
    /// name nothing (§4.5).
    private func addIBB(
        _ segments: [(flags: UInt16, base: UInt32, size: UInt32)],
        digests: [ProtectedRange.Digest],
        source: Range<UInt64>
    ) {
        var group = Group(kind: .ibb, digests: digests, source: source)
        for segment in segments where segment.flags == 0 {
            add(physical(segment.base, segment.size), to: &group)
        }
        if !group.members.isEmpty || group.incomplete { groups.append(group) }
    }

    /// Only when the digest is not uniform: all `0x00` or all `0xFF` is a
    /// manifest that names no post-IBB range (§4.5).
    private func addPostIBB(_ digest: ProtectedRange.Digest, source: Range<UInt64>) {
        guard !Self.isUniform(digest.bytes) else { return }
        var group = Group(kind: .postIbb, digests: [digest], source: source)
        if let volume = dxeRootVolume {
            group.members = [volume]
        } else {
            note(.protectedRangeNotPlaced(ProtectedRange.Kind.postIbb.name), at: source.lowerBound)
            group.members = [nil]
        }
        groups.append(group)
    }

    private func addSingle(
        _ kind: ProtectedRange.Kind, _ placement: Placement,
        digest: ProtectedRange.Digest, source: Range<UInt64>
    ) {
        var group = Group(kind: kind, digests: [digest], source: source)
        add(placement, to: &group)
        if !group.members.isEmpty || group.incomplete { groups.append(group) }
    }

    private func add(_ placement: Placement, to group: inout Group) {
        switch placement {
        case .placed(let range):
            group.members.append(range)
        case .unused:
            break
        case .outside:
            // Not in this image: reported and dropped, never used unconverted
            // the way UEFITool does (§3).
            note(.protectedRangeOutsideImage(group.kind.name), at: group.source.lowerBound)
            group.incomplete = true
        case .unmapped:
            note(.protectedRangeNotPlaced(group.kind.name), at: group.source.lowerBound)
            group.members.append(nil)
        }
    }

    private func physical(_ base: UInt32, _ size: UInt32) -> Placement {
        guard Self.isUsed(base, size) else { return .unused }
        guard let addressDiff = image.addressDiff else { return .unmapped }
        guard UInt64(base) >= addressDiff else { return .outside }
        return inImage(UInt64(base) - addressDiff, size)
    }

    private func inImage(_ offset: UInt64, _ size: UInt32) -> Placement {
        file.range(at: offset, count: UInt64(size)).map(Placement.placed) ?? .outside
    }

    private static func isUsed(_ base: UInt32, _ size: UInt32) -> Bool {
        base != .max && size != 0 && size != .max
    }

    private static func isUniform(_ bytes: [UInt8]) -> Bool {
        bytes.allSatisfy { $0 == 0x00 } || bytes.allSatisfy { $0 == 0xFF }
    }

    // MARK: - Where a range with no address starts (§3)

    /// The outermost volume holding the first DXE Core, in the file — through
    /// any compressed section the core itself sits in.
    private lazy var dxeRootVolume: Range<UInt64>? = {
        guard let core = nodes.first(where: {
            $0.kind == .file && ($0.guid == KnownGUIDs.dxeCore || $0.guid == KnownGUIDs.amiDxeCore)
        }) else { return nil }
        var path = core.id.path
        var outermost: UEFINode?
        while !path.isEmpty {
            path.removeLast()
            if let ancestor = image.node(NodeID(path)), ancestor.kind == .volume, ancestor.space == .file {
                outermost = ancestor
            }
        }
        return outermost?.fileRange
    }()

    /// What Phoenix entries are relative to: the first element of the BIOS
    /// region, or the image's start when there is no descriptor (§3).
    private lazy var protectedRegionsBase: UInt64 = {
        guard let bios = nodes.first(where: { $0.kind == .region && $0.subtype == UEFITypes.Sub.biosRegion }) else {
            return 0
        }
        return bios.children.first(where: { $0.kind != .padding })?.range.lowerBound ?? bios.body.lowerBound
    }()

    // MARK: - Vendor hash files (§5)

    func readVendorHashFiles() {
        for node in nodes where node.kind == .file && node.space == .file {
            if node.guid == KnownGUIDs.phoenixHashFile {
                phoenix(node)
            } else if node.guid == KnownGUIDs.amiHashFile {
                ami(node)
            }
        }
    }

    /// §5.1: the file's body is the table.
    private func phoenix(_ node: UEFINode) {
        let body = node.body
        guard file.uint64(at: body.lowerBound) == BootPolicy.phoenixSignature else { return }
        guard let count = file.uint32(at: body.lowerBound + 8),
              UInt64(count) * BootPolicy.vendorEntrySize + 0x0C <= body.upperBound - body.lowerBound
        else { return note(.truncated(.vendorHashFile), at: body.lowerBound) }
        for index in 0..<UInt64(count) {
            let entry = body.lowerBound + 0x0C + index * BootPolicy.vendorEntrySize
            guard let hash = file.bytes(at: entry, count: 32),
                  let base = file.uint32(at: entry + 32),
                  let size = file.uint32(at: entry + 36)
            else { return note(.truncated(.vendorHashFile), at: entry) }
            let placement = Self.isUsed(base, size) ? inImage(protectedRegionsBase + UInt64(base), size) : .unused
            addSingle(.phoenix, placement, digest: .init(algorithm: TCGHash.sha256, bytes: hash),
                      source: entry..<(entry + BootPolicy.vendorEntrySize))
        }
    }

    /// §5.2: the body of a raw section, versioned by its size alone.
    private func ami(_ node: UEFINode) {
        guard let raw = node.flattened.dropFirst().first(where: {
            $0.kind == .section && $0.subtype == Section.raw && $0.space == .file
        }) else { return }
        let body = raw.body
        let start = body.lowerBound
        let size = body.upperBound - body.lowerBound
        guard let hash = file.bytes(at: start, count: min(size, 32)) else {
            return note(.truncated(.vendorHashFile), at: start)
        }
        let sha256 = ProtectedRange.Digest(algorithm: TCGHash.sha256, bytes: hash)
        switch size {
        case 0x24:
            guard let length = file.uint32(at: start + 32), Self.isUsed(0, length) else { return }
            var group = Group(kind: .amiV1, digests: [sha256], source: body)
            if let volume = dxeRootVolume {
                add(inImage(volume.lowerBound, length), to: &group)
            } else {
                note(.protectedRangeNotPlaced(ProtectedRange.Kind.amiV1.name), at: start)
                group.members = [nil]
            }
            if !group.members.isEmpty || group.incomplete { groups.append(group) }
        case 0x50:
            for index in 0..<UInt64(2) {
                let entry = start + index * BootPolicy.vendorEntrySize
                guard let hash = file.bytes(at: entry, count: 32),
                      let base = file.uint32(at: entry + 32),
                      let length = file.uint32(at: entry + 36)
                else { return }
                addSingle(.amiV2, physical(base, length),
                          digest: .init(algorithm: TCGHash.sha256, bytes: hash),
                          source: entry..<(entry + BootPolicy.vendorEntrySize))
            }
        case 0x70:
            var group = Group(kind: .amiV3, digests: [sha256], source: body, hashedInFileOrder: true)
            // Three FvMain segments, then the nested volume.
            let fields: [(base: UInt64, size: UInt64)] = [(32, 44), (36, 48), (40, 52), (56, 60)]
            for field in fields {
                guard let base = file.uint32(at: start + field.base),
                      let length = file.uint32(at: start + field.size)
                else { return }
                add(physical(base, length), to: &group)
            }
            if !group.members.isEmpty || group.incomplete { groups.append(group) }
        default:
            note(.unknownVendorHashFileSize(size), at: start)
        }
    }

    // MARK: - The Insyde flash device map (§5.3)

    func readFlashDeviceMaps() {
        for store in nodes where store.kind == .flashDeviceMapStore && store.space == .file {
            guard let base = file.uint64(at: store.header.lowerBound + FlashDeviceMap.baseAddressOffset) else {
                continue
            }
            for entry in store.children where entry.kind == .flashDeviceMapEntry {
                let at = entry.header.lowerBound
                guard let offset = file.uint64(at: at + FlashDeviceMap.regionOffsetOffset),
                      let size = file.uint64(at: at + FlashDeviceMap.regionSizeOffset),
                      let attributes = file.uint32(at: at + FlashDeviceMap.attributesOffset),
                      let hash = file.bytes(at: at + FlashDeviceMap.hashOffset, count: 32)
                else { continue }
                // UEFITool looks at MODIFIABLE alone: an entry marked IGNORED
                // and not MODIFIABLE is still a range. Followed until a real
                // image says otherwise (§5.3).
                guard attributes & FlashDeviceMap.modifiable == 0 else { continue }
                let address = UInt32(truncatingIfNeeded: base) &+ UInt32(truncatingIfNeeded: offset)
                addSingle(.insyde, physical(address, UInt32(truncatingIfNeeded: size)),
                          digest: .init(algorithm: TCGHash.sha256, bytes: hash), source: entry.header)
            }
        }
    }

    // MARK: - Hashing (§6)

    func finish() -> ProtectedRanges {
        var ranges: [ProtectedRange] = []
        for group in groups {
            let verdict = self.verdict(of: group)
            for member in group.members {
                ranges.append(ProtectedRange(
                    kind: group.kind, range: member, digests: group.digests,
                    source: group.source, verdict: verdict
                ))
            }
        }
        return ProtectedRanges(ranges: ranges, obbDigests: obbDigests, diagnostics: diagnostics)
    }

    private func verdict(of group: Group) -> ProtectedRange.Verdict {
        let placed = group.members.compactMap { $0 }
        let digests = group.digests.filter { !$0.bytes.isEmpty && $0.algorithm != TCGHash.null }
        guard !group.incomplete, !placed.isEmpty, placed.count == group.members.count, !digests.isEmpty else {
            return .unchecked
        }
        let hashed = group.hashedInFileOrder ? placed.sorted { $0.lowerBound < $1.lowerBound } : placed
        var computedAny = false
        var mismatch = false
        var unsupported: UInt16?
        for digest in digests {
            guard let computed = TCGHash.digest(of: hashed, in: file, algorithm: digest.algorithm) else {
                unsupported = unsupported ?? digest.algorithm
                continue
            }
            computedAny = true
            if computed != digest.bytes { mismatch = true }
        }
        if let unsupported, !computedAny {
            note(.unsupportedHashAlgorithm(unsupported), at: group.source.lowerBound)
            return .unsupported(algorithm: unsupported)
        }
        if mismatch {
            note(.protectedRangeHashMismatch(group.kind.name), at: placed[0].lowerBound)
            return .mismatch
        }
        return .matches
    }
}
