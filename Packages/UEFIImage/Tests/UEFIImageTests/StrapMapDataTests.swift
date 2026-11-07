import XCTest
@testable import UEFIImage

/// The binary strap tables (`Design/MAP_DATA.md`): what the JSON
/// sources state, and what the reader refuses before it interprets a byte.
final class StrapMapDataTests: XCTestCase {
    func testTheResourceLoadsWithTheVersionTheCodeWasMarkedWith() {
        XCTAssertNil(StrapMapData.failure)
        XCTAssertEqual(StrapMapData.pchMaps.map(\.words),
                       [69, 70, 74, 90, 101, 114, 115, 130])
        XCTAssertEqual(StrapMapData.sptMaps.map(\.words), [66, 88, 90, 139])
        XCTAssertEqual(StrapMapData.cpuMaps.map(\.words),
                       [1, 3, 7, 10, 14, 15, 17, 18, 20, 21, 22, 25, 11])
        XCTAssertEqual(StrapMapData.sptCPUMaps.map(\.words), [3])
        XCTAssertEqual(StrapMapData.pmcMaps.map(\.words), [7, 20, 21, 22])
        XCTAssertEqual(StrapMapData.mipMaps.map(\.words), [17, 20])
        XCTAssertEqual(StrapMapData.legacyMaps.map(\.words), [16, 18, 21])
        XCTAssertEqual(StrapMapData.map(id: "pch115")?.words, 115)
        XCTAssertEqual(StrapMapData.map(id: "sptPch139")?.words, 139)
        XCTAssertEqual(StrapMapData.map(id: "cpu11")?.words, 11)
    }

    /// The field counts are the sources': a table that lost or gained entries
    /// in a rebuild is a changed layout, not a smaller file.
    func testTheTablesCarryTheFieldsTheSourcesState() {
        let counts: [String: Int] = [
            "pch69": 737, "pch70": 759, "pch74": 786, "pch90": 755,
            "pch101": 901, "pch114": 1212, "pch115": 1201, "pch130": 1184,
            "sptPch66": 559, "sptPch88": 664, "sptPch90": 733, "sptPch139": 1155,
            "cpu1": 2, "cpu3": 20, "cpu7": 26, "cpu10": 27, "cpu11": 78,
            "cpu14": 109, "cpu15": 113, "cpu17": 19, "cpu18": 5, "cpu20": 81,
            "cpu21": 8, "cpu22": 10, "cpu25": 10, "sptCpu3": 27,
            "pmc7": 135, "pmc20": 194, "pmc21": 230, "pmc22": 232,
            "mipCpu17": 110, "mipCpu20": 73,
            "pch16": 48, "pch18": 54, "pch21": 66,
        ]
        for (id, count) in counts {
            XCTAssertEqual(StrapMapData.map(id: id)?.fields.count, count, id)
        }
    }

    /// The labelled tables keep their labels and option words as text, not
    /// as numbers only: the SoC table, the guides' legacy tables and the MIP
    /// message all state them.
    func testTheTablesKeepTheirLabelsAndOptions() throws {
        for map in [DescriptorStrapMap.pch130, DescriptorStrapMap.pch18,
                    DescriptorStrapMap.pch21, DescriptorStrapMap.mipCpu17] {
            let field = try XCTUnwrap(map.fields.first { $0.options != nil },
                                      map.name)
            XCTAssertNotNil(field.label, map.name)
            XCTAssertFalse(try XCTUnwrap(field.options).isEmpty, map.name)
        }
    }

    func testAStaleVersionIsRefusedBeforeAnySectionIsRead() throws {
        var data = try XCTUnwrap(StrapMapData.bundledData)
        let wrong = StrapMapData.expectedVersion + 1
        data[8] = UInt8(truncatingIfNeeded: wrong)
        data[9] = UInt8(truncatingIfNeeded: wrong >> 8)
        data[10] = UInt8(truncatingIfNeeded: wrong >> 16)
        data[11] = UInt8(truncatingIfNeeded: wrong >> 24)
        XCTAssertThrowsError(try StrapMapData.decode(data)) { error in
            guard case .versionMismatch(let file, let code)? = error as? MapDataError else {
                return XCTFail("\(error)")
            }
            XCTAssertEqual(file, wrong)
            XCTAssertEqual(code, StrapMapData.expectedVersion)
        }
    }

    func testAnotherFormatIsRefused() throws {
        var data = try XCTUnwrap(StrapMapData.bundledData)
        data[4] = 2
        data[5] = 0
        XCTAssertThrowsError(try StrapMapData.decode(data)) { error in
            XCTAssertEqual(error as? MapDataError, .unsupportedFormat(2))
        }
    }

    func testAnEditedFileFailsItsChecksum() throws {
        var data = try XCTUnwrap(StrapMapData.bundledData)
        data[data.count - 1] ^= 0xFF
        XCTAssertThrowsError(try StrapMapData.decode(data)) { error in
            guard case .corrupt? = error as? MapDataError else {
                return XCTFail("\(error)")
            }
        }
    }

    func testATruncatedFileIsReported() throws {
        let data = try XCTUnwrap(StrapMapData.bundledData).prefix(10)
        XCTAssertThrowsError(try StrapMapData.decode(Data(data))) { error in
            guard case .corrupt? = error as? MapDataError else {
                return XCTFail("\(error)")
            }
        }
    }
}
