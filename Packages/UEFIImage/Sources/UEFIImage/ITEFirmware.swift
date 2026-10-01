import Foundation

/// The identification an ITE embedded controller's firmware carries near its
/// start (`UEFI_IMAGE_FORMAT.md` §9): a signature block and the string after
/// it, such as `ITE8380-EC-V1.43`.
///
/// No datasheet describes it. The layout is what seven dumps agree on: at
/// `+0x40` (the 8051 parts) or `+0x80`, six `A5` bytes, two bytes that vary,
/// `85 12 5A 5A AA`, one byte that varies, `55 55`; then up to sixteen bytes
/// of text. What the string names is what the firmware's author wrote into
/// it — the chip the image was built for, which is not always the chip on the
/// board.
///
/// Public because the details panel shows it beside the name.
public struct ITEFirmware: Equatable, Sendable {
    /// The string, as written, with trailing spaces and NULs dropped.
    public var identification: String
    /// Where the image starts: the identification is read relative to it.
    public var start: UInt64
    /// Where the signature block starts, relative to the image.
    public var signatureOffset: UInt64

    /// The start of the name a padding row gets when it opens on an ITE
    /// image, which the help lookup keys on as well.
    public static let paddingNamePrefix = "EC firmware ("

    static let candidates: [UInt64] = [0x40, 0x80]
    static let blockSize: UInt64 = 0x10
    static let identificationSize: UInt64 = 0x10

    /// The identification of an image starting at `start`, or nil when no
    /// signature block is where one would be.
    public static func read(at start: UInt64, limit: UInt64, in reader: ImageReader) -> ITEFirmware? {
        for offset in candidates {
            let at = start + offset
            guard at + blockSize + identificationSize <= limit,
                  let block = reader.bytes(at: at, count: blockSize),
                  isSignature(block),
                  let text = reader.bytes(at: at + blockSize, count: identificationSize)
            else { continue }
            let printable = text.prefix { (0x20..<0x7F).contains($0) }
            let identification = String(decoding: printable, as: UTF8.self)
                .trimmingCharacters(in: .whitespaces)
            guard !identification.isEmpty else { continue }
            return ITEFirmware(identification: identification, start: start, signatureOffset: offset)
        }
        return nil
    }

    /// Every ITE image in `range`, at each 4 KiB boundary — a region can hold
    /// more than one: an EC image and a second controller's, or two copies.
    public static func all(in range: Range<UInt64>, reader: ImageReader) -> [ITEFirmware] {
        var found: [ITEFirmware] = []
        var start = range.lowerBound
        while start < range.upperBound {
            if let image = read(at: start, limit: range.upperBound, in: reader) { found.append(image) }
            start += 0x1000
        }
        return found
    }

    static func isSignature(_ block: [UInt8]) -> Bool {
        block.count == Int(blockSize)
            && block[0..<6].allSatisfy { $0 == 0xA5 }
            && Array(block[8..<13]) == [0x85, 0x12, 0x5A, 0x5A, 0xAA]
            && block[14] == 0x55 && block[15] == 0x55
    }
}
