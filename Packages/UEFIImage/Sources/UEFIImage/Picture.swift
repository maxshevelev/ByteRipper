import Foundation

/// A picture kept in a firmware image (`UEFI_IMAGE_FORMAT.md` §9): a JPEG,
/// PNG, GIF or BMP — the boot logo, the setup screen's icons, a vendor's
/// splash. Found where the raw-area scan meets one outside every volume, and
/// as the body of a raw section, where most of them are.
///
/// Recognised by each format's own opening and taken only when its structure
/// can be read to its end, which is also what gives its length: a JPEG's
/// segments to the end marker, a PNG's chunks to `IEND`, a GIF's blocks to the
/// trailer, a BMP's header and the size it declares.
public struct Picture: Equatable, Sendable {
    public enum Format: UInt8, Equatable, Sendable, CaseIterable {
        case jpeg = 1
        case png
        case gif
        case bmp

        public var name: String {
            switch self {
            case .jpeg: return "JPEG"
            case .png: return "PNG"
            case .gif: return "GIF"
            case .bmp: return "BMP"
            }
        }

        /// What a file of this format is called, for a picture saved as one.
        public var fileExtension: String {
            switch self {
            case .jpeg: return "jpg"
            case .png: return "png"
            case .gif: return "gif"
            case .bmp: return "bmp"
            }
        }
    }

    public var format: Format
    public var range: Range<UInt64>
    /// What the format says of itself beyond its name: `JFIF` or `Exif`, the
    /// GIF version, a BMP's bits per pixel. Nil for a PNG.
    public var variant: String?
    public var width: UInt32
    public var height: UInt32
    /// A BMP that declares more bytes than the space holding it has. Its range
    /// is what there is; the bytes past it are missing from the image.
    public var declaredLength: UInt64?
    /// How many images a GIF holds — more than one is an animation. Nil for
    /// the other formats.
    public var frames: Int?

    public init(
        format: Format, range: Range<UInt64>, variant: String? = nil,
        width: UInt32, height: UInt32, declaredLength: UInt64? = nil, frames: Int? = nil
    ) {
        self.format = format
        self.range = range
        self.variant = variant
        self.width = width
        self.height = height
        self.declaredLength = declaredLength
        self.frames = frames
    }

    /// The format and the size in pixels, the same in every language.
    public var name: String { "\(format.name) \(width)×\(height)" }

    public var isTruncated: Bool { declaredLength != nil }

    /// How a format opens, as the scan reads a dword. A BMP opens with two
    /// bytes, `BM`, and the next two are its size's.
    static let jfifSignature: UInt32 = 0xE0FF_D8FF
    static let exifSignature: UInt32 = 0xE1FF_D8FF
    static let pngSignature: UInt32 = 0x474E_5089
    static let gifSignature: UInt32 = 0x3846_4947
    static let bmpSignature: UInt16 = 0x4D42

    /// Larger than any picture a firmware keeps: a walk past it is not one.
    static let largest: UInt64 = 0x100_0000
    static let largestSide: UInt32 = 0x4000
    static let maxBlocks = 0x1_0000

    /// The picture starting at `start` and ending at or before `limit`, or nil
    /// when what is there is not a whole one. `allowingTruncation` takes a BMP
    /// whose declared size runs past `limit` as far as `limit` — for the body
    /// of a raw section, which is the picture whether or not it is whole.
    public static func read(
        at start: UInt64, limit: UInt64, in reader: ImageReader, allowingTruncation: Bool = false
    ) -> Picture? {
        let end = min(limit, start + largest, reader.count)
        guard start + 16 <= end, let bytes = reader.bytes(start..<end) else { return nil }
        let found: Picture?
        switch (bytes[0], bytes[1], bytes[2]) {
        case (0xFF, 0xD8, 0xFF): found = jpeg(bytes)
        case (0x89, 0x50, 0x4E): found = png(bytes)
        case (0x47, 0x49, 0x46): found = gif(bytes)
        case (0x42, 0x4D, _): found = bmp(bytes, allowingTruncation: allowingTruncation)
        default: found = nil
        }
        guard var picture = found,
              picture.width > 0, picture.height > 0,
              picture.width <= largestSide, picture.height <= largestSide
        else { return nil }
        picture.range = (start + picture.range.lowerBound)..<(start + picture.range.upperBound)
        return picture
    }

    // MARK: - JPEG

    /// `FF D8 FF`, then an `APP0` `JFIF` or an `APP1` `Exif` segment; the
    /// segments walked to the end marker.
    private static func jpeg(_ bytes: [UInt8]) -> Picture? {
        let variant: String
        switch (bytes[3], Array(bytes[6..<11])) {
        case (0xE0, Array("JFIF".utf8) + [0]): variant = "JFIF"
        case (0xE1, Array("Exif".utf8) + [0]): variant = "Exif"
        default: return nil
        }

        var size: (width: UInt32, height: UInt32)?
        var at = 2
        for _ in 0..<maxBlocks {
            // A marker, after any number of fill bytes.
            guard at + 1 < bytes.count, bytes[at] == 0xFF else { return nil }
            while at + 1 < bytes.count, bytes[at + 1] == 0xFF { at += 1 }
            guard at + 1 < bytes.count else { return nil }
            let marker = bytes[at + 1]
            switch marker {
            case 0xD9:
                guard let size else { return nil }
                return Picture(format: .jpeg, range: 0..<UInt64(at + 2), variant: variant,
                               width: size.width, height: size.height)
            case 0x01, 0xD0...0xD7:
                at += 2
                continue
            default:
                break
            }
            guard at + 4 <= bytes.count else { return nil }
            let length = Int(bigEndian16(bytes, at + 2))
            guard length >= 2, at + 2 + length <= bytes.count else { return nil }
            // A start-of-frame segment: precision, then height and width.
            if (0xC0...0xCF).contains(marker), ![0xC4, 0xC8, 0xCC].contains(marker), length >= 7 {
                size = (UInt32(bigEndian16(bytes, at + 7)), UInt32(bigEndian16(bytes, at + 5)))
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

    // MARK: - PNG

    /// The eight-byte signature, `IHDR` first, then chunks — a big-endian
    /// length, a type, the data and a CRC — to `IEND`.
    private static func png(_ bytes: [UInt8]) -> Picture? {
        guard Array(bytes[0..<8]) == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A],
              bytes.count >= 33,
              bigEndian32(bytes, 8) == 13, Array(bytes[12..<16]) == Array("IHDR".utf8)
        else { return nil }
        let width = bigEndian32(bytes, 16)
        let height = bigEndian32(bytes, 20)
        var at = 8
        for _ in 0..<maxBlocks {
            guard at + 12 <= bytes.count else { return nil }
            let length = Int(bigEndian32(bytes, at))
            let type = Array(bytes[(at + 4)..<(at + 8)])
            guard length <= bytes.count - at - 12 else { return nil }
            at += 12 + length
            if type == Array("IEND".utf8) {
                return Picture(format: .png, range: 0..<UInt64(at), width: width, height: height)
            }
        }
        return nil
    }

    // MARK: - GIF

    /// `GIF87a` or `GIF89a`, the screen descriptor and its colour table, then
    /// extensions and images — each a run of sub-blocks ending in a zero — to
    /// the trailer.
    private static func gif(_ bytes: [UInt8]) -> Picture? {
        guard Array(bytes[0..<4]) == Array("GIF8".utf8), bytes[4] == 0x37 || bytes[4] == 0x39, bytes[5] == 0x61
        else { return nil }
        let width = UInt32(littleEndian16(bytes, 6))
        let height = UInt32(littleEndian16(bytes, 8))
        var at = 13 + colourTable(bytes[10])
        var frames = 0

        /// Steps over sub-blocks up to and past their terminating zero.
        func subBlocks() -> Bool {
            while at < bytes.count {
                let size = Int(bytes[at])
                at += 1 + size
                if size == 0 { return at <= bytes.count }
            }
            return false
        }

        for _ in 0..<maxBlocks {
            guard at < bytes.count else { return nil }
            switch bytes[at] {
            case 0x3B:
                return Picture(format: .gif, range: 0..<UInt64(at + 1), variant: String(decoding: bytes[3..<6], as: UTF8.self),
                               width: width, height: height, frames: frames)
            case 0x21:
                at += 2
                guard subBlocks() else { return nil }
            case 0x2C:
                guard at + 10 < bytes.count else { return nil }
                at += 10 + colourTable(bytes[at + 9]) + 1    // the LZW code size
                guard subBlocks() else { return nil }
                frames += 1
            default:
                return nil
            }
        }
        return nil
    }

    /// How many bytes the colour table a GIF's flags byte announces takes.
    private static func colourTable(_ flags: UInt8) -> Int {
        flags & 0x80 == 0 ? 0 : 3 << (Int(flags & 0x07) + 1)
    }

    // MARK: - BMP

    /// The file header — `BM`, the size, two reserved words, where the pixels
    /// start — then a DIB header of a size Windows defines, one plane and a
    /// depth it allows; an uncompressed one must hold the rows it says.
    private static func bmp(_ bytes: [UInt8], allowingTruncation: Bool) -> Picture? {
        guard bytes.count >= 30 else { return nil }
        let declared = UInt64(littleEndian32(bytes, 2))
        let pixels = UInt64(littleEndian32(bytes, 10))
        let dib = littleEndian32(bytes, 14)
        guard littleEndian32(bytes, 6) == 0,
              [12, 40, 52, 56, 64, 108, 124].contains(dib),
              pixels >= 14 + UInt64(dib), pixels < declared
        else { return nil }
        let width: UInt32
        let height: UInt32
        let bits: UInt16
        var compression: UInt32 = 0
        if dib == 12 {
            width = UInt32(littleEndian16(bytes, 18))
            height = UInt32(littleEndian16(bytes, 20))
            guard littleEndian16(bytes, 22) == 1 else { return nil }
            bits = littleEndian16(bytes, 24)
        } else {
            guard bytes.count >= 34 else { return nil }
            let signedWidth = Int32(bitPattern: littleEndian32(bytes, 18))
            let signedHeight = Int32(bitPattern: littleEndian32(bytes, 22))
            guard signedWidth > 0, signedHeight != 0, signedHeight != .min, littleEndian16(bytes, 26) == 1
            else { return nil }
            width = UInt32(signedWidth)
            height = signedHeight.magnitude
            bits = littleEndian16(bytes, 28)
            compression = littleEndian32(bytes, 30)
        }
        guard [1, 2, 4, 8, 16, 24, 32].contains(bits), compression <= 6 else { return nil }
        // Uncompressed rows are padded to four bytes: the size has to hold them.
        if compression == 0 {
            let row = (UInt64(width) * UInt64(bits) + 31) / 32 * 4
            guard pixels + row * UInt64(height) <= declared else { return nil }
        }
        let available = UInt64(bytes.count)
        if declared <= available {
            return Picture(format: .bmp, range: 0..<declared, variant: "\(bits)-bit", width: width, height: height)
        }
        guard allowingTruncation, pixels < available else { return nil }
        return Picture(format: .bmp, range: 0..<available, variant: "\(bits)-bit",
                       width: width, height: height, declaredLength: declared)
    }

    // MARK: - Fields

    private static func bigEndian16(_ bytes: [UInt8], _ at: Int) -> UInt16 {
        UInt16(bytes[at]) << 8 | UInt16(bytes[at + 1])
    }

    private static func bigEndian32(_ bytes: [UInt8], _ at: Int) -> UInt32 {
        UInt32(bytes[at]) << 24 | UInt32(bytes[at + 1]) << 16 | UInt32(bytes[at + 2]) << 8 | UInt32(bytes[at + 3])
    }

    private static func littleEndian16(_ bytes: [UInt8], _ at: Int) -> UInt16 {
        UInt16(bytes[at]) | UInt16(bytes[at + 1]) << 8
    }

    private static func littleEndian32(_ bytes: [UInt8], _ at: Int) -> UInt32 {
        UInt32(bytes[at]) | UInt32(bytes[at + 1]) << 8 | UInt32(bytes[at + 2]) << 16 | UInt32(bytes[at + 3]) << 24
    }
}

extension Parser {
    /// A picture, as the raw-area scan's element: padding to UEFITool, which
    /// does not look for one.
    func parsePicture(at offset: UInt64, limit: UInt64) -> UEFINode? {
        Picture.read(at: offset, limit: limit, in: reader).map(pictureNode)
    }

    /// A raw section's body read as the picture it starts with — the way
    /// nearly every logo and icon is kept — and whatever follows it as
    /// padding; nil when it does not start with one.
    func pictureBody(_ body: Range<UInt64>, emptyByte: UInt8) -> [UEFINode]? {
        guard let picture = Picture.read(at: body.lowerBound, limit: body.upperBound, in: reader,
                                         allowingTruncation: true)
        else { return nil }
        return [pictureNode(picture)] + padding(from: picture.range.upperBound, to: body.upperBound, emptyByte: emptyByte)
    }

    private func pictureNode(_ picture: Picture) -> UEFINode {
        UEFINode(
            kind: .picture,
            subtype: picture.format.rawValue,
            name: picture.name,
            header: picture.range.lowerBound..<picture.range.lowerBound,
            body: picture.range
        )
    }
}
