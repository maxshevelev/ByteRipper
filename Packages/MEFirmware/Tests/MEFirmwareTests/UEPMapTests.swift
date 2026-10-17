import XCTest
@testable import MEFirmware

/// The FPF/UEP settings: the tool's own layout of the `$UEP` area's first bit
/// array, and reading an image's area through it.
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
        XCTAssertGreaterThan(map.settings.count, 60)

        // Flash Image Tool 15 names the same bits by their identifiers alone.
        let fit = try XCTUnwrap(UEPMap.forME(major: 15))
        XCTAssertGreaterThan(fit.settings.count, 50)
        XCTAssertNil(fit.settings.first?.label)
        // CSME 12 to 14 keep the profile in a record, not in these arrays.
        XCTAssertNil(UEPMap.forME(major: 14))
        XCTAssertNil(UEPMap.forME(major: 12))
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
