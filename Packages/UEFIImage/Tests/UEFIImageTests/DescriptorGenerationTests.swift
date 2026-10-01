import XCTest
@testable import UEFIImage

/// The chipset generation a descriptor's layout is (§2.5), checked on the
/// map words of the dumps at hand, whose ME region names its own chipset.
final class DescriptorGenerationTests: XCTestCase {
    /// A descriptor's first `0x1000` bytes with only the words the rules read.
    private func generation(map1: UInt32, map2: UInt32, mipBase: UInt8)
        -> (generation: DescriptorGeneration, isCertain: Bool)? {
        var bytes = [UInt8](repeating: 0xFF, count: 0x1000)
        func put(_ value: UInt32, at offset: Int) {
            for index in 0..<4 { bytes[offset + index] = UInt8(truncatingIfNeeded: value >> (8 * index)) }
        }
        put(Descriptor.signature, at: 0x10)
        put(map1, at: 0x18)
        put(map2, at: 0x1C)
        bytes[0x0EFF] = mipBase
        return DescriptorGeneration.read(at: 0, in: ImageReader(bytes))
    }

    func testTheDumpsAtHandAreToldApart() throws {
        let cases: [(String, UInt32, UInt32, UInt8, DescriptorGeneration)] = [
            ("ME 7 (Cougar Point)", 0x1210_0206, 0x0021_0120, 0x00, .cougarPoint),
            ("CSME 11 (Sunrise Point LP)", 0x4210_0208, 0x0031_0330, 0x00, .sunrisePoint),
            ("CSME 12 (Cannon Point H)", 0x5A10_0208, 0x0034_0330, 0xC0, .cannonPoint),
            ("CSME 15 (Tiger Point LP)", 0x4610_0208, 0x0011_01A0, 0xC0, .tigerPoint),
            ("1.bin (Tiger Point H)", 0x6510_0208, 0x0011_01B0, 0xC0, .tigerPoint),
            ("CSME 16 (Alder Point)", 0x7310_0208, 0x0014_0170, 0xC0, .alderPoint),
            ("clean_me (Alder Point LP)", 0x4610_0208, 0x0014_01B0, 0xC0, .alderPoint),
        ]
        for (name, map1, map2, mip, expected) in cases {
            let read = try XCTUnwrap(generation(map1: map1, map2: map2, mipBase: mip), name)
            XCTAssertEqual(read.generation, expected, name)
            XCTAssertTrue(read.isCertain, name)
        }
    }

    /// A layout no rule names is read as the newest family the rules end on,
    /// and says it is assumed.
    func testAnUnknownLayoutIsAssumed() throws {
        let read = try XCTUnwrap(generation(map1: 0x4610_0208, map2: 0x0077_01B0, mipBase: 0xC0))
        XCTAssertEqual(read.generation, .tigerPoint)
        XCTAssertFalse(read.isCertain)
    }

    /// What the generation changes in the reading.
    func testTheGenerationDecidesTheLayout() {
        XCTAssertEqual(DescriptorGeneration.cougarPoint.regionCount, 5)
        XCTAssertEqual(DescriptorGeneration.sunrisePoint.regionCount, 10)
        XCTAssertEqual(DescriptorGeneration.alderPoint.regionCount, 16)
        XCTAssertFalse(DescriptorGeneration.cougarPoint.hasWideMasks)
        XCTAssertTrue(DescriptorGeneration.sunrisePoint.hasWideMasks)
        XCTAssertEqual(DescriptorGeneration.cougarPoint.densityBits, 3)
        XCTAssertEqual(DescriptorGeneration.lynxPoint.densityBits, 4)
        // One code, three clocks, by generation.
        XCTAssertEqual(DescriptorGeneration.cougarPoint.clock(4), [50])
        XCTAssertEqual(DescriptorGeneration.sunrisePoint.clock(4), [30])
        XCTAssertEqual(DescriptorGeneration.alderPoint.clock(4), [25])
        XCTAssertNil(DescriptorGeneration.alderPoint.clock(2))
    }
}
