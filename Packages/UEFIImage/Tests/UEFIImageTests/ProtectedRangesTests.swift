import CryptoKit
import FirmwareCompressionTestSupport
import XCTest
@testable import UEFIImage

/// The lists of `BOOT_GUARD_PROTECTED_RANGES.md` §4 and §5, byte for byte.
enum TestBootGuard {
    struct Segment {
        var base: UInt32
        var size: UInt32
        var flags: UInt16 = 0
    }

    typealias Entry = (base: UInt32, size: UInt32, hash: [UInt8])

    /// `__TXTS__`: an element the reading does not know.
    static let txts: UInt64 = 0x5F5F_5354_5854_5F5F
    static let zero32 = [UInt8](repeating: 0, count: 32)

    static func sha256(_ bytes: [UInt8]) -> [UInt8] { Array(SHA256.hash(data: bytes)) }
    static func sha384(_ bytes: [UInt8]) -> [UInt8] { Array(SHA384.hash(data: bytes)) }

    static func hashV1(_ digest: [UInt8], algorithm: UInt16 = TCGHash.sha256) -> [UInt8] {
        var writer = BinaryWriter()
        writer.u16(algorithm)
        writer.u16(32)
        writer.raw(Array((digest + zero32).prefix(32)))
        return writer.bytes
    }

    static func hashV2(_ digest: [UInt8], algorithm: UInt16 = TCGHash.sha256) -> [UInt8] {
        var writer = BinaryWriter()
        writer.u16(algorithm)
        writer.u16(UInt16(digest.count))
        writer.raw(digest)
        return writer.bytes
    }

    static func segments(_ list: [Segment]) -> [UInt8] {
        var writer = BinaryWriter()
        for segment in list {
            writer.u16(0)                           // Reserved
            writer.u16(segment.flags)
            writer.u32(segment.base)
            writer.u32(segment.size)
        }
        return writer.bytes
    }

    static func bootPolicyV1(
        segments list: [Segment],
        ibbHash: [UInt8],
        postIbbHash: [UInt8] = zero32,
        pmda: [Entry] = [],
        unknownElementFirst: Bool = false
    ) -> [UInt8] {
        var writer = BinaryWriter()
        writer.u64(BootPolicy.structureID)
        writer.u8(0x10)                             // Version
        writer.fill(5, with: 0)                     // Reserved0 … Reserved1
        writer.u16(0)                               // NemDataSize
        if unknownElementFirst {
            writer.u64(txts)
            writer.u8(1)
            writer.fill(0x20, with: 0)
        }
        writer.u64(BootPolicy.ibbs)
        writer.u8(1)
        writer.fill(3, with: 0)                     // Reserved
        writer.u32(0)                               // Flags
        writer.fill(0x28, with: 0)                  // MchBar … DmaProtectionLimit1
        writer.raw(hashV1(postIbbHash))
        writer.u32(0xFFFF_FFF0)                     // IbbEntryPoint
        writer.raw(hashV1(ibbHash))
        writer.u8(UInt8(list.count))
        writer.raw(segments(list))
        if !pmda.isEmpty {
            writer.u64(BootPolicy.pmda)
            writer.u8(1)
            writer.u16(UInt16(0x0A + pmda.count * 0x28))
            writer.u32(1)                           // Version
            writer.u32(UInt32(pmda.count))
            for entry in pmda {
                writer.u32(entry.base)
                writer.u32(entry.size)
                writer.raw(entry.hash)
            }
        }
        writer.u64(BootPolicy.pmsg)
        writer.u8(1)
        writer.fill(0x40, with: 0x5A)
        return writer.bytes
    }

    static func element(_ id: UInt64, _ body: [UInt8]) -> [UInt8] {
        var writer = BinaryWriter()
        writer.u64(id)
        writer.u8(0x20)                             // Version
        writer.u8(0)                                // HeaderSpecific
        writer.u16(UInt16(12 + body.count))
        writer.raw(body)
        return writer.bytes
    }

    static func bootPolicyV2(
        segments list: [Segment],
        ibbDigests: [(algorithm: UInt16, bytes: [UInt8])],
        postIbb: [UInt8] = zero32,
        obb: [UInt8] = zero32,
        pmda: [Entry] = []
    ) -> [UInt8] {
        var writer = BinaryWriter()
        writer.u64(BootPolicy.structureID)
        writer.u8(0x21)                             // Version
        writer.u8(0)                                // HeaderSpecific
        writer.u16(0x14)                            // TotalSize
        writer.u16(0)                               // KeySignatureOffset
        writer.fill(4, with: 0)                     // BpmRevision, BpSvn, AcmSvn, Reserved
        writer.u16(0)                               // NemDataSize
        writer.raw(element(txts, [UInt8](repeating: 0x77, count: 0x20)))

        var ibbs = BinaryWriter()
        ibbs.fill(4, with: 0)                       // Reserved0, SetNumber, Reserved1, PbetValue
        ibbs.u32(0)                                 // Flags
        ibbs.fill(0x28, with: 0)                    // MchBar … DmaProtectionLimit1
        ibbs.raw(hashV2(postIbb))
        ibbs.u32(0xFFFF_FFF0)                       // IbbEntryPoint
        let digests = ibbDigests.flatMap { hashV2($0.bytes, algorithm: $0.algorithm) }
        ibbs.u16(UInt16(digests.count))
        ibbs.u16(UInt16(ibbDigests.count))
        ibbs.raw(digests)
        ibbs.raw(hashV2(obb))
        ibbs.fill(3, with: 0)
        ibbs.u8(UInt8(list.count))
        ibbs.raw(segments(list))
        writer.raw(element(BootPolicy.ibbs, ibbs.bytes))

        if !pmda.isEmpty {
            var entries = BinaryWriter()
            for entry in pmda {
                let hash = hashV2(entry.hash)
                entries.u32(0x4144_4D50)            // EntryId
                entries.u32(entry.base)
                entries.u32(entry.size)
                entries.u16(UInt16(0x10 + hash.count))
                entries.u16(1)
                entries.raw(hash)
            }
            var body = BinaryWriter()
            body.u16(0)
            body.u16(UInt16(0x0C + entries.bytes.count))
            body.u32(3)
            body.u32(UInt32(pmda.count))
            body.raw(entries.bytes)
            writer.raw(element(BootPolicy.pmda, body.bytes))
        }
        writer.raw(element(BootPolicy.pmsg, [UInt8](repeating: 0x5A, count: 0x40)))
        return writer.bytes
    }

    /// A header, a microcode row the reading passes over, and the Boot Policy.
    static func fitTable(bootPolicyAt address: UInt32) -> [UInt8] {
        var writer = BinaryWriter()
        func row(_ address: UInt64, size: UInt32, type: UInt8) {
            writer.u64(address)
            writer.u24(size)
            writer.u8(0)
            writer.u16(0x0100)
            writer.u8(type)
            writer.u8(0)
        }
        row(BootPolicy.fitSignature, size: 3, type: 0)
        row(0xFFFF_0000, size: 0, type: 0x01)
        row(UInt64(address), size: 0, type: BootPolicy.fitType)
        return writer.bytes
    }

    static func vendorEntry(hash: [UInt8], base: UInt32, size: UInt32) -> [UInt8] {
        var writer = BinaryWriter()
        writer.raw(hash)
        writer.u32(base)
        writer.u32(size)
        return writer.bytes
    }

    static func amiFile(body: [UInt8]) -> [UInt8] {
        TestImage.sectionedFile(
            guid: KnownGUIDs.amiHashFile, type: 0x02,
            sections: [TestImage.section(type: Section.raw, body: body)]
        )
    }

    typealias MapEntry = (offset: UInt64, size: UInt64, attributes: UInt32, hash: [UInt8])

    /// An Insyde flash device map, its header checksum right.
    static func flashDeviceMap(
        base: UInt64,
        entries: [MapEntry],
        entrySize: UInt32 = 0x54,
        format: UInt8 = 0,
        revision: UInt8 = 3
    ) -> [UInt8] {
        var body = BinaryWriter()
        for (index, entry) in entries.enumerated() {
            body.guid(KnownGUIDs.guid(String(format: "FD000000-0000-4000-8000-%012X", UInt32(index + 1))))
            let regionID = Array("REGION\(index)".utf8)
            body.raw(regionID + [UInt8](repeating: 0, count: 16 - regionID.count))
            body.u64(entry.offset)
            body.u64(entry.size)
            body.u32(entry.attributes)
            body.raw(entry.hash)
        }
        var header = BinaryWriter()
        header.u32(FlashDeviceMap.signature)
        header.u32(UInt32(FlashDeviceMap.headerSize) + UInt32(body.bytes.count))
        header.u32(UInt32(FlashDeviceMap.headerSize))   // DataOffset
        header.u32(entrySize)
        header.u8(format)
        header.u8(revision)
        header.u8(0)                                     // ExtensionCount
        header.u8(0)                                     // Checksum, filled in below
        header.u64(base)
        var bytes = header.bytes
        bytes[FlashDeviceMap.checksumOffset] = 0 &- Checksums.sum8(bytes)
        return bytes + body.bytes
    }

    static func phoenixFile(entries: [Entry]) -> [UInt8] {
        var writer = BinaryWriter()
        writer.u64(BootPolicy.phoenixSignature)
        writer.u32(UInt32(entries.count))
        for entry in entries {
            writer.raw(vendorEntry(hash: entry.hash, base: entry.base, size: entry.size))
        }
        return TestImage.file(guid: KnownGUIDs.phoenixHashFile, body: writer.bytes)
    }
}

/// A 64 KiB image mapped flush against the top of the address space: a DXE
/// volume first, then a volume holding the FIT, the Boot Policy, data for the
/// IBB to cover and the Volume Top File. The files are laid out before their
/// contents are written, so what points at what is known up front.
struct BootGuardImage {
    static let size: UInt64 = 0x10000
    static let addressDiff: UInt64 = 0x1_0000_0000 - size
    static let dxeVolume: Range<UInt64> = 0..<0x4000
    static let fitGUID = KnownGUIDs.guid("F17A0000-0000-4000-8000-000000000001")
    static let policyGUID = KnownGUIDs.guid("F17A0000-0000-4000-8000-000000000002")
    static let ibbGUID = KnownGUIDs.guid("F17A0000-0000-4000-8000-000000000003")

    var bytes: [UInt8]
    let fit: Range<UInt64>
    let policy: Range<UInt64>
    let ibb: Range<UInt64>
    /// The body of the AMI hash file's raw section, when one was asked for.
    let amiTable: Range<UInt64>?

    init(dxeCoreCompressed: Bool = false, extraFiles: [[UInt8]] = []) {
        let core = TestImage.file(guid: KnownGUIDs.dxeCore, body: [UInt8](repeating: 0x33, count: 0x40))
        let dxeFiles: [[UInt8]]
        if dxeCoreCompressed {
            let inner = TestImage.section(
                type: Section.firmwareVolumeImage, body: TestImage.volume(length: 0x400, files: [core])
            )
            let lzma = TestImage.compressionSection(
                algorithm: 0x02, body: LZMATestEncoder.lzma(inner), uncompressedLength: UInt32(inner.count)
            )
            dxeFiles = [TestImage.sectionedFile(type: 0x0B, sections: [lzma])]
        } else {
            dxeFiles = [core]
        }
        let data = (0..<0x800).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ 3) }
        let main = TestImage.volume(
            length: 0xC000,
            files: [
                TestImage.file(guid: Self.fitGUID, body: [UInt8](repeating: 0xFF, count: 0x100)),
                TestImage.file(guid: Self.policyGUID, body: [UInt8](repeating: 0xFF, count: 0x400)),
                TestImage.file(guid: Self.ibbGUID, body: data)
            ] + extraFiles,
            lastFile: TestImage.volumeTopFile(size: 0x100)
        )
        bytes = TestImage.volume(length: 0x4000, files: dxeFiles) + main

        let nodes = UEFIParser.parse(bytes, readsProtectedRanges: false).allNodes
        func body(_ guid: EFIGUID) -> Range<UInt64> {
            nodes.first { $0.kind == .file && $0.guid == guid }!.body
        }
        fit = body(Self.fitGUID)
        policy = body(Self.policyGUID)
        ibb = body(Self.ibbGUID)
        amiTable = nodes.first { $0.guid == KnownGUIDs.amiHashFile }?
            .flattened.first { $0.kind == .section && $0.subtype == Section.raw }?.body
    }

    func address(_ offset: UInt64) -> UInt32 {
        UInt32(offset + Self.addressDiff)
    }

    mutating func write(_ data: [UInt8], at offset: UInt64) {
        bytes.replaceSubrange(Int(offset)..<(Int(offset) + data.count), with: data)
    }

    /// The manifest into its file, a FIT pointing at it, and the pointer at
    /// `0xFFFFFFC0` — inside the Volume Top File, where it is in a real image.
    mutating func install(policy manifest: [UInt8]) {
        precondition(manifest.count <= 0x400)
        write(manifest, at: policy.lowerBound)
        write(TestBootGuard.fitTable(bootPolicyAt: address(policy.lowerBound)), at: fit.lowerBound)
        var pointer = BinaryWriter()
        pointer.u32(address(fit.lowerBound))
        write(pointer.bytes, at: Self.size - 0x40)
    }

    func slice(_ range: Range<UInt64>) -> [UInt8] {
        Array(bytes[Int(range.lowerBound)..<Int(range.upperBound)])
    }

    func sha256(_ ranges: Range<UInt64>...) -> [UInt8] {
        TestBootGuard.sha256(ranges.flatMap(slice))
    }

    var ranges: ProtectedRanges {
        UEFIParser.parse(bytes).protectedRanges!
    }
}

private extension UEFIDiagnostic {
    var structureIsFlashDeviceMap: Bool {
        switch kind {
        case .truncated(.flashDeviceMap), .checksumMismatch(.flashDeviceMap, _, _),
             .unknownRevision(.flashDeviceMap, _), .unknownFlashDeviceMapEntries:
            return true
        default:
            return false
        }
    }
}

final class ProtectedRangesTests: XCTestCase {
    private typealias Build = TestBootGuard

    // MARK: - The Boot Policy (§4)

    func testAV1ManifestNamesItsIBBThePostIBBRangeAndPMDA() {
        var image = BootGuardImage()
        let first = image.ibb.lowerBound..<(image.ibb.lowerBound + 0x300)
        let second = first.upperBound..<(first.upperBound + 0x200)
        let pmda = image.ibb.lowerBound..<(image.ibb.lowerBound + 0x100)
        image.install(policy: Build.bootPolicyV1(
            segments: [
                .init(base: image.address(first.lowerBound), size: 0x300),
                // Non-IBB: names nothing.
                .init(base: image.address(second.upperBound), size: 0x100, flags: 1),
                .init(base: image.address(second.lowerBound), size: 0x200)
            ],
            ibbHash: image.sha256(first, second),
            postIbbHash: image.sha256(BootGuardImage.dxeVolume),
            pmda: [(image.address(pmda.lowerBound), 0x100, image.sha256(pmda))]
        ))

        let ranges = image.ranges
        XCTAssertEqual(ranges.ranges.map(\.kind), [.ibb, .ibb, .postIbb, .pmda])
        XCTAssertEqual(ranges.ranges.map(\.range), [first, second, BootGuardImage.dxeVolume, pmda])
        XCTAssertEqual(ranges.ranges.map(\.verdict), [.matches, .matches, .matches, .matches])
        XCTAssertEqual(ranges.diagnostics, [])
    }

    func testAV2ManifestStepsOverAnElementItDoesNotKnowAndChecksEveryDigest() {
        var image = BootGuardImage()
        let segment = image.ibb.lowerBound..<(image.ibb.lowerBound + 0x400)
        let pmda = (image.ibb.lowerBound + 0x400)..<(image.ibb.lowerBound + 0x480)
        let obb = [UInt8](repeating: 0x11, count: 32)
        image.install(policy: Build.bootPolicyV2(
            segments: [.init(base: image.address(segment.lowerBound), size: 0x400)],
            ibbDigests: [
                (TCGHash.sha256, image.sha256(segment)),
                (TCGHash.sha384, Build.sha384(image.slice(segment)))
            ],
            postIbb: image.sha256(BootGuardImage.dxeVolume),
            obb: obb,
            pmda: [(image.address(pmda.lowerBound), 0x80, image.sha256(pmda))]
        ))

        let ranges = image.ranges
        XCTAssertEqual(ranges.ranges.map(\.kind), [.ibb, .postIbb, .pmda])
        XCTAssertEqual(ranges.ranges.map(\.range), [segment, BootGuardImage.dxeVolume, pmda])
        XCTAssertEqual(ranges.ranges.map(\.verdict), [.matches, .matches, .matches])
        XCTAssertEqual(ranges.ranges.first?.digests.map(\.algorithm), [TCGHash.sha256, TCGHash.sha384])
        XCTAssertEqual(ranges.obbDigests, [.init(algorithm: TCGHash.sha256, bytes: obb)], "noted, not placed")
        XCTAssertEqual(ranges.diagnostics, [])
    }

    /// A v1 element has no size (§4.2): past one the reading does not know,
    /// nothing more can be read.
    func testAV1ManifestStopsAtAnElementItCannotStepOver() {
        var image = BootGuardImage()
        image.install(policy: Build.bootPolicyV1(
            segments: [.init(base: image.address(image.ibb.lowerBound), size: 0x100)],
            ibbHash: Build.zero32,
            unknownElementFirst: true
        ))

        XCTAssertEqual(image.ranges.ranges, [])
    }

    /// The reference prints the IBB digests and compares them with nothing; a
    /// port compares, and says what it found as a warning (§6.1).
    func testAnIBBThatDoesNotHashToItsDigestIsAWarning() throws {
        var image = BootGuardImage()
        let segment = image.ibb.lowerBound..<(image.ibb.lowerBound + 0x100)
        image.install(policy: Build.bootPolicyV1(
            segments: [.init(base: image.address(segment.lowerBound), size: 0x100)],
            ibbHash: [UInt8](repeating: 0xAB, count: 32)
        ))

        let ranges = image.ranges
        XCTAssertEqual(ranges.ranges.map(\.verdict), [.mismatch])
        let diagnostic = try XCTUnwrap(ranges.diagnostics.first)
        XCTAssertEqual(diagnostic.kind, .protectedRangeHashMismatch(ProtectedRange.Kind.ibb.name))
        XCTAssertEqual(diagnostic.offset, segment.lowerBound)
        XCTAssertEqual(diagnostic.severity, .warning)
        XCTAssertTrue(UEFIParser.parse(image.bytes).diagnostics.contains(diagnostic), "the image carries it")
    }

    func testAnSM3DigestIsNotComputedAndTheRangeIsStillPlaced() {
        var image = BootGuardImage()
        let segment = image.ibb.lowerBound..<(image.ibb.lowerBound + 0x100)
        image.install(policy: Build.bootPolicyV2(
            segments: [.init(base: image.address(segment.lowerBound), size: 0x100)],
            ibbDigests: [(TCGHash.sm3, [UInt8](repeating: 1, count: 32))]
        ))

        let ranges = image.ranges
        XCTAssertEqual(ranges.ranges.map(\.range), [segment])
        XCTAssertEqual(ranges.ranges.map(\.verdict), [.unsupported(algorithm: TCGHash.sm3)])
        XCTAssertTrue(ranges.diagnostics.contains { $0.kind == .unsupportedHashAlgorithm(TCGHash.sm3) })
    }

    /// A segment below the image's mapping, or running past its end, is not in
    /// this image: reported and dropped, and the digest over all of them is
    /// not checked against what is left (§3).
    func testASegmentOutsideTheImageIsDroppedAndReported() {
        var image = BootGuardImage()
        let inside = image.ibb.lowerBound..<(image.ibb.lowerBound + 0x100)
        image.install(policy: Build.bootPolicyV1(
            segments: [
                .init(base: image.address(inside.lowerBound), size: 0x100),
                .init(base: 0x1000, size: 0x100),
                .init(base: image.address(BootGuardImage.size - 0x10), size: 0x100)
            ],
            ibbHash: image.sha256(inside)
        ))

        let ranges = image.ranges
        XCTAssertEqual(ranges.ranges.map(\.range), [inside])
        XCTAssertEqual(ranges.ranges.map(\.verdict), [.unchecked])
        let outside = ranges.diagnostics.filter {
            $0.kind == .protectedRangeOutsideImage(ProtectedRange.Kind.ibb.name)
        }
        XCTAssertEqual(outside.count, 2)
    }

    /// The DXE Core inside an LZMA section still names the volume outside the
    /// section — and a node inside takes the marking of what holds it (§3, §7.3).
    func testThePostIBBRangeIsTheOutermostVolumeThroughACompressedSection() throws {
        var image = BootGuardImage(dxeCoreCompressed: true)
        image.install(policy: Build.bootPolicyV1(
            segments: [], ibbHash: Build.zero32, postIbbHash: image.sha256(BootGuardImage.dxeVolume)
        ))

        let parsed = UEFIParser.parse(image.bytes)
        let ranges = try XCTUnwrap(parsed.protectedRanges)
        XCTAssertEqual(ranges.ranges.map(\.kind), [.postIbb])
        XCTAssertEqual(ranges.ranges.map(\.range), [BootGuardImage.dxeVolume])
        XCTAssertEqual(ranges.ranges.map(\.verdict), [.matches])

        let core = try XCTUnwrap(parsed.allNodes.first { $0.guid == KnownGUIDs.dxeCore })
        XCTAssertNotEqual(core.space, .file)
        XCTAssertEqual(ranges.protection(of: core, in: parsed), .protected)
    }

    func testAnImageThatNamesNothingHasNoRanges() throws {
        let image = TestImage.volume(length: 0x4000, lastFile: TestImage.volumeTopFile(size: 0x100))
        let parsed = UEFIParser.parse(image)

        XCTAssertEqual(try XCTUnwrap(parsed.protectedRanges).isEmpty, true)
        XCTAssertEqual(parsed.diagnostics, [])
    }

    // MARK: - Vendor hash files (§5)

    /// With no descriptor, Phoenix entries are relative to the image's start.
    func testAPhoenixTableNamesItsRangesRelativeToTheImage() throws {
        let covered: Range<UInt64> = 0x800..<0x900
        let blank = TestImage.volume(length: 0x1000, files: [Build.phoenixFile(entries: [(0x800, 0x100, Build.zero32)])])
        let hash = Build.sha256(Array(blank[0x800..<0x900]))
        let image = TestImage.volume(length: 0x1000, files: [Build.phoenixFile(entries: [(0x800, 0x100, hash)])])

        let ranges = try XCTUnwrap(UEFIParser.parse(image).protectedRanges)
        XCTAssertEqual(ranges.ranges.map(\.kind), [.phoenix])
        XCTAssertEqual(ranges.ranges.map(\.range), [covered])
        XCTAssertEqual(ranges.ranges.map(\.verdict), [.matches])
    }

    func testAnAMIv1TableStartsAtTheDXERootVolume() throws {
        var image = BootGuardImage(extraFiles: [Build.amiFile(body: [UInt8](repeating: 0, count: 0x24))])
        let covered: Range<UInt64> = 0..<0x2000
        var table = BinaryWriter()
        table.raw(image.sha256(covered))
        table.u32(0x2000)
        image.write(table.bytes, at: try XCTUnwrap(image.amiTable).lowerBound)

        let ranges = image.ranges
        XCTAssertEqual(ranges.ranges.map(\.kind), [.amiV1])
        XCTAssertEqual(ranges.ranges.map(\.range), [covered])
        XCTAssertEqual(ranges.ranges.map(\.verdict), [.matches])
    }

    func testAnAMIv2TableHasTwoRangesEachWithItsOwnHash() throws {
        var image = BootGuardImage(extraFiles: [Build.amiFile(body: [UInt8](repeating: 0, count: 0x50))])
        let first = image.ibb.lowerBound..<(image.ibb.lowerBound + 0x100)
        let second = (image.ibb.lowerBound + 0x200)..<(image.ibb.lowerBound + 0x280)
        image.write(
            Build.vendorEntry(hash: image.sha256(first), base: image.address(first.lowerBound), size: 0x100)
                + Build.vendorEntry(hash: [UInt8](repeating: 9, count: 32),
                                    base: image.address(second.lowerBound), size: 0x80),
            at: try XCTUnwrap(image.amiTable).lowerBound
        )

        let ranges = image.ranges
        XCTAssertEqual(ranges.ranges.map(\.kind), [.amiV2, .amiV2])
        XCTAssertEqual(ranges.ranges.map(\.range), [first, second])
        XCTAssertEqual(ranges.ranges.map(\.verdict), [.matches, .mismatch])
    }

    /// Up to four ranges and one hash over them, taken in file order whatever
    /// the table's order (§6.2).
    func testAnAMIv3TableHashesItsRangesTogetherInFileOrder() throws {
        var image = BootGuardImage(extraFiles: [Build.amiFile(body: [UInt8](repeating: 0, count: 0x70))])
        let early = image.ibb.lowerBound..<(image.ibb.lowerBound + 0x100)
        let late = (image.ibb.lowerBound + 0x400)..<(image.ibb.lowerBound + 0x500)
        var table = BinaryWriter()
        table.raw(image.sha256(early, late))
        table.u32(image.address(late.lowerBound))   // FvMainSegmentBase
        table.u32(image.address(early.lowerBound))
        table.u32(0xFFFF_FFFF)
        table.u32(0x100)                             // FvMainSegmentSize
        table.u32(0x100)
        table.u32(0)
        table.u32(0xFFFF_FFFF)                       // NestedFvBase
        table.u32(0)
        table.fill(48, with: 0)
        image.write(table.bytes, at: try XCTUnwrap(image.amiTable).lowerBound)

        let ranges = image.ranges
        XCTAssertEqual(ranges.ranges.map(\.kind), [.amiV3, .amiV3])
        XCTAssertEqual(ranges.ranges.map(\.range), [late, early])
        XCTAssertEqual(ranges.ranges.map(\.verdict), [.matches, .matches])
    }

    func testAnAMITableOfAnotherSizeIsReported() throws {
        let image = TestImage.volume(length: 0x1000, files: [Build.amiFile(body: [UInt8](repeating: 0, count: 0x30))])

        let ranges = try XCTUnwrap(UEFIParser.parse(image).protectedRanges)
        XCTAssertEqual(ranges.ranges, [])
        XCTAssertTrue(ranges.diagnostics.contains { $0.kind == .unknownVendorHashFileSize(0x30) })
    }

    /// With no Volume Top File there is no address to convert: the range is
    /// named, and not placed (§3).
    func testWithoutAVolumeTopFileAPhysicalRangeIsNotPlaced() throws {
        let table = Build.vendorEntry(hash: Build.zero32, base: 0xFFFF_1000, size: 0x100)
            + Build.vendorEntry(hash: Build.zero32, base: 0xFFFF_FFFF, size: 0)
        let image = TestImage.volume(length: 0x1000, files: [Build.amiFile(body: table)])

        let ranges = try XCTUnwrap(UEFIParser.parse(image).protectedRanges)
        XCTAssertEqual(ranges.ranges.map(\.kind), [.amiV2], "the erased slot is not a range")
        XCTAssertEqual(ranges.ranges.map(\.range), [nil])
        XCTAssertEqual(ranges.ranges.map(\.verdict), [.unchecked])
        XCTAssertTrue(ranges.diagnostics.contains {
            $0.kind == .protectedRangeNotPlaced(ProtectedRange.Kind.amiV2.name)
        })
    }

    // MARK: - The Insyde flash device map (§5.3)

    /// The store at the start of a 64 KiB image with no descriptor, then a
    /// volume ending in the Volume Top File.
    private func mapImage(_ store: [UInt8]) -> [UInt8] {
        store + [UInt8](repeating: 0xFF, count: 0x1000 - store.count)
            + TestImage.volume(length: 0xF000, lastFile: TestImage.volumeTopFile(size: 0x100))
    }

    func testAFlashDeviceMapIsAFixedNodeWithItsEntries() throws {
        let store = Build.flashDeviceMap(base: 0xFFFF_0000, entries: [
            (0x3000, 0x100, 0, Build.zero32), (0x4000, 0x100, 1, Build.zero32)
        ])
        let parsed = UEFIParser.parse(mapImage(store))

        let node = try XCTUnwrap(parsed.allNodes.first { $0.kind == .flashDeviceMapStore })
        XCTAssertEqual(node.range, 0..<UInt64(store.count))
        XCTAssertTrue(node.isFixed)
        XCTAssertEqual(node.children.map(\.kind), [.flashDeviceMapEntry, .flashDeviceMapEntry])
        XCTAssertEqual(node.uefiItemType, UEFITypes.Item.insydeFlashDeviceMapStore.rawValue)
        XCTAssertFalse(parsed.diagnostics.contains { $0.structureIsFlashDeviceMap }, "\(parsed.diagnostics)")
    }

    /// An entry names a range unless it is modifiable — and one marked ignored
    /// but not modifiable still does, as in UEFITool.
    func testEveryEntryThatIsNotModifiableIsARange() throws {
        let erased = Build.sha256([UInt8](repeating: 0xFF, count: 0x100))
        let store = Build.flashDeviceMap(base: 0xFFFF_0000, entries: [
            (0x3000, 0x100, 0, erased),
            (0x4000, 0x100, 1, erased),
            (0x5000, 0x100, 2, [UInt8](repeating: 7, count: 32))
        ])

        let ranges = try XCTUnwrap(UEFIParser.parse(mapImage(store)).protectedRanges)
        XCTAssertEqual(ranges.ranges.map(\.kind), [.insyde, .insyde])
        XCTAssertEqual(ranges.ranges.map(\.range), [0x3000..<0x3100, 0x5000..<0x5100])
        XCTAssertEqual(ranges.ranges.map(\.verdict), [.matches, .mismatch])
    }

    func testAFlashDeviceMapOfAnUnknownEntryFormatIsALeafAndReported() throws {
        let store = Build.flashDeviceMap(base: 0xFFFF_0000, entries: [(0x3000, 0x100, 0, Build.zero32)], format: 1)
        let parsed = UEFIParser.parse(mapImage(store))

        let node = try XCTUnwrap(parsed.allNodes.first { $0.kind == .flashDeviceMapStore })
        XCTAssertEqual(node.children, [])
        XCTAssertTrue(parsed.diagnostics.contains { $0.kind == .unknownFlashDeviceMapEntries(size: 0x54, format: 1) })
        XCTAssertEqual(parsed.protectedRanges?.ranges, [])
    }

    func testAFlashDeviceMapOfALaterRevisionIsSkippedAndReported() {
        let store = Build.flashDeviceMap(base: 0xFFFF_0000, entries: [(0x3000, 0x100, 0, Build.zero32)], revision: 5)
        let parsed = UEFIParser.parse(mapImage(store))

        XCTAssertFalse(parsed.allNodes.contains { $0.kind == .flashDeviceMapStore })
        XCTAssertTrue(parsed.diagnostics.contains { $0.kind == .unknownRevision(.flashDeviceMap, 5) })
    }

    // MARK: - Marking (§7.3)

    private func list(_ entries: [(ProtectedRange.Kind, Range<UInt64>)]) -> ProtectedRanges {
        ProtectedRanges(ranges: entries.map { ProtectedRange(kind: $0.0, range: $0.1, source: 0..<0) })
    }

    /// Two adjacent IBB segments are one IBB: a node spanning both lies inside
    /// it, which UEFITool marks as partial (§7.2).
    func testANodeAcrossTwoAdjacentSegmentsIsInsideTheIBB() {
        let ranges = list([(.ibb, 0x100..<0x200), (.ibb, 0x200..<0x300), (.amiV2, 0x300..<0x400)])

        XCTAssertEqual(ranges.protection(of: 0x180..<0x280), .ibb)
        XCTAssertEqual(ranges.protection(of: 0x100..<0x400), .protected)
        XCTAssertEqual(ranges.protection(of: 0x380..<0x480), .partial)
        XCTAssertNil(ranges.protection(of: 0x400..<0x500))
    }

    /// The last range does not win: the answer depends on the set alone.
    func testTheOrderOfTheListChangesNothing() {
        let entries: [(ProtectedRange.Kind, Range<UInt64>)] = [
            (.amiV2, 0x0..<0x1000), (.ibb, 0x100..<0x200), (.pmda, 0x180..<0x300)
        ]
        let forward = list(entries)
        let backward = list(Array(entries.reversed()))

        let probes: [Range<UInt64>] = [0x100..<0x200, 0x150..<0x250, 0x0..<0x1000, 0xF00..<0x1100]
        for probe in probes {
            XCTAssertEqual(forward.protection(of: probe), backward.protection(of: probe), "\(probe)")
        }
        XCTAssertEqual(forward.protection(of: 0x100..<0x200), .ibb, "a later range around it does not repaint it")
    }

    func testThePlannerIsHandedTheIBBToRefuseAndTheRestToWarnAbout() {
        let ranges = list([(.ibb, 0x100..<0x200), (.phoenix, 0x300..<0x400)])

        XCTAssertEqual(ranges.rebuildRanges.map(\.kind), [.ibb, .vendorHash])
        XCTAssertEqual(ranges.rebuildRanges.map(\.range), [0x100..<0x200, 0x300..<0x400])
    }
}
