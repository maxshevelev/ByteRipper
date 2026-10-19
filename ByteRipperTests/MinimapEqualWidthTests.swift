import XCTest
import ToolModuleKit
@testable import ByteRipper

/// § 19.4: in a comparison the two maps' byte areas are the same width, whatever
/// the zone gutter and the segment strip take beside one of them, so a byte
/// column is the same column on both maps.
@MainActor
final class MinimapEqualWidthTests: XCTestCase {
    /// Two maps with the legends on different sides: zones on the first, a
    /// partition (and so a strip) on the second.
    private func makeMap(_ layout: MinimapView.MapLayout) -> MinimapView {
        let view = MinimapView(frame: NSRect(x: 0, y: 0, width: 240, height: 600))
        view.setMaps([MinimapView.Map(fileSize: 0x10000), MinimapView.Map(fileSize: 0x10000)])
        view.setMapLayout(layout)
        view.setZoneMaps([
            ZoneMap(zones: [Zone(id: "a", name: "A", range: 0..<0x8000),
                            Zone(id: "b", name: "B", range: 0x1000..<0x2000)]),
            .empty,
        ])
        view.setSegmentBlocks([
            [],
            [MinimapView.SegmentBlock(range: 0..<0x8000, colorIndex: 0),
             MinimapView.SegmentBlock(range: 0x8000..<0x10000, colorIndex: 1)],
        ])
        return view
    }

    func testSideBySideMapsAreTheSameWidthAndStillMeetAtTheGutter() throws {
        let view = makeMap(.sideBySide)
        let left = view.contentAreaForTesting(forMapAt: 0)
        let right = view.contentAreaForTesting(forMapAt: 1)
        XCTAssertGreaterThan(left.width, 0)
        XCTAssertEqual(left.width, right.width, accuracy: 0.001,
                       "the byte areas are the same width")
        XCTAssertLessThan(left.maxX, view.bounds.midX, "the left map stays left of the divider")
        XCTAssertGreaterThan(right.minX, view.bounds.midX, "and the right one right of it")

        // The legends follow their content: the gutter keeps its gap of paper,
        // the strip keeps its own.
        let gutter = try XCTUnwrap(view.zoneGutterRect(forMapAt: 0))
        XCTAssertEqual(left.minX - gutter.maxX, MinimapView.zoneGutterGap, accuracy: 0.001)
        let strip = try XCTUnwrap(view.segmentStripRect(forMapAt: 1))
        XCTAssertEqual(strip.minX - right.maxX, MinimapView.segmentStripGap, accuracy: 0.001)
    }

    func testStackedMapsShareOneHorizontalSpan() throws {
        let view = makeMap(.stacked(fraction: 0.5))
        let top = view.contentAreaForTesting(forMapAt: 0)
        let bottom = view.contentAreaForTesting(forMapAt: 1)
        XCTAssertGreaterThan(top.width, 0)
        XCTAssertEqual(top.minX, bottom.minX, accuracy: 0.001, "the columns line up")
        XCTAssertEqual(top.maxX, bottom.maxX, accuracy: 0.001)
        XCTAssertNotNil(view.zoneGutterRect(forMapAt: 0), "the gutter still fits")
        XCTAssertNotNil(view.segmentStripRect(forMapAt: 1), "and so does the strip")
    }

    /// A single map has nothing to match and keeps all its width.
    func testASingleMapKeepsItsOwnWidth() {
        let view = MinimapView(frame: NSRect(x: 0, y: 0, width: 240, height: 600))
        view.setMaps([MinimapView.Map(fileSize: 0x10000)])
        view.setMapLayout(.single)
        let content = view.contentAreaForTesting(forMapAt: 0)
        XCTAssertEqual(content.width, 240 - 2 * MinimapView.contentPadding, accuracy: 0.001)
    }
}
