import Foundation

/// How a row's value is drawn — the colour intent the pure target decides
/// because only it knows the fact behind a value (e.g. a File System State's
/// status). The view resolves each tone into a theme-adapted `NSColor`; a row
/// carries `.standard` unless it says otherwise.
///
/// Lived with the Summary tab's model, but `MEAField` (the tree's detail row)
/// carries a tone too, so the shared tree and the summary tab both need it —
/// which is why it sits here, in the shared presentation, not in `MEATool`.
public enum MEASummaryTone: Sendable, Equatable, Hashable {
    /// The ordinary label-colour value most rows carry.
    case standard
    /// A settled state — drawn green.
    case good
    /// A state in the middle of its lifecycle — drawn brown.
    case caution
    /// A failed state — drawn red.
    case bad
}
