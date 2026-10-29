import XCTest
@testable import MEFirmware

/// The FPF/UEP settings: the tool's own layout of the `$UEP` area's bit
/// arrays, and reading an image's area through it.
final class UEPMapTests: XCTestCase {
    /// The map is the tool's: identifiers, its own names and sections, and the
    /// places in the first array — the array the engine reads.
    func testTheMapIsTheToolsOwnLayoutOfTheFirstArray() throws {
        let map = try XCTUnwrap(UEPMap.forME(major: 16))
        let rpMc = try XCTUnwrap(map.settings.first { $0.name == "RpmcSupported" })
        XCTAssertEqual(rpMc.label, "RPMC Supported")
        XCTAssertEqual(rpMc.section, "RpmcConfiguration")
        XCTAssertEqual(rpMc.placement, .init(array: 0, offset: 0x74, bit: 4, count: 1))
        XCTAssertTrue(map.settings.allSatisfy { $0.placement.array == 0 },
                      "a setting the tool places only elsewhere is not in the map")
        XCTAssertEqual(map.settings.count, 76, "16.1.42's first array")
        // What 16.1.42 adds to the array.
        for name in ["CPU_AAB_ENABLED", "PCH_AAB_ENABLED", "OEM_CIM_ARB_EN",
                     "OEM_PIM_ARB_EN", "RpmcOverEc"] {
            XCTAssertNotNil(map.settings.first { $0.name == name }, name)
        }

        // Flash Image Tool 15 names the same bits by their identifiers alone.
        let fit = try XCTUnwrap(UEPMap.forME(major: 15))
        XCTAssertGreaterThan(fit.settings.count, 50)
        XCTAssertNil(fit.settings.first?.label)
        // 12, 13 and 14 have maps too — each FIT build's own platform
        // document — although the profile itself is still a record there.
        XCTAssertNotNil(UEPMap.forME(major: 12))
        XCTAssertNotNil(UEPMap.forME(major: 13))
        XCTAssertNotNil(UEPMap.forME(major: 14))
        XCTAssertNil(UEPMap.forME(major: 17))
    }

    /// CSME 18's map is the tool's rewritten `UEPs_Data`, read from the array
    /// that follows its own 8-byte `$UEP` header.
    func testTheCSME18MapFollowsTheRewrittenDatabase() throws {
        let map = try XCTUnwrap(UEPMap.forME(major: 18))
        XCTAssertEqual(map.arrayStart, 8, "the tool's header is signature + CRC-16 + reserved")
        XCTAssertEqual(map.arraySize, 0x80)
        XCTAssertEqual(map.settings.count, 41)
        let profile = try XCTUnwrap(map.settings.first { $0.name == "BTG_PROFILE" })
        XCTAssertEqual(profile.placement, .init(array: 0, offset: 0x48, bit: 30, count: 3))
        XCTAssertEqual(profile.label, "Boot Guard Profile")
        XCTAssertEqual(profile.section, "BootGuardConfiguration")
        XCTAssertEqual(profile.options, [0: "Boot Guard Disabled", 3: "Debug Profile",
                                         4: "Verified Boot", 5: "Verified and Measured Boot"])
        let kmID = try XCTUnwrap(map.settings.first { $0.name == "KM_ID" })
        XCTAssertEqual(kmID.placement, .init(array: 0, offset: 0x48, bit: 23, count: 4))
        // The tool's validity bits are named by their identifiers and carry no
        // UI words of their own.
        let idSet = try XCTUnwrap(map.settings.first { $0.name == "OEM_ID_V" })
        XCTAssertNil(idSet.label)
        XCTAssertEqual(idSet.placement, .init(array: 0, offset: 0x4C, bit: 6, count: 1))
        // The tool places some settings in the second array; the map says so
        // rather than dropping them.
        let platformID = try XCTUnwrap(map.settings.first { $0.name == "PLAT_ID" })
        XCTAssertEqual(platformID.placement, .init(array: 1, offset: 0x4, bit: 0, count: 16))
        XCTAssertEqual(platformID.label, "DnX OEM Platform ID")
        XCTAssertNotNil(map.settings.first { $0.name == "ESE_ROM_SVN_EN" })
        // 15/16 keep to the first array, so size 0 leaves the place as the
        // tool's own offset.
        XCTAssertEqual(UEPMap.forME(major: 16)?.arraySize, 0)
        // The 15/16 array start is the measured one, not a header size.
        XCTAssertEqual(UEPMap.forME(major: 16)?.arrayStart, UEPReader.firstArrayOffset)
        XCTAssertNil(UEPMap.forME(major: 17))
    }

    /// CSME 12's map is Flash Image Tool 12's CNP `Uep` class: four arrays
    /// after its own 8-byte header, with the tool's labels and value words.
    func testTheCSME12MapFollowsFlashImageToolsClassDocuments() throws {
        let map = try XCTUnwrap(UEPMap.forME(major: 12))
        XCTAssertEqual(map.arrayStart, 8, "signature + CRC-16 + reserved")
        XCTAssertEqual(map.arraySize, 0x80)
        XCTAssertEqual(map.settings.count, 42)
        let vendor = try XCTUnwrap(map.settings.first { $0.name == "OemVendorId" })
        XCTAssertEqual(vendor.placement, .init(array: 0, offset: 0x3C, bit: 0, count: 16))
        XCTAssertEqual(vendor.label, "OEM Vendor ID")
        XCTAssertEqual(vendor.section, "OEMandPlatformIDs")
        // The Boot Guard profile proper is a record on this generation; the
        // array holds its individual bits.
        let verified = try XCTUnwrap(map.settings.first { $0.name == "VerifiedBoot" })
        XCTAssertEqual(verified.placement, .init(array: 0, offset: 0x44, bit: 5, count: 1))
        XCTAssertEqual(verified.options, [0: "false", 1: "true"])
        // A value class's words: `SupportedFpfValues` is 0xC "No", 0xF "Yes".
        let ptt = try XCTUnwrap(map.settings.first { $0.name == "PttSupportedFpf" })
        XCTAssertEqual(ptt.options, [12: "No", 15: "Yes"])
        // What only a later array holds is kept, once.
        let bsmm = try XCTUnwrap(map.settings.first { $0.name == "sb_bsmm_svn" })
        XCTAssertEqual(bsmm.placement, .init(array: 1, offset: 0x40, bit: 30, count: 15))
        XCTAssertEqual(map.settings.filter { $0.name == "sb_bsmm_svn" }.count, 1)
        // The 256-bit key hash is not a row the reader could fill.
        XCTAssertNil(map.settings.first { $0.name == "OemPublicKeyHash" })
    }

    /// CSME 12's first array reads where the tool places its bits: the word
    /// the CSME 12 dump carries at array 0 +0x40 is 0x0058E080 — FW_TYPE 3
    /// with its valid bit, and the ID validity bits set.
    func testTheCSME12ArrayReadsWhereTheToolPlacesItsBits() throws {
        let map = try XCTUnwrap(UEPMap.forME(major: 12))
        var area = Data("$UEP".utf8)
        area.append(Data(count: 4))                       // CRC-16 + reserved
        area.append(Data(count: 4 * 0x80))                // arrays_count 4
        let word = area.startIndex + map.arrayStart + 0x40
        area[word] = 0x80
        area[word + 1] = 0xE0
        area[word + 2] = 0x58
        let readings = try XCTUnwrap(UEPReader.readings(in: area, map: map))
        XCTAssertEqual(readings.first { $0.name == "lo_id_v" }?.value, 1)
        XCTAssertEqual(readings.first { $0.name == "oem_id_v" }?.value, 1)
        XCTAssertEqual(readings.first { $0.name == "plat_id_v" }?.value, 1)
        XCTAssertEqual(readings.first { $0.name == "fw_type" }?.value, 3)
        XCTAssertEqual(readings.first { $0.name == "fw_type_v" }?.value, 1)
        XCTAssertEqual(readings.first { $0.name == "OemVendorId" }?.value, 0)

        // And the same area as a slice of a larger buffer reads the same.
        let buffer = Data(repeating: 0xA5, count: 0x100) + area
        let fromSlice = try XCTUnwrap(UEPReader.readings(in: buffer[0x100...], map: map))
        XCTAssertEqual(fromSlice, readings)
    }

    /// CSME 13 and 14's maps are their FIT builds' Ice Lake and Comet Lake
    /// `Uep` documents, with the profile bits where the four builds of each
    /// generation put profiles 0, 3, 4 and 5.
    func testTheCSME13And14MapsAreTheirPlatformsDocuments() throws {
        let thirteen = try XCTUnwrap(UEPMap.forME(major: 13))
        XCTAssertEqual(thirteen.settings.count, 43)
        XCTAssertEqual(thirteen.arrayStart, 8, "signature + CRC-16 + reserved")
        XCTAssertEqual(thirteen.arraySize, 0x80)
        let verified13 = try XCTUnwrap(thirteen.settings.first { $0.name == "VerifiedBoot" })
        XCTAssertEqual(verified13.placement, .init(array: 0, offset: 0x5C, bit: 5, count: 1))
        XCTAssertEqual(verified13.section, "BootGuardProfileSettings")
        XCTAssertEqual(verified13.options, [0: "false", 1: "true"])
        XCTAssertEqual(thirteen.settings.first { $0.name == "fw_type" }?.placement,
                       .init(array: 0, offset: 0x58, bit: 19, count: 3))

        let fourteen = try XCTUnwrap(UEPMap.forME(major: 14))
        XCTAssertEqual(fourteen.settings.count, 44)
        let verified14 = try XCTUnwrap(fourteen.settings.first { $0.name == "VerifiedBoot" })
        XCTAssertEqual(verified14.placement, .init(array: 0, offset: 0x44, bit: 5, count: 1))
        XCTAssertEqual(fourteen.settings.first { $0.name == "fw_type" }?.placement,
                       .init(array: 0, offset: 0x40, bit: 19, count: 3))
    }

    /// The four FIT builds of CSME 13's dump differ exactly where the tool
    /// says the profile lives: array 0 +0x5C reads 0x40, 0x78, 0x69 and 0x79
    /// — profiles 0, 3, 4 and 5 in the bits the map names.
    func testTheCSME13ProfileBitsReadTheBuilds() throws {
        let map = try XCTUnwrap(UEPMap.forME(major: 13))
        func readings(_ byte: UInt8) -> [String: Int] {
            var area = Data("$UEP".utf8)
            area.append(Data(count: 4))                   // CRC-16 + reserved
            area.append(Data(count: 6 * 0x80))            // six arrays
            area[area.startIndex + map.arrayStart + 0x5C] = byte
            let list = UEPReader.readings(in: area, map: map) ?? []
            return Dictionary(uniqueKeysWithValues: list.map { ($0.name, $0.value) })
        }
        XCTAssertEqual(readings(0x40)["VerifiedBoot"], 0)
        XCTAssertEqual(readings(0x40)["MeasuredBoot"], 0)
        XCTAssertEqual(readings(0x78)["VerifiedBoot"], 1)
        XCTAssertEqual(readings(0x78)["MeasuredBoot"], 1)
        XCTAssertEqual(readings(0x69)["VerifiedBoot"], 1)
        XCTAssertEqual(readings(0x69)["MeasuredBoot"], 0)
        XCTAssertEqual(readings(0x79)["VerifiedBoot"], 1)
        XCTAssertEqual(readings(0x79)["MeasuredBoot"], 1)
        XCTAssertEqual(readings(0x79)["ProtectBiosEnvironment"], 1)
    }

    /// The CSME 18 arrays start after the tool's 8-byte header: the profile's
    /// bits 30–32 at offset 0x48 read the value the HP dump carries (5), and a
    /// setting the tool places in the second array reads the word the dump
    /// carries there.
    func testTheCSME18ArrayStartsAfterTheToolsHeader() throws {
        let map = try XCTUnwrap(UEPMap.forME(major: 18))
        var area = Data("$UEP".utf8)
        area.append(Data(count: 4))                       // CRC-16 + reserved
        area.append(Data(count: 4 * 0x80))                // arrays_count 4
        let word = area.startIndex + map.arrayStart + 0x48
        area[word + 3] = 0x40                             // (5 << 30) little-endian
        area[word + 4] = 0x01
        // PLAT_ID | DNX | RPMC_RB | PLAT_ID_V | CSE_BOOTSTRAP_SVN_EN |
        // CSE_FW_SVN_EN at array 1, offset 4 — the HP dump's 0x001D0000.
        let second = area.startIndex + map.arrayStart + map.arraySize + 0x4
        area[second + 2] = 0x1D
        let readings = try XCTUnwrap(UEPReader.readings(in: area, map: map))
        XCTAssertEqual(readings.first { $0.name == "BTG_PROFILE" }?.value, 5)
        XCTAssertEqual(readings.first { $0.name == "PLAT_ID" }?.value, 0)
        XCTAssertEqual(readings.first { $0.name == "DNX" }?.value, 1)
        XCTAssertEqual(readings.first { $0.name == "RPMC_RB" }?.value, 0)
        XCTAssertEqual(readings.first { $0.name == "PLAT_ID_V" }?.value, 1)
        XCTAssertEqual(readings.first { $0.name == "CSE_BOOTSTRAP_SVN_EN" }?.value, 1)
        XCTAssertEqual(readings.first { $0.name == "CSE_FW_SVN_EN" }?.value, 1)
        XCTAssertEqual(readings.first { $0.name == "ESE_ROM_SVN_EN" }?.value, 0)
        // Read at the 15/16 array start the same bytes are another setting's
        // (and not the profile): the placement is the tool's, not a guess.
        let shifted = map
        let atTwelve = UEPMap(name: "test", settings: shifted.settings, arrayStart: 0x0C)
        XCTAssertNotEqual(UEPReader.readings(in: area, map: atTwelve)?
                            .first { $0.name == "BTG_PROFILE" }?.value, 5)
    }

    /// A setting's bits are read little-endian from its offset in the array,
    /// which begins 0x0C bytes past the container's signature — where the Boot
    /// Guard word sits, too — and a field may run past the word it starts in.
    func testTheAreasBitsAreReadWhereTheToolPlacesThem() throws {
        var area = Data("$UEP".utf8)
        area.append(Data(repeating: 0, count: 0x0C - 4))
        area.append(Data(count: 0x20))                     // the first array
        let array = UEPReader.firstArrayOffset
        // offset 4, bit 4: the word at array+4 = 0x10
        area[array + 4] = 0x10
        // offset 0, bits 8–11: the word at array = 0x0A00
        area[array] = 0x00
        area[array + 1] = 0x0A
        // A field that runs past its word — `sb_bsmm_svn` is 15 bits from bit
        // 30 — is read on across the next byte: 0b1011 from bits 30–33.
        area[array + 3] = 0xC0
        area[array + 4] = 0x12                             // 0x02 for the field
        let map = UEPMap(name: "test", settings: [
            .init(name: "One", placement: .init(array: 0, offset: 4, bit: 4, count: 1)),
            .init(name: "Four", placement: .init(array: 0, offset: 0, bit: 8, count: 4)),
            .init(name: "Pad", placement: .init(array: 0, offset: 2, bit: 0, count: 1)),
            .init(name: "Across", placement: .init(array: 0, offset: 0, bit: 30, count: 4)),
        ])
        let readings = try XCTUnwrap(UEPReader.readings(in: area, map: map))
        XCTAssertEqual(readings, [.init(name: "One", value: 1),
                                  .init(name: "Four", value: 0xA),
                                  .init(name: "Pad", value: 0),
                                  .init(name: "Across", value: 0b1011)])
    }

    /// No container, or one too short for a setting's bytes: nothing is
    /// claimed, rather than zeros read past the area.
    func testAnAreaWithoutAContainerAnswersNothing() {
        let map = UEPMap(name: "test", settings: [
            .init(name: "One", placement: .init(array: 0, offset: 4, bit: 4, count: 1)),
        ])
        XCTAssertNil(UEPReader.readings(in: Data(repeating: 0xFF, count: 0x40), map: map))
        var short = Data("$UEPC".utf8)
        short.append(Data(count: 0x0C))
        let past = UEPMap(name: "test", settings: [
            .init(name: "Past", placement: .init(array: 0, offset: 8, bit: 0, count: 8)),
        ])
        XCTAssertNil(UEPReader.readings(in: short, map: past))
    }
}
