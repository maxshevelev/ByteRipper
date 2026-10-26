import Foundation
import XCTest
import CodeAnalysis
@testable import GhidraHost

final class TEImageTests: XCTestCase {
    /// A two-section 32-bit TE image built here, and the PE `te_to_pe.py`
    /// makes of it (generated once, pinned as hex).
    func testASyntheticImageConvertsAsThePythonScriptDoes() throws {
        var te = [UInt8](repeating: 0, count: 40 + 2 * 40 + 0x40)
        func put(_ at: Int, _ value: UInt64, _ size: Int) {
            for i in 0..<size { te[at + i] = UInt8(truncatingIfNeeded: value >> (8 * i)) }
        }
        te[0] = 0x56; te[1] = 0x5A
        put(2, 0x14C, 2); te[4] = 2; te[5] = 0x0B; put(6, 0x1C8, 2)
        put(8, 0x240, 4); put(12, 0x240, 4); put(16, 0xFFC00000, 8)
        put(24, 0x2A0, 4); put(28, 0x10, 4)
        for (index, name) in [".text", ".data"].enumerated() {
            let at = 40 + index * 40
            for (i, byte) in name.utf8.enumerated() { te[at + i] = byte }
            put(at + 8, 0x20, 4); put(at + 12, 0x240 + UInt64(index) * 0x20, 4)
            put(at + 16, 0x20, 4); put(at + 20, 0x218 + UInt64(index) * 0x20, 4)
            put(at + 36, index == 0 ? 0x60000020 : 0xC0000040, 4)
        }
        for i in 0..<0x40 { te[120 + i] = UInt8(i) }
        let pe = try TEImage.convert(Data(te))
        XCTAssertEqual(SHA256Digest.hex(of: pe), Self.expected)
        XCTAssertEqual(Array(pe.prefix(2)), [0x4D, 0x5A])
        XCTAssertThrowsError(try TEImage.convert(Data("MZ".utf8)))
    }

    static let expected = "7a880d30478f01dc4237306e9fd4c0dc84cb353b31f155cdb7905519a305feab"

    /// Every TE image of a folder against the `.pe` `te_to_pe.py` wrote beside
    /// it; run with `TE_PARITY_DIR` set.
    func testRealImagesMatchThePythonScript() throws {
        guard let folder = ProcessInfo.processInfo.environment["TE_PARITY_DIR"] else {
            throw XCTSkip("TE_PARITY_DIR names no folder of .te and .pe pairs")
        }
        let files = try FileManager.default.contentsOfDirectory(atPath: folder).filter { $0.hasSuffix(".te") }
        var compared = 0
        for name in files {
            let te = try Data(contentsOf: URL(fileURLWithPath: folder).appendingPathComponent(name))
            let peURL = URL(fileURLWithPath: folder).appendingPathComponent(name.replacingOccurrences(of: ".te", with: ".pe"))
            guard let expected = try? Data(contentsOf: peURL) else { continue }
            XCTAssertEqual(try TEImage.convert(te), expected, name)
            compared += 1
        }
        XCTAssertGreaterThan(compared, 0)
        print("TE parity: \(compared) images")
    }
}

extension SHA256Digest {
    static func hex(of data: Data) -> String { SHA256Digest(data: data).hex }
}
