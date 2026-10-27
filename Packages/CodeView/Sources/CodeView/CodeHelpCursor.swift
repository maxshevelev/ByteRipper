import AppKit

/// The pointer over a name that explains itself: the arrow with a question
/// mark beside it, as Xcode shows over a symbol that has Quick Help. AppKit
/// has no public cursor for it, so it is drawn once from the arrow.
enum CodeHelpCursor {
    static let cursor: NSCursor = {
        let arrow = NSCursor.arrow
        let base = arrow.image
        let badge: CGFloat = (base.size.height * 0.55).rounded()
        let size = NSSize(width: base.size.width + badge * 0.6, height: base.size.height + badge * 0.4)
        let image = NSImage(size: size, flipped: true) { _ in
            base.draw(in: NSRect(origin: .zero, size: base.size))
            let box = NSRect(x: size.width - badge - 0.5, y: size.height - badge - 0.5,
                             width: badge, height: badge)
            let path = NSBezierPath(roundedRect: box, xRadius: 2, yRadius: 2)
            NSColor.white.setFill()
            path.fill()
            NSColor.black.setStroke()
            path.lineWidth = 1
            path.stroke()
            let mark = NSAttributedString(string: "?", attributes: [
                .font: NSFont.systemFont(ofSize: badge * 0.85, weight: .bold),
                .foregroundColor: NSColor.black
            ])
            let markSize = mark.size()
            mark.draw(at: NSPoint(x: box.midX - markSize.width / 2, y: box.midY - markSize.height / 2))
            return true
        }
        return NSCursor(image: image, hotSpot: arrow.hotSpot)
    }()
}
