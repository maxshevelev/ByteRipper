import Foundation
import XCTest
@testable import UEFIImage

/// The AMD PSP's map (`AMDFirmware`): the EFS found, the directories walked
/// from it — combo, first and second level, a slot header — their entries'
/// locations read in each address mode, and every structure laid into the
/// padding as a row, a compressed BIOS image opening to what it inflates to.
final class AMDFirmwareTests: XCTestCase {
    private static let size = 0x80_0000
    /// Where an 8 MiB flash is mapped: its top at 4 GiB.
    private static let mapped: UInt32 = 0xFF80_0000

    private struct Fixture {
        var bytes: [UInt8]
        var stream: Int
        var volume: [UInt8]
    }

    private func put32(_ value: UInt32, at offset: Int, in bytes: inout [UInt8]) {
        for index in 0..<4 { bytes[offset + index] = UInt8(truncatingIfNeeded: value >> (8 * index)) }
    }

    private func put64(_ value: UInt64, at offset: Int, in bytes: inout [UInt8]) {
        for index in 0..<8 { bytes[offset + index] = UInt8(truncatingIfNeeded: value >> (8 * index)) }
    }

    /// A directory at `offset`: its signature, entries, and the checksum the
    /// PSP checks.
    private func directory(_ signature: String, at offset: Int, info: UInt32 = 0, header: Int = 0x10,
                           entries: [[UInt8]], in bytes: inout [UInt8]) {
        bytes.replaceSubrange(offset..<(offset + 4), with: Array(signature.utf8))
        put32(UInt32(entries.count), at: offset + 8, in: &bytes)
        put32(info, at: offset + 12, in: &bytes)
        if header > 0x10 { bytes.replaceSubrange((offset + 0x10)..<(offset + header), with: [UInt8](repeating: 0, count: header - 0x10)) }
        var at = offset + header
        for entry in entries {
            bytes.replaceSubrange(at..<(at + entry.count), with: entry)
            at += entry.count
        }
        put32(AMDFirmware.fletcher32(Array(bytes[(offset + 8)..<at])), at: offset + 4, in: &bytes)
    }

    private func pspEntry(_ type: UInt8, flags: UInt16 = 0, size: UInt32, location: UInt64) -> [UInt8] {
        var entry = [UInt8](repeating: 0, count: 16)
        entry[0] = type
        entry[2] = UInt8(flags & 0xFF)
        entry[3] = UInt8(flags >> 8)
        put32(size, at: 4, in: &entry)
        put64(location, at: 8, in: &entry)
        return entry
    }

    private func biosEntry(_ type: UInt8, flags: UInt16 = 0, size: UInt32, location: UInt64,
                           destination: UInt64 = 0xFFFF_FFFF_FFFF_FFFF) -> [UInt8] {
        var entry = pspEntry(type, flags: flags, size: size, location: location) + [UInt8](repeating: 0, count: 8)
        put64(destination, at: 16, in: &entry)
        return entry
    }

    /// A zlib stream: the two-byte header, raw deflate, Adler-32.
    private func zlib(_ bytes: [UInt8]) throws -> [UInt8] {
        let deflated = [UInt8](try (Data(bytes) as NSData).compressed(using: .zlib) as Data)
        var a: UInt32 = 1, b: UInt32 = 0
        for byte in bytes {
            a = (a + UInt32(byte)) % 65521
            b = (b + a) % 65521
        }
        let adler = b << 16 | a
        return [0x78, 0x9C] + deflated + [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: adler >> $0) }
    }

    /// An 8 MiB AMD flash:
    ///
    /// - EFS at `0x20000`; `+0x14` names the combo directory by flash offset,
    ///   `+0x28` the BIOS directory by its mapped address.
    /// - `2PSP` at `0x30000`, one entry for PSP id `0xBC0C0140` → `$PSP` at
    ///   `0x31000`: a boot loader with room for `0x100`, a soft fuse value, a
    ///   gasket blob around the EFS (`0x1F000`–`0x21000`), and `$PL2`.
    /// - `$PL2` at `0x33000`, entries relative to it: the trusted OS at
    ///   `+0x400`, and the boot loader again, `0x80` long.
    /// - `$BHD` at `0x40000`: APCB, APOB (no location), a compressed BIOS
    ///   image at `0x50000`, and `$BL2` at `0x42000` with a microcode patch.
    private func fixture() throws -> Fixture {
        var bytes = [UInt8](repeating: 0xFF, count: Self.size)
        let efs = 0x2_0000
        put32(AMDFirmware.efsSignature, at: efs, in: &bytes)
        for field in stride(from: 4, to: 0x50, by: 4) { put32(0, at: efs + field, in: &bytes) }
        put32(0x3_0000, at: efs + 0x14, in: &bytes)
        put32(Self.mapped + 0x4_0000, at: efs + 0x28, in: &bytes)

        var combo = [UInt8](repeating: 0, count: 16)
        put32(0xBC0C_0140, at: 4, in: &combo)
        put64(0x3_1000, at: 8, in: &combo)
        directory("2PSP", at: 0x3_0000, header: 0x20, entries: [combo], in: &bytes)

        directory("$PSP", at: 0x3_1000, entries: [
            pspEntry(0x01, size: 0x100, location: UInt64(Self.mapped) + 0x3_2000),
            pspEntry(0x0B, size: 0xFFFF_FFFF, location: 0x1000_8041),
            pspEntry(0x24, size: 0x2000, location: UInt64(Self.mapped) + 0x1_F000),
            pspEntry(0x40, size: 0x400, location: UInt64(Self.mapped) + 0x3_3000),
        ], in: &bytes)
        // Mode 2 (bits 29–30): the entries say for themselves; these are
        // relative to the directory, but for the boot loader's mapped address.
        directory("$PL2", at: 0x3_3000, info: 0x4000_0000, entries: [
            pspEntry(0x02, size: 0x200, location: 0x8000_0000_0000_0400),
            pspEntry(0x01, size: 0x80, location: UInt64(Self.mapped) + 0x3_2000),
        ], in: &bytes)

        let volume = TestImage.volume(length: 0x1000, files: [TestImage.file(body: [UInt8](repeating: 0x5A, count: 0x40))])
        let stream = try zlib(volume)
        var header = [UInt8](repeating: 0, count: 0x100)
        put32(UInt32(stream.count), at: 0x14, in: &header)
        bytes.replaceSubrange(0x5_0000..<(0x5_0000 + 0x100 + stream.count), with: header + stream)

        directory("$BHD", at: 0x4_0000, entries: [
            biosEntry(0x60, size: 0x100, location: UInt64(Self.mapped) + 0x4_1000),
            biosEntry(0x61, size: 0, location: 0, destination: 0x9F0_0000),
            biosEntry(0x62, flags: 0x0B, size: UInt32(volume.count), location: UInt64(Self.mapped) + 0x5_0000,
                      destination: 0x9A0_0000),
            biosEntry(0x70, size: 0x400, location: UInt64(Self.mapped) + 0x4_2000),
        ], in: &bytes)
        directory("$BL2", at: 0x4_2000, entries: [
            biosEntry(0x66, flags: 0x10, size: 0x40, location: UInt64(Self.mapped) + 0x4_3000),
        ], in: &bytes)
        // Written, so none of the blobs is erased space.
        for start in [0x1_F000, 0x3_2000, 0x3_3400, 0x4_1000, 0x4_3000] {
            bytes.replaceSubrange(start..<(start + 0x40), with: [UInt8](repeating: 0x11, count: 0x40))
        }
        return Fixture(bytes: bytes, stream: stream.count, volume: volume)
    }

    // MARK: - The walk

    func testTheWalkFollowsTheEFSThroughEveryLevel() throws {
        let fixture = try fixture()
        let firmware = try XCTUnwrap(AMDFirmware.read(ImageReader(fixture.bytes)))

        XCTAssertEqual(firmware.efsOffset, 0x2_0000)
        XCTAssertEqual(firmware.romSize, 0x80_0000)
        XCTAssertEqual(firmware.pointers.map(\.field), [0x14, 0x28])
        XCTAssertEqual(firmware.directories.map(\.kind), [.pspCombo, .psp, .pspLevel2, .bios, .biosLevel2])
        XCTAssertEqual(firmware.directories.map(\.offset), [0x3_0000, 0x3_1000, 0x3_3000, 0x4_0000, 0x4_2000])
        XCTAssertTrue(firmware.directories.allSatisfy(\.checksumMatches))
        XCTAssertEqual(firmware.directories[1].pspID, 0xBC0C_0140, "the combo entry chose it for that id")
        XCTAssertEqual(firmware.directories[2].addressMode, .directoryRelative)

        let psp = firmware.directories[1].entries
        XCTAssertEqual(psp[0].range, 0x3_2000..<0x3_2100, "a mapped address")
        XCTAssertTrue(psp[1].isValue, "a soft fuse is a value")
        XCTAssertNil(psp[1].range)
        XCTAssertEqual(firmware.directories[2].entries[0].range, 0x3_3400..<0x3_3600, "relative to the directory")
        XCTAssertEqual(firmware.directories[2].entries[1].range, 0x3_2000..<0x3_2080, "the entry's own mode")

        let bios = firmware.directories[3].entries
        XCTAssertEqual(bios.map(\.typeName), ["APCB", "APOB", "BIOS", "BIOS_L2_PTR"])
        XCTAssertNil(bios[1].range, "the APOB has a destination and no blob")
        XCTAssertEqual(bios[1].destination, 0x9F0_0000)
        XCTAssertTrue(bios[2].isCompressed && bios[2].isReset && bios[2].isCopy)
        XCTAssertTrue(bios[2].isStoredCompressed)
        XCTAssertEqual(bios[2].range, 0x5_0000..<UInt64(0x5_0100 + fixture.stream),
                       "the header and the stream, not the size it inflates to")
        let microcode = firmware.directories[4].entries[0]
        XCTAssertEqual(microcode.typeName, "MICROCODE_PATCH")
        XCTAssertEqual(microcode.instance, 1)
        XCTAssertEqual(AMDFirmware.entryName(microcode), "MICROCODE_PATCH, instance 1")

        let blobs = firmware.blobs.map { $0.entry.range! }
        XCTAssertEqual(blobs.filter { $0.lowerBound == 0x3_2000 }, [0x3_2000..<0x3_2080],
                       "one blob for the boot loader both levels name, at the smaller size")
    }

    func testAChecksumThatDoesNotMatchIsSaid() throws {
        var bytes = try fixture().bytes
        bytes[0x3_1000 + 0x10 + 4] ^= 1
        let firmware = try XCTUnwrap(AMDFirmware.read(ImageReader(bytes)))
        XCTAssertFalse(firmware.directories[1].checksumMatches)
        XCTAssertTrue(firmware.directories[0].checksumMatches)
    }

    func testFletcher32IsThePSPs() {
        // PSPTool's `fletcher32`, little-endian.
        XCTAssertEqual(AMDFirmware.fletcher32([1, 2, 3, 4]), 0x0805_0604)
        let ramp: [UInt8] = (0...255).map { UInt8($0) }
        XCTAssertEqual(AMDFirmware.fletcher32(ramp + ramp + ramp), 0x0060_BF40, "past the fold at 360 words")
    }

    func testNoEFSIsNoMap() throws {
        XCTAssertNil(AMDFirmware.read(ImageReader([UInt8](repeating: 0xFF, count: Self.size))))
        XCTAssertNil(AMDFirmware.read(ImageReader([UInt8](repeating: 0xFF, count: 0x10_0000))), "smaller than any AMD flash")
        var orphan = [UInt8](repeating: 0xFF, count: Self.size)
        put32(AMDFirmware.efsSignature, at: 0x2_0000, in: &orphan)
        put32(0x3_0000, at: 0x2_0014, in: &orphan)
        XCTAssertNil(AMDFirmware.read(ImageReader(orphan)), "an EFS that leads to no directory")
        let intel = try fixture().bytes
        XCTAssertEqual(AMDFirmware.romSize(forFileSize: UInt64(intel.count + 0x300)), 0x80_0000,
                       "a dump with bytes appended is still its chip")
    }

    // MARK: - The rows

    func testEveryStructureIsARowInThePadding() throws {
        let fixture = try fixture()
        let image = UEFIParser.parse(fixture.bytes)
        let rows = image.allNodes.filter { [.amdEFS, .amdDirectory, .amdFirmwareEntry].contains($0.kind) }

        XCTAssertEqual(rows.filter { $0.kind == .amdDirectory }.map(\.name),
                       ["PSP combo directory 2PSP", "PSP directory $PSP", "PSP level 2 directory $PL2",
                        "BIOS directory $BHD", "BIOS level 2 directory $BL2"])
        XCTAssertEqual(rows.first { $0.kind == .amdDirectory }?.range, 0x3_0000..<0x3_0030)
        let names = rows.filter { $0.kind == .amdFirmwareEntry }.map(\.name)
        XCTAssertEqual(Set(names), ["PSP_FW_BOOT_LOADER", "SEC_GASKET", "PSP_FW_TRUSTED_OS", "APCB", "BIOS",
                                    "MICROCODE_PATCH, instance 1"])
        XCTAssertTrue(rows.allSatisfy { $0.uefiItemType == UEFITypes.Item.padding.rawValue }, "padding to UEFITool")
        XCTAssertTrue(rows.allSatisfy(\.isFixed), "the PSP finds them by address")

        // A blob around a row already read takes it in.
        let gasket = try XCTUnwrap(rows.first { $0.name == "SEC_GASKET" })
        XCTAssertEqual(gasket.range, 0x1_F000..<0x2_1000)
        XCTAssertEqual(gasket.children.map(\.kind), [.padding, .amdEFS, .padding])
    }

    /// The BIOS image the PSP inflates opens to what it inflates to, read as a
    /// stretch of flash: its volume and the files in it.
    func testTheCompressedBIOSImageOpens() throws {
        let fixture = try fixture()
        let image = UEFIParser.parse(fixture.bytes)
        let bios = try XCTUnwrap(image.allNodes.first { $0.kind == .amdFirmwareEntry && $0.name == "BIOS" })
        XCTAssertEqual(bios.compression, SectionCompression(algorithm: "Zlib (AMD)", decodes: true))
        XCTAssertEqual(bios.header, 0x5_0000..<0x5_0100)
        let volume = try XCTUnwrap(bios.children.first)
        XCTAssertEqual(volume.kind, .volume)
        XCTAssertEqual(volume.space, .decompressed(chain: [0x5_0000]))
        XCTAssertEqual(volume.range, 0..<UInt64(fixture.volume.count))
        XCTAssertTrue(volume.children.contains { $0.kind == .file })

        let reader = try XCTUnwrap(SpaceReaders(file: ImageReader(fixture.bytes)).reader(for: volume.space))
        XCTAssertEqual(reader.bytes(reader.all), fixture.volume)
    }

    /// Nothing compresses it again the way the PSP reads it, so a change
    /// inside is refused, by name.
    func testAChangeInsideTheInflatedImageIsRefused() throws {
        let fixture = try fixture()
        let space = ByteSpace.file.inside(sectionAt: 0x5_0000)
        guard case .failure(let refusal) = UEFIRebuild.plan(fixture.volume, at: .init(space: space),
                                                             in: fixture.bytes) else {
            return XCTFail("a change inside the PSP's BIOS image went through")
        }
        XCTAssertTrue(refusal.message.contains("the PSP inflates"), refusal.message)
    }
}
