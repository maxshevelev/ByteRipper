import XCTest
@testable import ToolModuleKit

/// The repair a published map goes through before the dump draws it
/// (`ZoneMap.normalized(contentSize:)`).
final class ZoneMapTests: XCTestCase {
    private func zone(_ id: String, _ range: Range<UInt64>) -> Zone {
        Zone(id: id, name: id, range: range)
    }

    /// A map is always one re-read behind the file it describes, and the
    /// ordinary way it disagrees is an edit that shortened the content. What is
    /// left of the zone is still worth drawing.
    func testAZoneReachingPastTheEndIsCutToTheEnd() {
        let map = ZoneMap(zones: [zone("fv", 0x100..<0x400)])

        let drawn = map.normalized(contentSize: 0x280)

        XCTAssertEqual(drawn.zones.map(\.range), [0x100..<0x280])
    }

    func testAZoneStartingPastTheEndIsDropped() {
        let map = ZoneMap(zones: [zone("gone", 0x400..<0x500), zone("here", 0..<0x10)])

        let drawn = map.normalized(contentSize: 0x100)

        XCTAssertEqual(drawn.zones.map(\.id), ["here"])
    }

    /// A zone is a stretch. A stretch of no bytes is a mark, and marks are
    /// bookmarks (§20).
    func testAnEmptyZoneIsDropped() {
        let map = ZoneMap(zones: [zone("point", 0x40..<0x40)])

        XCTAssertTrue(map.normalized(contentSize: 0x100).zones.isEmpty)
    }

    /// The focus names a zone by id, so two zones may not answer to one id.
    func testARepeatedIdKeepsTheFirstOne() {
        let map = ZoneMap(zones: [zone("dup", 0..<0x10), zone("dup", 0x20..<0x30)])

        let drawn = map.normalized(contentSize: 0x100)

        XCTAssertEqual(drawn.zones.count, 1)
        XCTAssertEqual(drawn.zones.first?.range, 0..<0x10)
    }

    func testAFocusThatSurvivesIsKept() {
        let map = ZoneMap(zones: [zone("a", 0..<0x10)], focus: "a")

        XCTAssertEqual(map.normalized(contentSize: 0x100).focus, "a")
    }

    /// The zone the focus named was dropped by the repair above it, so the
    /// focus has to go with it rather than point at nothing.
    func testAFocusOnAZoneThatWentAwayIsCleared() {
        let map = ZoneMap(zones: [zone("gone", 0x400..<0x500)], focus: "gone")

        XCTAssertNil(map.normalized(contentSize: 0x100).focus)
    }

    /// Nesting is what a parse produces — a volume holds files hold sections —
    /// so overlap is not an error, and the containing zone is drawn first.
    func testNestedZonesSurviveAndTheOuterOneIsDrawnFirst() {
        let map = ZoneMap(zones: [zone("section", 0x100..<0x180),
                                  zone("volume", 0x100..<0x400)])

        let drawn = map.normalized(contentSize: 0x1000)

        XCTAssertEqual(drawn.zones.map(\.id), ["volume", "section"])
    }

    /// Whatever order a tool-module emits its slice in, the dump draws the same
    /// map — so a rebuild that happens to enumerate a tree differently does not
    /// redraw everything.
    func testTheResultDoesNotDependOnTheOrderItArrivedIn() {
        let zones = [zone("c", 0x200..<0x300), zone("a", 0..<0x100), zone("b", 0x100..<0x200)]

        let forwards = ZoneMap(zones: zones).normalized(contentSize: 0x1000)
        let backwards = ZoneMap(zones: zones.reversed()).normalized(contentSize: 0x1000)

        XCTAssertEqual(forwards, backwards)
        XCTAssertEqual(forwards.zones.map(\.id), ["a", "b", "c"])
    }

    /// What a click in the dump will resolve to: every zone over that byte,
    /// outermost first.
    func testTheZonesOverAByteAreListedOutermostFirst() {
        let map = ZoneMap(zones: [zone("volume", 0x100..<0x400),
                                  zone("file", 0x100..<0x180),
                                  zone("elsewhere", 0x500..<0x600)])
            .normalized(contentSize: 0x1000)

        XCTAssertEqual(map.zones(containing: 0x120).map(\.id), ["volume", "file"])
        XCTAssertEqual(map.zones(containing: 0x200).map(\.id), ["volume"])
        XCTAssertTrue(map.zones(containing: 0x450).isEmpty)
    }

    // MARK: - Zones in fragments (#31)

    /// A file the firmware scattered: three chunks, the second stored before
    /// the first, a CRC between each.
    private let file = Zone(id: "file", name: "file",
                            ranges: [0x200..<0x240, 0x100..<0x140, 0x300..<0x340])

    /// The stretches keep the owner's order; the span orders the zone among the
    /// others, and the start is the first stretch's — not the lowest address.
    func testAScatteredZoneKeepsItsOrderAndIsPlacedByItsSpan() {
        let map = ZoneMap(zones: [zone("later", 0x180..<0x190), file])
            .normalized(contentSize: 0x1000)

        XCTAssertEqual(map.zones.map(\.id), ["file", "later"])
        XCTAssertEqual(map.zones[0].ranges, file.ranges)
        XCTAssertEqual(map.zones[0].range, 0x100..<0x340)
        XCTAssertEqual(map.zones[0].start, 0x200)
        XCTAssertTrue(map.zones[0].isScattered)
        XCTAssertFalse(zone("one", 0..<4).isScattered)
    }

    /// The gap between two chunks is not the file.
    func testAByteBetweenTwoStretchesIsNotInTheZone() {
        let map = ZoneMap(zones: [file]).normalized(contentSize: 0x1000)

        XCTAssertEqual(map.zones(containing: 0x120).map(\.id), ["file"])
        XCTAssertEqual(map.zones(containing: 0x33F).map(\.id), ["file"])
        XCTAssertTrue(map.zones(containing: 0x140).isEmpty, "the CRC after a chunk")
        XCTAssertTrue(map.zones(containing: 0x280).isEmpty)
        XCTAssertEqual(file.stretch(containing: 0x210), 0x200..<0x240)
        XCTAssertNil(file.stretch(containing: 0x250))
    }

    /// Each stretch is repaired as a zone of one would be, and a zone with
    /// nothing left is gone.
    func testEachStretchIsClampedOrDropped() {
        let map = ZoneMap(zones: [file], focus: "file").normalized(contentSize: 0x220)

        XCTAssertEqual(map.zones.first?.ranges, [0x200..<0x220, 0x100..<0x140])
        XCTAssertEqual(map.focus, "file")

        let gone = ZoneMap(zones: [file], focus: "file").normalized(contentSize: 0x80)
        XCTAssertTrue(gone.zones.isEmpty)
        XCTAssertNil(gone.focus)
    }
}
