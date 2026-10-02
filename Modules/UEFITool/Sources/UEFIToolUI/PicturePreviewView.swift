import AppKit
import Localization
import HelpUI

/// The picture a node is, drawn in the detail list on a background the reader
/// can change with a click, inside a hairline frame.
///
/// Firmware pictures are logos, and a logo is often white or transparent: on
/// the panel's own background it is not there at all. The frame says where the
/// picture is whatever its colours; the background is what lets its pixels be
/// seen. A picture with an alpha channel starts on the checkerboard, which is
/// what shows transparency; one without starts on the panel's background, which
/// it covers anyway. The choice is not remembered — the next picture starts
/// from what suits it.
final class PicturePreviewView: NSImageView {
    enum Background: CaseIterable {
        /// Nothing drawn: the panel shows through.
        case panel
        case checkerboard
        /// Black on a light panel, white on a dark one: the colour a picture
        /// made for the panel's own is least likely to be.
        case contrast
    }

    private(set) var background: Background

    init(image: NSImage, hasAlpha: Bool) {
        background = hasAlpha ? .checkerboard : .panel
        super.init(frame: .zero)
        self.image = image
        imageScaling = .scaleProportionallyUpOrDown
        imageFrameStyle = .none
        ControlHelp.describe(self, name: L("Picture preview"), tooltip: L("Click to change the background"))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The next background, in a circle.
    func cycleBackground() {
        let all = Background.allCases
        background = all[(all.firstIndex(of: background)! + 1) % all.count]
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        cycleBackground()
    }

    override func accessibilityPerformPress() -> Bool {
        cycleBackground()
        return true
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func draw(_ dirtyRect: NSRect) {
        switch background {
        case .panel:
            break
        case .checkerboard:
            Self.checkerLight.setFill()
            bounds.fill()
            Self.checkerDark.setFill()
            let side: CGFloat = 8
            var y: CGFloat = 0
            var row = 0
            while y < bounds.height {
                var x: CGFloat = row % 2 == 0 ? 0 : side
                while x < bounds.width {
                    NSRect(x: x, y: y, width: side, height: side).intersection(bounds).fill()
                    x += side * 2
                }
                y += side
                row += 1
            }
        case .contrast:
            Self.contrast.setFill()
            bounds.fill()
        }
        super.draw(dirtyRect)
        NSColor.separatorColor.setStroke()
        let frame = NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5))
        frame.lineWidth = 1
        frame.stroke()
    }

    private static func dynamic(light: CGFloat, dark: CGFloat) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(white: isDark ? dark : light, alpha: 1)
        }
    }

    private static let checkerLight = dynamic(light: 1.0, dark: 0.30)
    private static let checkerDark = dynamic(light: 0.80, dark: 0.18)
    private static let contrast = dynamic(light: 0.0, dark: 1.0)
}
