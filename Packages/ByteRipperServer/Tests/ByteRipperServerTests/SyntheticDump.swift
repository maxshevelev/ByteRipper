import Foundation
import UEFIImage

/// A firmware image built byte by byte for the server's tests: one FFSv2
/// volume holding one DXE driver whose PE32 section is a stub image. No real
/// dump is ever committed; the UEFI parser's own tests build the broken
/// ones, and this is only enough for a tree to read.
enum SyntheticDump {
    static let driver = EFIGUID("11111111-2222-3333-4444-555555555555")!
    static let ffsV2 = EFIGUID("8C8CE578-8A3D-4F1C-9935-896185C32DD3")!

    /// The image; `marker` goes into the PE32 body, so two dumps differ.
    static func image(marker: UInt8 = 0) -> Data {
        let pe32 = [UInt8]("MZ".utf8) + [UInt8](repeating: marker, count: 62)
        let section = le(UInt32(4 + pe32.count), 3) + [0x10] + pe32       // EFI_SECTION_PE32
        var file = driver.bytes + [0, 0xAA, 0x07, 0] + le(UInt32(0x18 + section.count), 3) + [0xF8]
        file[0x10] = 0 &- Checksums.sum8(file[0..<0x10] + file[0x12..<0x17])
        file += section

        let length = 0x1000
        var header = [UInt8](repeating: 0, count: 16) + ffsV2.bytes + le(UInt64(length), 8)
        header += le(UInt32(0x4856_465F), 4) + le(UInt32(0x0004_FEFF), 4)  // "_FVH", attributes
        header += le(UInt32(0x48), 2) + [0, 0] + [0, 0] + [0, 2]           // header length, checksum, ext, rev
        header += le(UInt32(1), 4) + le(UInt32(length), 4) + [UInt8](repeating: 0, count: 8)
        let checksum = Checksums.checksum16(header) ?? 0
        header[0x32] = UInt8(truncatingIfNeeded: checksum)
        header[0x33] = UInt8(truncatingIfNeeded: checksum >> 8)

        var volume = header + file
        volume += [UInt8](repeating: 0xFF, count: length - volume.count)
        return Data(volume)
    }

    private static func le<T: FixedWidthInteger>(_ value: T, _ count: Int) -> [UInt8] {
        (0..<count).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) }
    }
}
