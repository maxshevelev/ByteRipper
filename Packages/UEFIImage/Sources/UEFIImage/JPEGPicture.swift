import Foundation

/// A JPEG picture the raw-area scan finds outside every volume
/// (`UEFI_IMAGE_FORMAT.md` §9) — on the HP ZBook Fury 16 G9 dump an 800×480
/// JFIF in the padding after the FFSv3 volume, the boot logo presumably.
///
/// Recognised by the start of the file — `FF D8 FF`, then an `APP0` `JFIF` or
/// an `APP1` `Exif` segment — and taken only when its segments can be walked
/// to the end marker, which is also what gives its length: nothing in a JPEG
/// says how long it is.
public struct JPEGPicture: Equatable, Sendable {
    public var range: Range<UInt64>
    /// `JFIF` or `Exif`: the segment the picture opens with.
    public var format: String
    public var width: UInt16
    public var height: UInt16

    /// The format and the size in pixels, the same in every language.
    public var name: String { "JPEG \(width)×\(height)" }

    /// `FF D8 FF E0` and `FF D8 FF E1`, as the scan reads a dword.
    static let jfifSignature: UInt32 = 0xE0FF_D8FF
    static let exifSignature: UInt32 = 0xE1FF_D8FF
    /// Larger than any boot logo: a walk past it is not one picture.
    static let largest: UInt64 = 0x100_0000
    static let maxSegments = 4096

    /// The picture starting at `start` and ending at or before `limit`, or nil
    /// when what is there is not a whole one.
    public static func read(at start: UInt64, limit: UInt64, in reader: ImageReader) -> JPEGPicture? {
        let end = min(limit, start + largest, reader.count)
        guard start + 11 <= end,
              let bytes = reader.bytes(start..<end),
              bytes[0] == 0xFF, bytes[1] == 0xD8, bytes[2] == 0xFF
        else { return nil }
        let format: String
        switch (bytes[3], Array(bytes[6..<11])) {
        case (0xE0, Array("JFIF".utf8) + [0]): format = "JFIF"
        case (0xE1, Array("Exif".utf8) + [0]): format = "Exif"
        default: return nil
        }

        var size: (width: UInt16, height: UInt16)?
        var at = 2
        for _ in 0..<maxSegments {
            // A marker, after any number of fill bytes.
            guard at + 1 < bytes.count, bytes[at] == 0xFF else { return nil }
            while at + 1 < bytes.count, bytes[at + 1] == 0xFF { at += 1 }
            guard at + 1 < bytes.count else { return nil }
            let marker = bytes[at + 1]
            switch marker {
            case 0xD9:
                guard let size, size.width > 0, size.height > 0 else { return nil }
                return JPEGPicture(
                    range: start..<(start + UInt64(at + 2)), format: format, width: size.width, height: size.height
                )
            case 0x01, 0xD0...0xD7:
                at += 2
                continue
            default:
                break
            }
            guard at + 4 <= bytes.count else { return nil }
            let length = Int(bytes[at + 2]) << 8 | Int(bytes[at + 3])
            guard length >= 2, at + 2 + length <= bytes.count else { return nil }
            // A start-of-frame segment: precision, then height and width.
            if (0xC0...0xCF).contains(marker), ![0xC4, 0xC8, 0xCC].contains(marker), length >= 7 {
                size = (
                    UInt16(bytes[at + 7]) << 8 | UInt16(bytes[at + 8]),
                    UInt16(bytes[at + 5]) << 8 | UInt16(bytes[at + 6])
                )
            }
            at += 2 + length
            // After a start of scan, the coded data runs to the next marker
            // that is neither a stuffed `FF 00` nor a restart.
            if marker == 0xDA {
                while at + 1 < bytes.count,
                      !(bytes[at] == 0xFF && bytes[at + 1] != 0x00 && !(0xD0...0xD7).contains(bytes[at + 1])) {
                    at += 1
                }
            }
        }
        return nil
    }
}

extension Parser {
    /// A picture, as the raw-area scan's element: padding to UEFITool, which
    /// does not look for one.
    func parsePicture(at offset: UInt64, limit: UInt64) -> UEFINode? {
        guard let picture = JPEGPicture.read(at: offset, limit: limit, in: reader) else { return nil }
        return UEFINode(
            kind: .picture,
            name: picture.name,
            header: offset..<offset,
            body: picture.range
        )
    }
}
