import ByteRipperCore
import Foundation

/// A place in the navigation history (§10.6): the selection in each pane a
/// jump moved, and the first byte on screen in the pane it was made in.
///
/// A pane is held weakly and named with the document it held: a pane outlives
/// the file in it, and a place in a file since closed, or replaced by another
/// one, is not a place to go back to.
struct NavigationPlace: Equatable {
    struct Spot: Equatable {
        weak var pane: PaneViewModel?
        let paneID: ObjectIdentifier
        let documentID: ObjectIdentifier
        let start: UInt64
        let end: UInt64

        init(pane: PaneViewModel, document: BinaryDocument, selection: SelectionModel) {
            self.pane = pane
            paneID = ObjectIdentifier(pane)
            documentID = ObjectIdentifier(document)
            start = selection.start
            end = selection.end
        }

        static func == (lhs: Spot, rhs: Spot) -> Bool {
            lhs.paneID == rhs.paneID && lhs.documentID == rhs.documentID
                && lhs.start == rhs.start && lhs.end == rhs.end
        }
    }

    /// The pane the jump was made in first; in a comparison, the other one
    /// after it.
    var spots: [Spot]
    var top: UInt64
}
