import XCTest
@testable import UEFIImage

/// A picture in a firmware image (`UEFI_IMAGE_FORMAT.md` §9) — JPEG, PNG,
/// GIF or BMP: found by its start, measured by reading it through to its end,
/// in padding and as the body of a raw section.
final class PictureTests: XCTestCase {
    /// A small but well-formed JPEG: the opening segment, a frame of
    /// `width`×`height`, a scan whose data holds a stuffed `FF 00` and a
    /// restart marker, and the end marker.
    static func jpeg(exif: Bool = false, width: UInt16 = 800, height: UInt16 = 480, end: Bool = true) -> [UInt8] {
        var bytes: [UInt8] = [0xFF, 0xD8]
        if exif {
            bytes += [0xFF, 0xE1, 0x00, 0x08] + Array("Exif".utf8) + [0, 0]
        } else {
            bytes += [0xFF, 0xE0, 0x00, 0x10] + Array("JFIF".utf8) + [0, 1, 1, 0, 0, 1, 0, 1, 0, 0]
        }
        bytes += [0xFF, 0xFF]                                 // fill
        bytes += [0xFF, 0xC0, 0x00, 0x11, 0x08]
        bytes += [UInt8(height >> 8), UInt8(height & 0xFF), UInt8(width >> 8), UInt8(width & 0xFF)]
        bytes += [0x03, 1, 0x22, 0, 2, 0x11, 1, 3, 0x11, 1]
        bytes += [0xFF, 0xDA, 0x00, 0x0C, 0x03, 1, 0, 2, 0x11, 3, 0x11, 0, 0x3F, 0]
        bytes += [0x12, 0xFF, 0x00, 0x34, 0xFF, 0xD0, 0x56, 0x78]
        if end { bytes += [0xFF, 0xD9] }
        return bytes
    }

    func testAPictureIsReadToItsEndMarker() {
        let bytes = [0x00] + Self.jpeg() + [UInt8](repeating: 0xFF, count: 32)
        let picture = Picture.read(at: 1, limit: UInt64(bytes.count), in: ImageReader(bytes))
        XCTAssertEqual(picture, Picture(
            format: .jpeg, range: 1..<(1 + UInt64(Self.jpeg().count)), variant: "JFIF", width: 800, height: 480
        ))
        XCTAssertEqual(picture?.name, "JPEG 800×480")
    }

    func testAnExifPictureIsOneToo() {
        let picture = Picture.read(at: 0, limit: 0x100, in: ImageReader(Self.jpeg(exif: true, width: 64, height: 32)
            + [UInt8](repeating: 0xFF, count: 0x80)))
        XCTAssertEqual(picture?.variant, "Exif")
        XCTAssertEqual(picture?.name, "JPEG 64×32")
    }

    /// Without its end marker, or without the segment that names the format,
    /// what is there is not taken for a picture.
    func testAnythingLessIsNoPicture() {
        let cut = Self.jpeg(end: false)
        XCTAssertNil(Picture.read(at: 0, limit: UInt64(cut.count), in: ImageReader(cut)))
        var bare = Self.jpeg()
        bare.replaceSubrange(6..<10, with: Array("JFXX".utf8))
        XCTAssertNil(Picture.read(at: 0, limit: UInt64(bare.count), in: ImageReader(bare)))
    }

    /// In a raw area the picture is a row of its own, and the padding around
    /// it stays.
    func testTheScanFindsAPictureInPadding() {
        var bytes = [UInt8](repeating: 0xFF, count: 0x4000)
        let picture = Self.jpeg()
        bytes.replaceSubrange(0x1000..<(0x1000 + picture.count), with: picture)
        let parsed = UEFIParser.parse(bytes, readsProtectedRanges: false)
        let nodes = parsed.roots[0].children

        XCTAssertEqual(nodes.map(\.kind), [.padding, .picture, .padding])
        XCTAssertEqual(nodes[1].name, "JPEG 800×480")
        XCTAssertEqual(nodes[1].range, 0x1000..<(0x1000 + UInt64(picture.count)))
        XCTAssertEqual(nodes[1].uefiItemType, UEFITypes.Item.padding.rawValue)
        XCTAssertTrue(parsed.diagnostics.isEmpty, "\(parsed.diagnostics)")
    }

    // MARK: - PNG, GIF, BMP

    /// `IHDR` for `width`×`height`, one `IDAT`, `IEND`; the CRCs are not
    /// checked, and are zero.
    static func png(width: UInt32 = 16, height: UInt32 = 8, end: Bool = true) -> [UInt8] {
        func be(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
        func chunk(_ type: String, _ data: [UInt8]) -> [UInt8] { be(UInt32(data.count)) + Array(type.utf8) + data + [0, 0, 0, 0] }
        var bytes: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        bytes += chunk("IHDR", be(width) + be(height) + [8, 0, 0, 0, 0])
        bytes += chunk("IDAT", [0x78, 0x9C, 0x63, 0x00, 0x00, 0x00, 0x01, 0x00, 0x01])
        if end { bytes += chunk("IEND", []) }
        return bytes
    }

    /// A GIF89a with a two-colour table, then `frames` times a graphic control
    /// extension and an image of one sub-block, and the trailer.
    static func gif(width: UInt16 = 10, height: UInt16 = 4, frames: Int = 1, end: Bool = true) -> [UInt8] {
        var bytes = Array("GIF89a".utf8)
        bytes += [UInt8(width & 0xFF), UInt8(width >> 8), UInt8(height & 0xFF), UInt8(height >> 8)]
        bytes += [0x80, 0, 0] + [0, 0, 0, 0xFF, 0xFF, 0xFF]
        for _ in 0..<frames {
            bytes += [0x21, 0xF9, 0x04, 0, 0x04, 0, 0, 0x00]
            bytes += [0x2C, 0, 0, 0, 0, UInt8(width & 0xFF), UInt8(width >> 8), UInt8(height & 0xFF), UInt8(height >> 8), 0]
            bytes += [0x02, 0x02, 0x44, 0x01, 0x00]
        }
        if end { bytes += [0x3B] }
        return bytes
    }

    /// An animation is the same GIF with more images in it: read through all
    /// of them, and counted — ASUS's boot logo has 34.
    func testAnAnimatedGIFCountsItsFrames() {
        let animated = Self.gif(frames: 34)
        let picture = Picture.read(at: 0, limit: UInt64(animated.count), in: ImageReader(animated))
        XCTAssertEqual(picture?.frames, 34)
        XCTAssertEqual(picture?.range, 0..<UInt64(animated.count))
        XCTAssertEqual(Picture.read(at: 0, limit: 0x100, in: ImageReader(Self.gif() + [UInt8](repeating: 0, count: 0x100)))?.frames, 1)
        XCTAssertNil(Picture.read(at: 0, limit: 0x100, in: ImageReader(Self.png() + [UInt8](repeating: 0, count: 0x100)))?.frames)
    }

    /// An uncompressed 24-bit BMP, `width`×`height`, its rows padded to four
    /// bytes; `declared` overrides the size its header gives.
    static func bmp(width: Int32 = 3, height: Int32 = 2, declared: UInt32? = nil, dib: UInt32 = 40) -> [UInt8] {
        let row = (Int(width) * 24 + 31) / 32 * 4
        let pixels = row * Int(height.magnitude)
        var w = BinaryWriter()
        w.u16(0x4D42)
        w.u32(declared ?? UInt32(54 + pixels))
        w.u32(0)
        w.u32(54)
        w.u32(dib)
        w.u32(UInt32(bitPattern: width)); w.u32(UInt32(bitPattern: height))
        w.u16(1); w.u16(24)
        w.u32(0); w.u32(UInt32(pixels)); w.u32(2835); w.u32(2835); w.u32(0); w.u32(0)
        w.fill(UInt64(pixels), with: 0x7F)
        return w.bytes
    }

    func testEachFormatIsReadThroughToItsEnd() {
        for (bytes, name, variant) in [
            (Self.png(), "PNG 16×8", nil),
            (Self.gif(), "GIF 10×4", "89a"),
            (Self.bmp(), "BMP 3×2", "24-bit"),
            (Self.bmp(height: -2), "BMP 3×2", "24-bit"),
        ] as [([UInt8], String, String?)] {
            let padded = bytes + [UInt8](repeating: 0xAB, count: 0x40)
            let picture = Picture.read(at: 0, limit: UInt64(padded.count), in: ImageReader(padded))
            XCTAssertEqual(picture?.name, name)
            XCTAssertEqual(picture?.variant, variant)
            XCTAssertEqual(picture?.range, 0..<UInt64(bytes.count), name)
            XCTAssertFalse(picture?.isTruncated ?? true)
        }
    }

    func testAPictureThatDoesNotReadToItsEndIsNone() {
        for bytes in [Self.png(end: false), Self.gif(end: false), Self.bmp(dib: 41), Self.bmp(declared: 60)] {
            let padded = bytes + [UInt8](repeating: 0xFF, count: 0x40)
            XCTAssertNil(Picture.read(at: 0, limit: UInt64(padded.count), in: ImageReader(padded)), "\(bytes.prefix(4))")
        }
    }

    /// A BMP that declares more than its section holds is the section's
    /// picture as far as it goes — and only there.
    func testABMPCutShortIsTakenOnlyWhenAskedTo() {
        let bytes = Array(Self.bmp().dropLast(4))
        let reader = ImageReader(bytes)
        XCTAssertNil(Picture.read(at: 0, limit: UInt64(bytes.count), in: reader))
        let cut = Picture.read(at: 0, limit: UInt64(bytes.count), in: reader, allowingTruncation: true)
        XCTAssertEqual(cut?.range, 0..<UInt64(bytes.count))
        XCTAssertEqual(cut?.declaredLength, UInt64(bytes.count + 4))
    }

    func testTheScanFindsEveryFormatInPadding() {
        var bytes = [UInt8](repeating: 0xFF, count: 0x4000)
        for (at, picture) in [(0x1000, Self.png()), (0x2000, Self.gif()), (0x3000, Self.bmp())] {
            bytes.replaceSubrange(at..<(at + picture.count), with: picture)
        }
        let parsed = UEFIParser.parse(bytes, readsProtectedRanges: false)
        let pictures = parsed.roots[0].children.filter { $0.kind == .picture }
        XCTAssertEqual(pictures.map(\.name), ["PNG 16×8", "GIF 10×4", "BMP 3×2"])
        XCTAssertEqual(pictures.map(\.subtype), [Picture.Format.png, .gif, .bmp].map(\.rawValue))
        XCTAssertTrue(parsed.diagnostics.isEmpty, "\(parsed.diagnostics)")
    }

    /// Where nearly every logo is: a raw section's body. The picture is the
    /// section's child, and bytes after it stay padding.
    func testARawSectionsBodyIsReadAsItsPicture() {
        let body = Self.bmp() + [UInt8](repeating: 0xFF, count: 6)
        let volume = TestNVAR.volume(sections: [TestImage.section(type: Section.raw, body: body)])
        let parsed = UEFIParser.parse(volume, readsProtectedRanges: false)
        let section = parsed.allNodes.first { $0.kind == .section && $0.subtype == Section.raw }!
        XCTAssertEqual(section.children.map(\.kind), [.picture, .padding])
        XCTAssertEqual(section.children[0].name, "BMP 3×2")
        XCTAssertEqual(section.children[0].range.lowerBound, section.body.lowerBound)
        XCTAssertEqual(section.children[1].range.upperBound, section.body.upperBound)
        XCTAssertTrue(parsed.diagnostics.isEmpty, "\(parsed.diagnostics)")
    }
}
