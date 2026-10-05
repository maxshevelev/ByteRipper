import HelpBook
import UEFIImage
import XCTest
@testable import UEFITool

/// A sound row: its details read it again, the panel is handed the WAV to
/// play, `?` opens the sound entry, and saving it offers a `.wav`.
final class SoundDisplayTests: XCTestCase {
    /// Half a second of 16-bit stereo silence at 8000 Hz.
    private static let wav: [UInt8] = {
        let frames = 4000
        let data = frames * 4
        func u32(_ value: Int) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) } }
        func u16(_ value: Int) -> [UInt8] { (0..<2).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) } }
        return Array("RIFF".utf8) + u32(4 + 8 + 16 + 8 + data) + Array("WAVEfmt ".utf8) + u32(16)
            + u16(1) + u16(2) + u32(8000) + u32(8000 * 4) + u16(4) + u16(16)
            + Array("data".utf8) + u32(data) + [UInt8](repeating: 0, count: data)
    }()

    private func built() -> (UEFIImage, ImageReader) {
        var bytes = [UInt8](repeating: 0xFF, count: 0x8000)
        bytes.replaceSubrange(0x100..<(0x100 + Self.wav.count), with: Self.wav)
        let sound = UEFINode(kind: .sound, name: "WAV, 8000 Hz, stereo",
                             header: 0x100..<0x100,
                             body: 0x100..<(0x100 + UInt64(Self.wav.count)))
        let root = UEFINode(kind: .uefiImage, name: "UEFI image", header: 0..<0, body: 0..<0x8000,
                            children: [sound])
        return (UEFIImage(size: 0x8000, roots: [root]), ImageReader(bytes))
    }

    func testTheDetailsSayWhatTheSoundIs() {
        let (image, reader) = built()
        let detail = UEFIDetail.build(for: image.roots[0].children[0], image: image, reader: reader)
        let fields = Dictionary(detail.fields.map { ($0.label, $0.value) }, uniquingKeysWith: { first, _ in first })
        XCTAssertEqual(fields["Kind"], "Sound")
        XCTAssertEqual(fields["Format"], "WAV (PCM)")
        XCTAssertEqual(fields["Sample rate"], "8000 Hz")
        XCTAssertEqual(fields["Bits per sample"], "16")
        XCTAssertEqual(fields["Channels"], "2")
        XCTAssertEqual(fields["Duration"], "0.5 s")
    }

    /// The panel is handed the whole WAV to play, and only a sound's.
    func testTheSoundIsHandedToThePanel() {
        let (image, reader) = built()
        XCTAssertEqual(UEFIDetail.build(for: image.roots[0].children[0], image: image, reader: reader).sound, Self.wav)
        XCTAssertNil(UEFIDetail.build(for: image.roots[0], image: image, reader: reader).sound)
    }

    func testItOpensItsEntryAndSavesAsAWAV() {
        let (image, _) = built()
        let node = image.roots[0].children[0]
        XCTAssertEqual(UEFIHelpTerms.term(for: node), HelpTermID("sound"))
        XCTAssertEqual(UEFIPresenter.nodeOpen(for: node, in: image, body: false)?.suggestedName,
                       "WAV, 8000 Hz, stereo.wav")
    }
}
