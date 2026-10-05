import XCTest
import AppKit
@testable import UEFIToolUI

/// The player a sound row puts under its details: it plays and pauses, stops
/// back at the start, moves where the bar is dragged, and stops when it leaves
/// the window.
@MainActor
final class SoundPlayerViewTests: XCTestCase {
    /// Two seconds of 16-bit stereo silence at 8000 Hz — nothing to hear while
    /// the suite runs.
    private static let wav: [UInt8] = {
        let data = 2 * 8000 * 4
        func u32(_ value: Int) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) } }
        func u16(_ value: Int) -> [UInt8] { (0..<2).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) } }
        return Array("RIFF".utf8) + u32(4 + 8 + 16 + 8 + data) + Array("WAVEfmt ".utf8) + u32(16)
            + u16(1) + u16(2) + u32(8000) + u32(8000 * 4) + u16(4) + u16(16)
            + Array("data".utf8) + u32(data) + [UInt8](repeating: 0, count: data)
    }()

    func testItPlaysPausesAndStopsBackAtTheStart() throws {
        let player = try XCTUnwrap(SoundPlayerView(wav: Self.wav))
        XCTAssertFalse(player.isPlaying)

        player.playOrPause()
        XCTAssertTrue(player.isPlaying)
        player.playOrPause()
        XCTAssertFalse(player.isPlaying, "the same button pauses")

        player.playOrPause()
        player.stop()
        XCTAssertFalse(player.isPlaying)
        XCTAssertEqual(player.position, 0, accuracy: 0.001, "stop goes back to the start")
    }

    /// Another row selected takes the player out of the window: a sound left
    /// playing for a row nobody sees is one nobody can find to stop.
    func testLeavingTheWindowStopsIt() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 60),
                              styleMask: [.titled], backing: .buffered, defer: true)
        let player = try XCTUnwrap(SoundPlayerView(wav: Self.wav))
        window.contentView?.addSubview(player)
        player.playOrPause()
        XCTAssertTrue(player.isPlaying)

        player.removeFromSuperview()

        XCTAssertFalse(player.isPlaying)
    }

    func testBytesThatAreNoSoundGiveNoPlayer() {
        XCTAssertNil(SoundPlayerView(wav: [UInt8](repeating: 0x5A, count: 256)))
    }

    func testTheClockReadsAsAPlayersDoes() {
        XCTAssertEqual(SoundPlayerView.clock(0), "0:00")
        XCTAssertEqual(SoundPlayerView.clock(4.97), "0:04")
        XCTAssertEqual(SoundPlayerView.clock(61), "1:01")
    }
}
