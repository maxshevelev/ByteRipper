import LenovoDMI
import Localization
import PartCodec
import UEFIContentSource
import UEFIImage
import XCTest
@testable import ByteRipper

/// Every codec a part can be opened with is written down and read back as
/// itself, so a restored part goes back into its parent the way it came out.
final class PartCodecStateTests: XCTestCase {
    private func roundTrip(_ codec: any PartCodec) throws -> PartCodecState {
        let state = try XCTUnwrap(PartCodecState(codec))
        let text = try XCTUnwrap(PartCodecState.text(state))
        let back = try XCTUnwrap(PartCodecState.value(PartCodecState.self, from: text))
        XCTAssertEqual(back, state)
        XCTAssertEqual(PartCodecState(back.codec), state)
        return back
    }

    func testEveryCodecReadsBackAsItself() throws {
        XCTAssertEqual(try roundTrip(CopyPartCodec()), .copy)
        _ = try roundTrip(ReadOnlyPartCodec([1, 2, 3], title: .verbatim("t"), reason: .verbatim("r")))
        _ = try roundTrip(UEFIPartCodec(target: UEFIRebuild.Target(space: .decompressed(chain: [0x100, 0x20]),
                                                                   range: 0x10..<0x80),
                                        compression: "LZMA"))
        XCTAssertEqual(try roundTrip(LenovoDMIBlockCodec(encodes: true, key: 0x77)),
                       .lenovoDMI(encodes: true, key: 0x77))
    }

    func testALayoutReadsBackAsItself() throws {
        for layout: UEFIRootLayout in [.image, .volume, .file(ffsVersion: 3, volumeRevision: 2),
                                       .sections(ffsVersion: 2), .nvramStores] {
            let text = try XCTUnwrap(PartCodecState.text(layout))
            XCTAssertEqual(PartCodecState.value(UEFIRootLayout.self, from: text), layout)
        }
    }
}
