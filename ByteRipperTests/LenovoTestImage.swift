import Foundation

/// An image with a Lenovo identity store in it, laid out as the real dumps lay
/// theirs out — the log, then two blocks XORed with one key — with made-up
/// values.
enum LenovoTestImage {
    static let key: UInt8 = 0x77
    static let namespace: [UInt8] = [
        0x55, 0x57, 0x0E, 0xC2, 0x69, 0x11, 0x56, 0x4C,
        0xA4, 0x8A, 0x98, 0x24, 0xAB, 0x43
    ]
    /// Where the log starts; the blocks follow at +0x2000 and +0x3000.
    static let area = 0x1000
    /// Block 2's serial number value, in the file.
    static let serialInBlock2 = 0x4000 + 0x10 + 0x18

    static func block(generation: UInt32) -> [UInt8] {
        var body = namespace + [0x00, 0x04] + le32(8) + [0, 0, 0, 0] + Array("PF0TEST1".utf8)
        body += [UInt8](repeating: 0, count: 0x1000 - 16 - body.count)
        body = body.map { $0 ^ key }
        let sum = body.reduce(UInt16(0)) { $0 &+ UInt16($1) }
        return Array("LENV".utf8) + le32(generation) + le32(1)
            + [0, key, UInt8(sum & 0xFF), UInt8(sum >> 8)] + body
    }

    static func make() -> [UInt8] {
        let log = Array("LDBG".utf8) + le32(0x20) + [UInt8](repeating: 0, count: 24)
            + [UInt8](repeating: key, count: 0x2000 - 0x20)
        return [UInt8](repeating: 0xFF, count: area) + log
            + block(generation: 4) + block(generation: 5)
            + [UInt8](repeating: 0xFF, count: 0x1000)
    }

    static func le32(_ value: UInt32) -> [UInt8] { (0..<4).map { UInt8((value >> (8 * $0)) & 0xFF) } }
}
