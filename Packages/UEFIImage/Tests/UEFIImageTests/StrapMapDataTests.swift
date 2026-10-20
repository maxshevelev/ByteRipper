import XCTest
@testable import UEFIImage

/// The binary strap tables (`Design/UEFI/STRAP_MAP_DATA.md`): what the JSON
/// sources state, and what the reader refuses before it interprets a byte.
final class StrapMapDataTests: XCTestCase {
    func testTheResourceLoadsWithTheBuildTheCodeWasMarkedWith() {
        XCTAssertNil(StrapMapData.failure)
        XCTAssertEqual(StrapMapData.pchMaps.map(\.words),
                       [69, 70, 74, 90, 101, 114, 115, 130])
        XCTAssertEqual(StrapMapData.sptMaps.map(\.words), [66, 88, 90, 139])
        XCTAssertEqual(StrapMapData.map(id: "pch115")?.words, 115)
        XCTAssertEqual(StrapMapData.map(id: "sptPch139")?.words, 139)
    }

    /// The field counts are the sources': a table that lost or gained entries
    /// in a rebuild is a changed layout, not a smaller file.
    func testTheTablesCarryTheFieldsTheSourcesState() {
        let counts: [String: Int] = [
            "pch69": 737, "pch70": 759, "pch74": 786, "pch90": 755,
            "pch101": 901, "pch114": 1212, "pch115": 1201, "pch130": 1184,
            "sptPch66": 559, "sptPch88": 664, "sptPch90": 733, "sptPch139": 1155,
        ]
        for (id, count) in counts {
            XCTAssertEqual(StrapMapData.map(id: id)?.fields.count, count, id)
        }
    }

    /// The 130-word SoC table is the one with labels and option words; both
    /// are in the binary as text, not as numbers only.
    func testTheSoCStrapsKeepTheirLabelsAndOptions() throws {
        let map = DescriptorStrapMap.pch130
        let field = try XCTUnwrap(map.fields.first { $0.options != nil })
        XCTAssertNotNil(field.label)
        XCTAssertFalse(try XCTUnwrap(field.options).isEmpty)
    }

    func testAStaleBuildIsRefusedBeforeAnySectionIsRead() throws {
        var data = try XCTUnwrap(StrapMapData.bundledData)
        let wrong = StrapMapData.expectedBuild + 1
        data[8] = UInt8(truncatingIfNeeded: wrong)
        data[9] = UInt8(truncatingIfNeeded: wrong >> 8)
        data[10] = UInt8(truncatingIfNeeded: wrong >> 16)
        data[11] = UInt8(truncatingIfNeeded: wrong >> 24)
        XCTAssertThrowsError(try StrapMapData.decode(data)) { error in
            guard case .buildMismatch(let file, let code)? = error as? MapDataError else {
                return XCTFail("\(error)")
            }
            XCTAssertEqual(file, wrong)
            XCTAssertEqual(code, StrapMapData.expectedBuild)
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
