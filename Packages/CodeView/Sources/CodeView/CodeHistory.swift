import AppKit
import CodeAnalysis

/// How one place in the code was on screen when the reader left it: where
/// the listing and the C were scrolled, and in the C the call they followed
/// or what they had selected. Back puts it back as it was.
struct CodeViewPosition: Equatable {
    var listing: NSPoint?
    var c: NSPoint?
    /// The range in the C flashed on the way back.
    var cMark: NSRange?
    /// The function's C the mark is in; a mark into other text is dropped.
    var cText: String?
}

/// Back and Forward, carried from one Code panel to another drawing the same
/// module — a republished review, another recipe: each place by address,
/// which one is current, and how each was on screen.
public struct CodeHistory {
    public let places: [CodeLocation]
    public let index: Int
    let views: [CodeViewPosition]
}
