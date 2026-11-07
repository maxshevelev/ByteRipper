import AppKit
import ByteRipperCore
import XCTest
@testable import ByteRipper

/// The find bar and the search-results panel paint their backgrounds onto a
/// CALayer. A dynamic `NSColor.controlBackgroundColor` assigned in `setUp` —
/// before the view is in a window — is captured once, so a launch in one theme
/// left the panel stuck in it: switching to dark mode kept the bar white.
/// `viewDidChangeEffectiveAppearance` re-resolves the color against the current
/// appearance, and these tests pin that the layer actually follows the
/// appearance instead of holding the launch-theme bake (§3.1).
@MainActor
final class PanelAppearanceTests: XCTestCase {
    /// The layer's first background component (red, or the gray value for a
    /// gray color) — `controlBackgroundColor` is a gray, so its component cleanly
    /// separates the light plate (> 0.8) from the dark plate (< 0.25).
    private func backgroundComponent(_ c: CGColor?) -> CGFloat {
        guard let c, c.numberOfComponents >= 1 else { return -1 }
        return c.components?[0] ?? -1
    }

    func testFindBarBackgroundFollowsAppearance() {
        let bar = FindBarView()
        defer { bar.removeFromSuperview() }

        bar.appearance = NSAppearance(named: .darkAqua)
        bar.viewDidChangeEffectiveAppearance()
        XCTAssertLessThan(backgroundComponent(bar.layer?.backgroundColor), 0.5,
                          "the bar must use the dark plate in dark mode, not the light-launch bake")

        bar.appearance = NSAppearance(named: .aqua)
        bar.viewDidChangeEffectiveAppearance()
        XCTAssertGreaterThan(backgroundComponent(bar.layer?.backgroundColor), 0.5,
                            "the bar must return to the light plate in light mode")
    }

    /// The results panel draws its fill through an `NSBox`, so there is no baked
    /// `CGColor` to go stale: AppKit re-resolves an `NSColor` per appearance
    /// itself. Asserted by resolving the very colour the box is given, in both
    /// appearances — the bug this replaces was a colour that could not change,
    /// and a colour that resolves differently cannot have it.
    func testSearchResultsBackgroundFollowsAppearance() throws {
        let panel = SearchResultsViewController(pane: PaneViewModel())
        let box = try XCTUnwrap(descendants(of: panel.view, NSBox.self).first,
                                "the panel draws its fill with a box")
        let fill = box.fillColor

        var dark: CGFloat = 1
        var light: CGFloat = 0
        NSAppearance(named: .darkAqua)?.performAsCurrentDrawingAppearance {
            dark = fill.usingColorSpace(NSColorSpace.deviceRGB)?.redComponent ?? 1
        }
        NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance {
            light = fill.usingColorSpace(NSColorSpace.deviceRGB)?.redComponent ?? 0
        }

        XCTAssertLessThan(dark, 0.5, "the results panel must be dark in dark mode")
        XCTAssertGreaterThan(light, 0.5, "and light in light mode")
    }

    /// The minimap paints its paper onto a layer the same way, from
    /// `textBackgroundColor` — white in light, near-black in dark — so it needs
    /// the same re-resolve or the panel keeps the launch theme's paper.
    func testMinimapBackgroundFollowsAppearance() {
        let minimap = MinimapView(frame: NSRect(x: 0, y: 0, width: 120, height: 400))
        defer { minimap.removeFromSuperview() }

        minimap.appearance = NSAppearance(named: .darkAqua)
        minimap.viewDidChangeEffectiveAppearance()
        XCTAssertLessThan(backgroundComponent(minimap.layer?.backgroundColor), 0.5,
                          "the minimap must use the dark paper in dark mode")

        minimap.appearance = NSAppearance(named: .aqua)
        minimap.viewDidChangeEffectiveAppearance()
        XCTAssertGreaterThan(backgroundComponent(minimap.layer?.backgroundColor), 0.5,
                            "the minimap must return to the light paper in light mode")
    }

    /// A drop zone paints its idle "milky" plate onto a layer from
    /// `windowBackgroundColor`, the same layer-bake that left the find bar
    /// white in dark mode (§3.1). The colour is captured when the zone is built
    /// and only re-resolved here — so a zone the pointer never hovers (a thin
    /// insert/append strip, the New Tab plate) keeps the launch theme's plate
    /// in a dark window. All five zones are the same view; Replace and Open-as-
    /// Second merely get re-painted by a hover more often, which is why only
    /// the strips looked wrong.
    ///
    /// From macOS 26 the plate is clear glass and the layer has no fill at all,
    /// so what follows the theme is the zone's edge: `tertiaryLabelColor`,
    /// light on a dark window and dark on a light one.
    func testDropZonePlateFollowsAppearance() {
        let zone = DropTargetView(title: SingleFileDropTarget.replace.title)
        defer { zone.removeFromSuperview() }

        if #available(macOS 26.0, *) {
            zone.appearance = NSAppearance(named: .darkAqua)
            zone.viewDidChangeEffectiveAppearance()
            XCTAssertNil(zone.layer?.backgroundColor, "the glass is the plate: no launch-theme fill under it")
            XCTAssertGreaterThan(backgroundComponent(zone.layer?.borderColor), 0.5,
                                 "the idle edge is light in dark mode")

            zone.appearance = NSAppearance(named: .aqua)
            zone.viewDidChangeEffectiveAppearance()
            XCTAssertNil(zone.layer?.backgroundColor)
            XCTAssertLessThan(backgroundComponent(zone.layer?.borderColor), 0.5,
                              "the idle edge returns to dark in light mode")

            // The hover is a calm fill over the glass, as the plate had before
            // it: a tint of the glass itself comes out far brighter.
            XCTAssertNil(zone.hoverFillForTesting, "an idle zone has no fill")
            zone.setHighlighted(true)
            XCTAssertNil(zone.glassTintForTesting, "the glass is never tinted")
            XCTAssertEqual(zone.hoverFillForTesting?.alpha ?? 0, DropTargetView.hoverFillAlpha, accuracy: 0.01)
            zone.setHighlighted(false)
            XCTAssertNil(zone.hoverFillForTesting)
            return
        }

        zone.appearance = NSAppearance(named: .darkAqua)
        zone.viewDidChangeEffectiveAppearance()
        XCTAssertLessThan(backgroundComponent(zone.layer?.backgroundColor), 0.5,
                          "the idle zone must use the dark plate in dark mode, not a light launch bake")

        zone.appearance = NSAppearance(named: .aqua)
        zone.viewDidChangeEffectiveAppearance()
        XCTAssertGreaterThan(backgroundComponent(zone.layer?.backgroundColor), 0.5,
                            "the idle zone must return to the light plate in light mode")
    }
}
