import XCTest
@testable import UEFIImage

/// A variable's value read as its type: by the spec where it defines the
/// variable, by the attributes, by the bytes otherwise (§9).
final class NvramValueTests: XCTestCase {
    private let global = NvramValue.globalVariable
    private let vendor = EFIGUID(low: 0x1111_1111, high: 0x2222_2222)

    private func read(_ name: String, _ value: [UInt8], guid: EFIGUID? = nil, attributes: UInt32 = 7) -> NvramValue {
        NvramValue.read(name: name, guid: guid ?? vendor, attributes: attributes, value: value)
    }

    // MARK: - By the specification

    func testTheSpecsVariablesAreReadAsItDefinesThem() {
        XCTAssertEqual(read("BootOrder", [0x03, 0x00, 0x01, 0x20], guid: global),
                       NvramValue(content: .optionList([0x0003, 0x2001]), basis: .specification))
        XCTAssertEqual(read("BootNext", [0x01, 0x00], guid: global).content, .optionNumber(1))
        XCTAssertEqual(read("Timeout", [0x05, 0x00], guid: global).content, .number(5, size: 2))
        XCTAssertEqual(read("SecureBoot", [0x01], guid: global).content, .number(1, size: 1))
        XCTAssertEqual(read("Lang", Array("eng".utf8), guid: global).content, .text("eng", .ascii),
                       "the spec's text needs no terminator")
    }

    /// The spec's name under a vendor's GUID reads the same, and says so.
    func testASpecNameUnderAVendorGuidIsReadByTheName() {
        XCTAssertEqual(read("BootOrder", [0x80, 0x00]), NvramValue(content: .optionList([0x80]), basis: .name))
    }

    /// A value of another shape than the spec's is read from its bytes.
    func testASpecNameWithTheWrongShapeIsReadFromItsBytes() {
        XCTAssertEqual(read("Timeout", [0x05, 0x00, 0x00, 0x00], guid: global),
                       NvramValue(content: .number(5, size: 4), basis: .content))
    }

    func testALoadOptionReadsItsDescriptionAndPath() throws {
        let path = TestDevicePath.pciRoot + TestDevicePath.pci(device: 0x1F, function: 2) + TestDevicePath.file("\\EFI\\BOOT\\BOOTX64.EFI") + TestDevicePath.end
        var value: [UInt8] = [0x01, 0x00, 0x00, 0x00, UInt8(path.count), 0x00]
        value += TestNVRAM.ucs2("Windows Boot Manager") + path + [0xAA, 0xBB]
        let read = read("Boot0003", value, guid: global)
        XCTAssertEqual(read.basis, .specification)
        guard case .loadOption(let option) = read.content else { return XCTFail("\(read)") }
        XCTAssertEqual(option.description, "Windows Boot Manager")
        XCTAssertEqual(option.devicePath, "PciRoot(0x0)/Pci(0x1F,0x2)/\\EFI\\BOOT\\BOOTX64.EFI")
        XCTAssertEqual(option.optionalDataSize, 2)
        XCTAssertTrue(option.isActive)
    }

    func testOnlyFourUpperCaseHexDigitsMakeALoadOptionName() {
        XCTAssertTrue(NvramValue.isLoadOptionName("Boot00A1"))
        XCTAssertTrue(NvramValue.isLoadOptionName("PlatformRecovery0000"))
        XCTAssertFalse(NvramValue.isLoadOptionName("Boot00a1"))
        XCTAssertFalse(NvramValue.isLoadOptionName("BootOrder"))
        XCTAssertFalse(NvramValue.isLoadOptionName("Boot0001x"))
    }

    /// A certificate is named by its subject; hashes are only counted.
    func testASignatureDatabaseNamesItsCertificates() {
        let certificate = TestDevicePath.certificate(commonName: "Test Platform Key")
        let lists = TestDevicePath.signatureList(type: "A5C059A1-94E4-4AA7-87B5-AB155C2BF072", entries: [certificate])
            + TestDevicePath.signatureList(type: "C1C41626-504C-4092-ACA9-41F936934328",
                                           entries: [[UInt8](repeating: 1, count: 32), [UInt8](repeating: 2, count: 32)])
        let read = read("db", lists, guid: NvramValue.imageSecurityDatabase)
        XCTAssertEqual(read.basis, .specification)
        guard case .signatures(let found) = read.content else { return XCTFail("\(read)") }
        XCTAssertEqual(found.map(\.typeName), ["X.509", "SHA-256"])
        XCTAssertEqual(found[0].signatures.map(\.subject), ["Test Platform Key"])
        XCTAssertEqual(found[1].signatures.count, 2)
    }

    // MARK: - By the attributes

    func testAHardwareErrorRecordIsToldByItsAttribute() {
        XCTAssertEqual(read("HwErrRec0001", [0x43, 0x50, 0x45, 0x52], attributes: 0x0F),
                       NvramValue(content: .hardwareErrorRecord, basis: .attributes))
    }

    // MARK: - By the bytes

    func testTextIsToldByItsBytes() {
        XCTAssertEqual(read("x", TestNVRAM.ucs2("shutdown")).content, .text("shutdown", .ucs2))
        XCTAssertEqual(read("x", Array("Capsule0000".utf16).flatMap { [UInt8($0), 0] }).content,
                       .text("Capsule0000", .ucs2), "UCS-2 without a terminator")
        XCTAssertEqual(read("x", Array("en-US".utf8) + [0]).content, .text("en-US", .ascii))
        XCTAssertEqual(read("x", Array("[FUB]\r\nFUB=CBW28\r\n".utf8)).content, .text("[FUB]\r\nFUB=CBW28\r\n", .ascii))
        XCTAssertEqual(read("x", Array("cp".utf16).flatMap { [UInt8($0), 0] } + [0, 0]).content, .text("cp", .ucs2))
    }

    /// A counter whose bytes happen to be printable stays a number: as wide
    /// as a register, a value is text only with a terminator after three
    /// characters.
    func testARegisterWideValueIsANumberBeforeItIsText() {
        XCTAssertEqual(read("MTC", [0x39, 0x20, 0x00, 0x00]).content, .number(0x2039, size: 4))
        XCTAssertEqual(read("x", Array("e@7`".utf8)).content, .number(0x6037_4065, size: 4))
        XCTAssertEqual(read("x", Array("eng".utf8) + [0]).content, .text("eng", .ascii))
    }

    func testOtherValuesAreNumbersBySizeOrBytes() {
        XCTAssertEqual(read("x", [0x2C, 0x01]).content, .number(300, size: 2))
        XCTAssertEqual(read("x", [0, 0, 0, 0, 1, 0, 0, 0]).content, .number(1 << 32, size: 8))
        XCTAssertEqual(read("x", [0x00, 0x50, 0x41]).content, .bytes)
        XCTAssertEqual(read("x", []).content, .empty)
    }

    func testADevicePathIsToldByItsBytes() {
        let path = TestDevicePath.pciRoot + TestDevicePath.pci(device: 2, function: 0) + TestDevicePath.end
        XCTAssertEqual(read("ConOutDev", path, guid: global), NvramValue(content: .devicePath("PciRoot(0x0)/Pci(0x2,0x0)"),
                                                                         basis: .specification))
        XCTAssertEqual(read("efi-boot-device-data", path).content, .devicePath("PciRoot(0x0)/Pci(0x2,0x0)"))
    }
}

/// The spec's text form of device paths, and the checks that let a path be
/// told by its bytes (UEFI §10).
final class DevicePathTests: XCTestCase {
    func testNodesReadInTheSpecsTextForm() {
        let sata: [UInt8] = [3, 18, 10, 0, 0, 0, 0xFF, 0xFF, 0, 0]
        var hd: [UInt8] = [4, 1, 42, 0, 1, 0, 0, 0]
        hd += [0x00, 0x08, 0, 0, 0, 0, 0, 0] + [0x00, 0x20, 0x08, 0, 0, 0, 0, 0]
        hd += EFIGUID("3A5C66AD-43A7-491F-94C5-2A9428EEA3A9")!.bytes + [2, 2]
        let path = TestDevicePath.pciRoot + TestDevicePath.pci(device: 0x1F, function: 2) + sata + hd + TestDevicePath.end
        XCTAssertEqual(DevicePath.text(path),
                       "PciRoot(0x0)/Pci(0x1F,0x2)/Sata(0x0,0xFFFF,0x0)/HD(1,GPT,3A5C66AD-43A7-491F-94C5-2A9428EEA3A9,0x800,0x82000)")
    }

    func testInstancesAreSeparatedByCommas() {
        let instanceEnd: [UInt8] = [0x7F, 0x01, 4, 0]
        let path = TestDevicePath.pciRoot + instanceEnd + TestDevicePath.pciRoot + TestDevicePath.end
        XCTAssertEqual(DevicePath.text(path), "PciRoot(0x0),PciRoot(0x0)")
    }

    func testAnUnknownNodeIsNamedByItsTypes() {
        XCTAssertEqual(DevicePath.text([3, 99, 6, 0, 1, 2] + TestDevicePath.end), "Path(3,99)")
    }

    /// Anything that is not exactly a path is not one.
    func testBytesThatAreNotExactlyAPathAreNot() {
        XCTAssertNil(DevicePath.text(TestDevicePath.end), "an end alone names nothing")
        XCTAssertNil(DevicePath.text(TestDevicePath.pciRoot), "no end")
        XCTAssertNil(DevicePath.text(TestDevicePath.pciRoot + TestDevicePath.end + [0]), "bytes after the end")
        XCTAssertNil(DevicePath.text([9, 1, 4, 0] + TestDevicePath.end), "no such node type")
        XCTAssertNil(DevicePath.text([1, 1, 2, 0] + TestDevicePath.end), "a node shorter than its header")
    }
}

/// Device path nodes and signature lists, byte for byte.
enum TestDevicePath {
    static let pciRoot: [UInt8] = [2, 1, 12, 0, 0xD0, 0x41, 0x03, 0x0A, 0, 0, 0, 0]
    static let end: [UInt8] = [0x7F, 0xFF, 4, 0]

    static func pci(device: UInt8, function: UInt8) -> [UInt8] { [1, 1, 6, 0, function, device] }

    static func file(_ path: String) -> [UInt8] {
        let name = TestNVRAM.ucs2(path)
        return [4, 4, UInt8(4 + name.count), 0] + name
    }

    static func signatureList(type: String, entries: [[UInt8]]) -> [UInt8] {
        let signatureSize = 16 + entries[0].count
        let listSize = 28 + signatureSize * entries.count
        func u32(_ value: Int) -> [UInt8] { (0..<4).map { UInt8(value >> (8 * $0) & 0xFF) } }
        var bytes = EFIGUID(type)!.bytes + u32(listSize) + u32(0) + u32(signatureSize)
        for entry in entries { bytes += EFIGUID(low: 7, high: 7).bytes + entry }
        return bytes
    }

    /// A certificate as far as its subject: a TBSCertificate with a version,
    /// a serial, empty algorithm, issuer and validity, and a subject whose
    /// one attribute is the common name.
    static func certificate(commonName: String) -> [UInt8] {
        func der(_ tag: UInt8, _ content: [UInt8]) -> [UInt8] {
            content.count < 0x80 ? [tag, UInt8(content.count)] + content
                : [tag, 0x82, UInt8(content.count >> 8), UInt8(content.count & 0xFF)] + content
        }
        let name = der(0x0C, Array(commonName.utf8))
        let subject = der(0x30, der(0x31, der(0x30, der(0x06, [0x55, 0x04, 0x03]) + name)))
        let tbs = der(0x30, der(0xA0, der(0x02, [2])) + der(0x02, [1]) + der(0x30, []) + der(0x30, [])
                      + der(0x30, []) + subject)
        return der(0x30, tbs + der(0x30, []) + der(0x03, [0]))
    }
}

/// A VSS variable's header taken apart by its form (§9).
final class VSSVariableTests: XCTestCase {
    /// Intel's legacy form states only a total size: the name runs to its
    /// terminator, however long, and the value is what follows.
    func testAnIntelLegacyVariablesNameRunsToItsTerminator() throws {
        let name = TestNVRAM.ucs2("Setup")
        let data: [UInt8] = [0x01, 0x02, 0x03]
        func variable(state: UInt8) -> [UInt8] {
            var bytes: [UInt8] = [0xAA, 0x55, state, 0x00, 0x07, 0, 0, 0]
            bytes += [UInt8(28 + name.count + data.count), 0, 0, 0]
            return bytes + TestImage.driverGUID.bytes + name + data
        }
        let bytes = TestNVRAM.nvramVolume(stores: [TestNVRAM.vssStore(variables: [variable(state: 0xFC), variable(state: 0xF8)])])
        let image = UEFIParser.parse(bytes)
        let entries = image.roots[0].children[0].children.filter { $0.kind == .vssEntry }
        XCTAssertEqual(entries.map(\.name), ["Setup", "Invalid"])
        XCTAssertEqual(entries.map(\.subtype), [UEFITypes.Sub.intelVssEntry, UEFITypes.Sub.invalidVssEntry],
                       "0xF8 is Intel's invalid state")

        let reader = ImageReader(bytes)
        let read = try XCTUnwrap(VSSVariable.read(entries[0], in: image, reader: reader))
        XCTAssertEqual(read.form, .intelLegacy)
        XCTAssertEqual(reader.bytes(read.data), data)
        XCTAssertEqual(read.totalSize, UInt32(28 + name.count + data.count))
        XCTAssertNil(read.nameSize)
    }

    /// The authenticated form's count, time stamp and key index, and the
    /// sizes after them.
    func testAnAuthenticatedVariablesHeaderIsReadWhole() throws {
        var bytes = TestNVRAM.authVssVariable(name: "db", data: [0x01, 0x02, 0x03])
        bytes.replaceSubrange(8..<16, with: [5, 0, 0, 0, 0, 0, 0, 0])
        bytes.replaceSubrange(16..<23, with: [0xE7, 0x07, 5, 1, 12, 34, 56])
        bytes.replaceSubrange(32..<36, with: [9, 0, 0, 0])
        let read = try XCTUnwrap(VSSVariable.read(at: 0, limit: UInt64(bytes.count), inVss2: false,
                                                  reader: ImageReader(bytes)))
        XCTAssertEqual(read.form, .authenticated)
        XCTAssertEqual(read.monotonicCount, 5)
        XCTAssertEqual(read.timestamp?.text, "2023-05-01 12:34:56")
        XCTAssertEqual(read.publicKeyIndex, 9)
        XCTAssertEqual(read.nameSize, 6)
        XCTAssertEqual(read.dataSize, 3)
        XCTAssertEqual(read.decodedName(reader: ImageReader(bytes)), "db")
        XCTAssertEqual(read.data, 66..<69)
    }
}
