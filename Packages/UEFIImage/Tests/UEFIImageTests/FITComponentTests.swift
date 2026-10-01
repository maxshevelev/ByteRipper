import XCTest
@testable import UEFIImage

/// The structures the FIT names, read out of the padding a vendor keeps them
/// in (`UEFI_IMAGE_FORMAT.md` §9): the table, the Startup ACM, the Boot Guard
/// manifests — each where the FIT says, as long as its own header says.
final class FITComponentTests: XCTestCase {
    private static let size: UInt64 = 0x1_0000

    // MARK: - The structures

    /// `KEY_AND_SIGNATURE` with an RSA-2048 key and signature.
    private static var keySignature: [UInt8] {
        var w = BinaryWriter()
        w.u8(0x10)                        // Version
        w.u16(0x0001)                     // KeyAlg
        w.u8(0x10)                        // Key: version
        w.u16(2048)                       //      size in bits
        w.u32(0x1_0001)                   //      exponent
        w.fill(256, with: 0xA5)           //      modulus
        w.u16(0x0014)                     // SigScheme
        w.u8(0x10)                        // Signature: version
        w.u16(2048)                       //            size in bits
        w.u16(TCGHash.sha256)             //            hash algorithm
        w.fill(256, with: 0x5A)           //            signature
        return w.bytes
    }

    private static var keyManifestV2: [UInt8] {
        var w = BinaryWriter()
        w.u64(FITComponent.keyManifestID)
        w.u8(0x21)                        // StructVersion
        w.u8(0)                           // HeaderSpecific
        w.u16(0)                          // TotalSize
        w.u16(0x44)                       // KeySignatureOffset
        w.fill(3, with: 0)                // Reserved
        w.u8(1)                           // KmVersion
        w.u8(2)                           // KmSvn
        w.u8(3)                           // KmId
        w.u16(TCGHash.sha256)             // FpfHashAlgId
        w.u16(1)                          // KeyCount
        w.u64(1)                          //   Usage
        w.u16(TCGHash.sha256)             //   HashAlg
        w.u16(32)                         //   Size
        w.fill(32, with: 0x11)            //   Hash
        return w.bytes + keySignature
    }

    private static var keyManifestV1: [UInt8] {
        var w = BinaryWriter()
        w.u64(FITComponent.keyManifestID)
        w.u8(0x10)                        // Version
        w.u8(0x10)                        // KmVersion
        w.u8(0)                           // KmSvn
        w.u8(1)                           // KmId
        w.u16(TCGHash.sha256)
        w.u16(32)
        w.fill(32, with: 0x22)
        return w.bytes + keySignature
    }

    private static var bootPolicyV2: [UInt8] {
        var w = BinaryWriter()
        w.u64(BootPolicy.structureID)
        w.u8(0x21)                        // StructVersion
        w.u8(0x20)                        // HdrStructVersion
        w.u16(0x14)                       // HdrSize
        w.u16(0x14 + 0x10 + 0x0C)         // KeySignatureOffset
        w.u8(1)                           // BpmRevision
        w.u8(4)                           // BpSvn
        w.u8(5)                           // AcmSvn
        w.u8(0)
        w.u16(3)                          // NemDataSize
        w.u64(0x5F5F_5354_5854_5F5F)      // __TXTS__, stepped over by its size
        w.u8(0x21); w.u8(0); w.u16(0x10)
        w.fill(4, with: 0)
        w.u64(BootPolicy.pmsg)
        w.u8(0x21); w.u8(0); w.u16(0)
        return w.bytes + keySignature
    }

    private static var bootPolicyV1: [UInt8] {
        var w = BinaryWriter()
        w.u64(BootPolicy.structureID)
        w.u8(0x10)                        // Version
        w.u8(0x01)
        w.u8(0x10)                        // BpmRevision
        w.u8(0)                           // BpSvn
        w.u8(2)                           // AcmSvn
        w.u8(0)
        w.u16(0x80)                       // NemDataSize
        w.u64(BootPolicy.ibbs)            // __IBBS__, one segment
        w.u8(0x10)
        w.fill(0x7B, with: 0)
        w.u8(1)
        w.fill(4, with: 0); w.u32(0xFFFF_F000); w.u32(0x1000)
        w.u64(BootPolicy.pmda)            // __PMDA__, one version-1 entry
        w.u8(0x10)
        w.u16(0x32); w.u32(1); w.u32(1)
        w.fill(0x28, with: 0)
        w.u64(BootPolicy.pmsg)
        w.u8(0x10)
        return w.bytes + keySignature
    }

    private static var startupACM: [UInt8] {
        var w = BinaryWriter()
        w.u16(FITComponent.acmModuleType)
        w.u16(1)                          // ModuleSubType: Startup
        w.u32(0xE0)                       // HeaderLen
        w.u32(0x3_0000)                   // HeaderVersion
        w.u16(0xB00C)                     // ChipsetID
        w.u16(0)
        w.u32(FITComponent.intelVendor)
        w.raw([0x27, 0x04, 0x23, 0x20])   // Date, BCD
        w.u32(0x400)                      // Size, in dwords
        w.u16(3)                          // AcmSvn
        w.fill(0x1000 - 0x1E, with: 0x3C)
        return w.bytes
    }

    // MARK: - The image

    private typealias Placed = (type: UInt8, offset: UInt64, bytes: [UInt8])

    /// A 64 KiB block for an image `imageSize` bytes long whose last block it
    /// is: the FIT at `0x1000` and what it names in the padding after it, and
    /// a volume ending in the Volume Top File, with the FIT pointer, in its
    /// last 4 KiB.
    private static func block(
        imageSize: UInt64 = size,
        placed: [Placed] = [
            (0x0B, 0x2000, keyManifestV2), (0x0C, 0x3000, bootPolicyV2), (0x02, 0x4000, startupACM),
        ]
    ) -> [UInt8] {
        let addressDiff = 0x1_0000_0000 - imageSize
        let blockStart = imageSize - size
        var bytes = [UInt8](repeating: 0xFF, count: Int(size))
        var table = BinaryWriter()
        table.u64(TopSwapCopy.fitSignature)
        table.u24(UInt32(placed.count + 1))
        table.u8(0); table.u16(0x0100); table.u8(0); table.u8(0)
        for item in placed {
            bytes.replaceSubrange(Int(item.offset)..<(Int(item.offset) + item.bytes.count), with: item.bytes)
            table.u64(blockStart + item.offset + addressDiff)
            table.u24(0); table.u8(0); table.u16(0x0100); table.u8(item.type); table.u8(0)
        }
        bytes.replaceSubrange(0x1000..<(0x1000 + table.bytes.count), with: table.bytes)
        let volume = TestImage.volume(length: 0x1000, lastFile: TestImage.volumeTopFile())
        bytes.replaceSubrange(0xF000..<0x10000, with: volume)
        var pointer = BinaryWriter()
        pointer.u32(UInt32(blockStart + 0x1000 + addressDiff))
        bytes.replaceSubrange(Int(size - 0x40)..<Int(size - 0x3C), with: pointer.bytes)
        return bytes
    }

    private func components(_ nodes: [UEFINode]) -> [UEFINode] {
        nodes.filter { $0.kind == .fitComponent }
    }

    // MARK: - Tests

    func testWhatTheFITNamesIsCutOutOfThePadding() {
        let parsed = UEFIParser.parse(Self.block(), readsProtectedRanges: false)
        let nodes = parsed.roots[0].children
        let found = components(nodes)

        XCTAssertEqual(found.map(\.name), ["FIT", "Boot Guard Key Manifest", "Boot Guard Boot Policy", "Startup ACM"])
        XCTAssertEqual(found.map(\.subtype), [0x00, 0x0B, 0x0C, 0x02])
        XCTAssertEqual(found.map(\.range), [
            0x1000..<0x1040,
            0x2000..<(0x2000 + UInt64(Self.keyManifestV2.count)),
            0x3000..<(0x3000 + UInt64(Self.bootPolicyV2.count)),
            0x4000..<0x5000,
        ])
        XCTAssertTrue(found.allSatisfy(\.isFixed))
        XCTAssertEqual(found[0].uefiItemType, UEFITypes.Item.padding.rawValue)

        let first = nodes.firstIndex { $0.kind == .fitComponent }!
        XCTAssertEqual(nodes[first - 1].range, 0..<0x1000)
        XCTAssertEqual(nodes[first + 1].range, 0x1040..<0x2000)
        XCTAssertEqual(nodes[first + 1].kind, .padding)
        XCTAssertTrue(parsed.diagnostics.isEmpty, "\(parsed.diagnostics)")
    }

    func testAManifestIsAsLongAsItsHeaderSays() {
        let bytes = Self.keyManifestV1 + Self.bootPolicyV1 + Self.keyManifestV2 + Self.bootPolicyV2
        let reader = ImageReader(bytes)
        var at: UInt64 = 0
        for (kind, manifest) in [
            (FITComponent.Kind.keyManifest, Self.keyManifestV1), (.bootPolicy, Self.bootPolicyV1),
            (.keyManifest, Self.keyManifestV2), (.bootPolicy, Self.bootPolicyV2),
        ] {
            XCTAssertEqual(FITComponent.length(of: kind, at: at, in: reader), UInt64(manifest.count))
            at += UInt64(manifest.count)
        }
    }

    /// The FIT is a pointer, not a promise: what it names has to be there.
    func testAnAddressHoldingSomethingElseStaysPadding() {
        var acm = Self.startupACM
        acm[0x10] = 0                       // not Intel's
        let parsed = UEFIParser.parse(
            Self.block(placed: [(0x0B, 0x2000, Self.keyManifestV2), (0x02, 0x4000, acm)]),
            readsProtectedRanges: false
        )
        XCTAssertEqual(components(parsed.roots[0].children).map(\.name), ["FIT", "Boot Guard Key Manifest"])
    }

    /// With bytes after the Volume Top File the parser cannot map the FIT's
    /// addresses before its second pass, and leaves the padding alone.
    func testAnImageThatDoesNotEndWithItsVolumeTopFileKeepsItsPadding() {
        let bytes = Self.block() + [UInt8](repeating: 0xFF, count: 0x110)
        XCTAssertTrue(components(UEFIParser.parse(bytes, readsProtectedRanges: false).allNodes).isEmpty)
    }

    func testTheTopSwapCopyHasItsOwnRows() {
        let bytes = Self.block(imageSize: 2 * Self.size) + Self.block(imageSize: 2 * Self.size)
        let found = components(UEFIParser.parse(bytes, readsProtectedRanges: false).allNodes)
        XCTAssertEqual(found.map(\.range.lowerBound), [
            0x1000, 0x2000, 0x3000, 0x4000, 0x1_1000, 0x1_2000, 0x1_3000, 0x1_4000,
        ])
    }

    /// A pad file whose body is a manifest keeps the row UEFITool shows, and
    /// its warning; the manifest is a row inside it.
    func testAManifestInAPadFileIsARowOfItsNonUEFIData() {
        let pad = TestImage.file(
            guid: EFIGUID(bytes: [UInt8](repeating: 0xFF, count: 16)),
            type: FFS.padType,
            body: Self.keyManifestV2 + [UInt8](repeating: 0xFF, count: 0x100)
        )
        var bytes = Self.block(placed: [])
        let volume = TestImage.volume(length: 0x1000, files: [pad], lastFile: TestImage.volumeTopFile())
        bytes.replaceSubrange(0xF000..<0x10000, with: volume)
        let body = UEFIParser.parse(bytes, readsProtectedRanges: false).allNodes
            .first { $0.kind == .file && $0.subtype == FFS.padType }!.body.lowerBound
        // The FIT, one row pointing at the pad file's body.
        var table = BinaryWriter()
        table.u64(TopSwapCopy.fitSignature)
        table.u24(2); table.u8(0); table.u16(0x0100); table.u8(0); table.u8(0)
        table.u64(body + 0xFFFF_0000); table.u24(0); table.u8(0); table.u16(0x0100); table.u8(0x0B); table.u8(0)
        bytes.replaceSubrange(0x1000..<0x1020, with: table.bytes)
        var pointer = BinaryWriter()
        pointer.u32(0xFFFF_1000)
        bytes.replaceSubrange(0xFFC0..<0xFFC4, with: pointer.bytes)

        let parsed = UEFIParser.parse(bytes, readsProtectedRanges: false)
        let data = parsed.allNodes.first { $0.kind == .padding && $0.name == "Non-UEFI data" }!
        XCTAssertEqual(data.children.map(\.kind), [.fitComponent, .padding])
        XCTAssertEqual(data.children[0].range, body..<(body + UInt64(Self.keyManifestV2.count)))
        XCTAssertEqual(data.children.last?.range.upperBound, data.range.upperBound)
        XCTAssertTrue(parsed.diagnostics.contains { $0.kind == .nonUEFIDataInPadFile })
    }

    func testTheHeadersSayWhatUEFIToolShows() {
        let reader = ImageReader(Self.startupACM + Self.keyManifestV2 + Self.bootPolicyV1)
        XCTAssertEqual(
            FITComponentHeader.read(.startupACM, at: 0, in: reader),
            .acm(subtype: 1, headerVersion: 0x3_0000, chipsetID: 0xB00C, date: "2023-04-27", svn: 3)
        )
        XCTAssertEqual(
            FITComponentHeader.read(.keyManifest, at: 0x1000, in: reader),
            .keyManifest(version: 0x21, kmVersion: 1, svn: 2, id: 3)
        )
        XCTAssertEqual(
            FITComponentHeader.read(.bootPolicy, at: 0x1000 + UInt64(Self.keyManifestV2.count), in: reader),
            .bootPolicy(version: 0x10, revision: 0x10, svn: 0, acmSVN: 2)
        )
        XCTAssertEqual(FITComponentHeader.acmSubtypeName(1), "Startup")
    }
}
