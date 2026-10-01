import XCTest
@testable import UEFIImage

/// A JPEG picture outside every volume (`UEFI_IMAGE_FORMAT.md` §9): found by
/// its start, measured by walking its segments to the end marker.
final class JPEGPictureTests: XCTestCase {
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
        let picture = JPEGPicture.read(at: 1, limit: UInt64(bytes.count), in: ImageReader(bytes))
        XCTAssertEqual(picture, JPEGPicture(
            range: 1..<(1 + UInt64(Self.jpeg().count)), format: "JFIF", width: 800, height: 480
        ))
        XCTAssertEqual(picture?.name, "JPEG 800×480")
    }

    func testAnExifPictureIsOneToo() {
        let picture = JPEGPicture.read(at: 0, limit: 0x100, in: ImageReader(Self.jpeg(exif: true, width: 64, height: 32)
            + [UInt8](repeating: 0xFF, count: 0x80)))
        XCTAssertEqual(picture?.format, "Exif")
        XCTAssertEqual(picture?.name, "JPEG 64×32")
    }

    /// Without its end marker, or without the segment that names the format,
    /// what is there is not taken for a picture.
    func testAnythingLessIsNoPicture() {
        let cut = Self.jpeg(end: false)
        XCTAssertNil(JPEGPicture.read(at: 0, limit: UInt64(cut.count), in: ImageReader(cut)))
        var bare = Self.jpeg()
        bare.replaceSubrange(6..<10, with: Array("JFXX".utf8))
        XCTAssertNil(JPEGPicture.read(at: 0, limit: UInt64(bare.count), in: ImageReader(bare)))
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
}
