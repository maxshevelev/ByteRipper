import HelpBook
import UEFIImage
import XCTest
@testable import UEFITool

/// The AMD PSP's map in the panel: its rows read as padding and open the PSP's
/// entry, the details lead from the EFS to the directories and from a
/// directory to its blobs, and a directory's checksum is checked and fixed
/// like any other.
final class AMDFirmwareDisplayTests: XCTestCase {
    private static let mapped: UInt64 = 0xFF80_0000

    private static func put32(_ value: UInt32, at offset: Int, in bytes: inout [UInt8]) {
        for index in 0..<4 { bytes[offset + index] = UInt8(truncatingIfNeeded: value >> (8 * index)) }
    }

    private static func entry(_ type: UInt8, size: UInt32, location: UInt64, bios: Bool) -> [UInt8] {
        var entry = [UInt8](repeating: 0, count: bios ? 24 : 16)
        entry[0] = type
        put32(size, at: 4, in: &entry)
        put32(UInt32(truncatingIfNeeded: location), at: 8, in: &entry)
        put32(UInt32(truncatingIfNeeded: location >> 32), at: 12, in: &entry)
        if bios { for index in 16..<24 { entry[index] = 0xFF } }
        return entry
    }

    private static func directory(_ signature: String, at offset: Int, entries: [[UInt8]], in bytes: inout [UInt8]) {
        bytes.replaceSubrange(offset..<(offset + 4), with: Array(signature.utf8))
        put32(UInt32(entries.count), at: offset + 8, in: &bytes)
        put32(0, at: offset + 12, in: &bytes)
        let body = entries.flatMap { $0 }
        bytes.replaceSubrange((offset + 16)..<(offset + 16 + body.count), with: body)
        put32(AMDFirmware.fletcher32(Array(bytes[(offset + 8)..<(offset + 16 + body.count)])), at: offset + 4, in: &bytes)
    }

    /// An 8 MiB flash: the EFS at `0x20000` → `$PSP` at `0x31000` with the
    /// boot loader at `0x32000`, and `$BHD` at `0x40000` with the APCB at
    /// `0x41000`.
    private static let bytes: [UInt8] = {
        var bytes = [UInt8](repeating: 0xFF, count: 0x80_0000)
        put32(AMDFirmware.efsSignature, at: 0x2_0000, in: &bytes)
        for field in stride(from: 4, to: 0x50, by: 4) { put32(0, at: 0x2_0000 + field, in: &bytes) }
        put32(UInt32(mapped) + 0x3_1000, at: 0x2_0014, in: &bytes)
        put32(UInt32(mapped) + 0x4_0000, at: 0x2_0028, in: &bytes)
        directory("$PSP", at: 0x3_1000, entries: [entry(0x01, size: 0x100, location: mapped + 0x3_2000, bios: false)],
                  in: &bytes)
        directory("$BHD", at: 0x4_0000, entries: [entry(0x60, size: 0x100, location: mapped + 0x4_1000, bios: true)],
                  in: &bytes)
        for start in [0x3_2000, 0x4_1000] {
            bytes.replaceSubrange(start..<(start + 0x100), with: [UInt8](repeating: 0x11, count: 0x100))
        }
        return bytes
    }()

    private func row(_ image: UEFIImage, _ kind: UEFINodeKind, at offset: UInt64) throws -> UEFINode {
        try XCTUnwrap(image.allNodes.first { $0.kind == kind && $0.range.lowerBound == offset })
    }

    func testTheRowsReadAsPaddingAndOpenThePSPsEntry() throws {
        let image = UEFIParser.parse(Self.bytes)
        let efs = try row(image, .amdEFS, at: 0x2_0000)
        let directory = try row(image, .amdDirectory, at: 0x3_1000)
        let blob = try row(image, .amdFirmwareEntry, at: 0x3_2000)

        XCTAssertEqual([efs, directory, blob].map(UEFITreeDisplay.typeText), ["Padding", "Padding", "Padding"])
        XCTAssertEqual(UEFITreeDisplay.name(for: directory, catalogue: .empty), "PSP directory $PSP")
        XCTAssertEqual(UEFITreeDisplay.name(for: blob, catalogue: .empty), "PSP_FW_BOOT_LOADER")
        for node in [efs, directory, blob] {
            XCTAssertEqual(UEFIHelpTerms.term(for: node), HelpTermID("amd-psp"))
        }
    }

    func testTheEFSLeadsToItsDirectoriesAndADirectoryToItsBlobs() throws {
        let image = UEFIParser.parse(Self.bytes)
        let reader = ImageReader(Self.bytes)
        let efs = UEFIDetail.build(for: try row(image, .amdEFS, at: 0x2_0000), image: image, reader: reader)
        let pointers = try XCTUnwrap(efs.tables.first { $0.title == "Directories" })
        XCTAssertEqual(pointers.rows.map { $0[0].text }, ["+0x14", "+0x28"])
        XCTAssertEqual(pointers.rows.map { $0[2].text }, ["PSP directory $PSP", "BIOS directory $BHD"])
        XCTAssertEqual(pointers.rowTargets, [.node(try row(image, .amdDirectory, at: 0x3_1000).id),
                                             .node(try row(image, .amdDirectory, at: 0x4_0000).id)])

        let bhd = UEFIDetail.build(for: try row(image, .amdDirectory, at: 0x4_0000), image: image, reader: reader)
        let fields = Dictionary(bhd.fields.map { ($0.label, $0.value) }, uniquingKeysWith: { first, _ in first })
        XCTAssertEqual(fields["Kind"], "AMD firmware directory")
        XCTAssertEqual(fields["Type"], "BIOS directory")
        XCTAssertEqual(fields["Address mode"], "Memory-mapped address")
        XCTAssertEqual(fields["Checksum"]?.hasSuffix("(Valid)"), true)
        let entries = try XCTUnwrap(bhd.tables.first { $0.title == "Entries" })
        XCTAssertEqual(entries.rows.first?.map(\.text), ["0", "APCB (0x60)", "0x100 (256)", "0x41000", ""])
        XCTAssertEqual(entries.rowTargets, [.node(try row(image, .amdFirmwareEntry, at: 0x4_1000).id)])

        let blob = UEFIDetail.build(for: try row(image, .amdFirmwareEntry, at: 0x4_1000), image: image, reader: reader)
        XCTAssertTrue(blob.fields.contains { $0.label == "Entry type" && $0.value == "APCB (0x60)" })
        let listed = try XCTUnwrap(blob.tables.first { $0.title == "Listed in" })
        XCTAssertEqual(listed.rows.map { $0[0].text }, ["BIOS directory $BHD"])
    }

    /// A directory whose checksum is wrong is flagged, says what it should
    /// be, and the repair writes it.
    func testAWrongChecksumIsFlaggedAndRepaired() throws {
        var bytes = Self.bytes
        let stored = Array(bytes[0x3_1004..<0x3_1008])
        bytes[0x3_1004] ^= 0xFF
        let image = UEFIParser.parse(bytes)
        let reader = ImageReader(bytes)
        let directory = try row(image, .amdDirectory, at: 0x3_1000)

        let repairs = UEFIChecksumCheck.repairs(in: image, reader: reader)
        XCTAssertEqual(repairs[directory.id], [ChecksumRepair(offset: 0x3_1004, bytes: stored)])
        XCTAssertEqual(UEFIChecksumCheck.fields(of: repairs, in: image)[directory.id], [.pspDirectory])
        XCTAssertEqual(UEFITreeMarks.checksumText([.pspDirectory]), "Invalid PSP directory checksum")
        XCTAssertNil(repairs[try row(image, .amdDirectory, at: 0x4_0000).id], "the other one is right")

        let detail = UEFIDetail.build(for: directory, image: image, reader: reader, repairs: repairs[directory.id] ?? [])
        let checksum = try XCTUnwrap(detail.fields.first { $0.label == "Checksum" })
        XCTAssertTrue(checksum.isProblem)
        XCTAssertTrue(checksum.value.contains("should be"), checksum.value)
    }
}
