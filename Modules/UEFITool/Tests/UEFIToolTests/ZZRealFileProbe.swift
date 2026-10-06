import UEFIImage
import XCTest
@testable import UEFITool

final class ZZRealFileProbe: XCTestCase {
    func testRealFile() throws {
        let file = [UInt8](try Data(contentsOf: URL(fileURLWithPath: NSHomeDirectory() + "/Desktop/ME/Asus/X1704VAPF.306")))
        let dump = [UInt8](try Data(contentsOf: URL(fileURLWithPath: NSHomeDirectory() + "/Desktop/ME/Asus/SPI_C27519_256Mbit.orig.bin")))
        let start = Date()
        let (c, u) = try UEFIUpdateComparison.compare(file: file, with: Array(dump[0xB00000..<0x2000000]), at: 0xB00000).get()
        print("PROBE time", Date().timeIntervalSince(start), "blocks", u.blockCount, c.platform)
        for r in c.rows { print("PROBE", r.nameText, String(r.range.lowerBound, radix: 16), r.key, r.stateText, r.writesByDefault, r.differences.count) }
        let all = Set(c.rows.indices)
        let t = c.transaction(writing: all, from: u)!
        var patched = dump
        for w in t.writes { patched.replaceSubrange(Int(w.offset)..<Int(w.offset) + w.bytes.count, with: w.bytes) }
        XCTAssertEqual(Array(patched[0xB00000..<0x2000000]), u.region)
        print("PROBE writes", t.writes.count)
    }
}
