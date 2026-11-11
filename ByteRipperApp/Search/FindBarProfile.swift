import Foundation

/// What a Find bar searches, and so which of its parts it has (§11, #41).
///
/// The bar and its query controls ask the profile what they offer — never
/// which profile it is — so everything a profile means is written down here,
/// once, rather than as a test of its name at each control.
enum FindBarProfile: Equatable {
    /// The bytes of a dump: an encoding to read the pattern in, Smart Search,
    /// hex patterns and the pattern library, and the pane's results list.
    case hexDump
    /// The code panel's text — the C of the function on screen, or the module
    /// description: the pattern is text, matched under the case and
    /// whole-word rules.
    case code

    /// The encoding popup, and hex patterns read through it.
    var choosesEncoding: Bool { self == .hexDump }
    /// Smart Search, which makes the encoding a result.
    var offersSmartSearch: Bool { self == .hexDump }
    /// Save Search Pattern, the library's rows and Manage Search Patterns….
    var offersPatternLibrary: Bool { self == .hexDump }
    /// The button that lists every occurrence in the pane's results panel.
    var offersResultsList: Bool { self == .hexDump }
    /// The whole-word toggle: a name in C, not part of a longer one.
    var offersWholeWord: Bool { self == .code }
    /// Which list of recent queries the field offers and writes to.
    var history: History {
        switch self {
        case .hexDump: .bytes
        case .code: .code
        }
    }

    /// The lists of recent queries: one for dumps (`FindHistoryStore`), one
    /// for code (`CodeFindHistoryStore`). A byte pattern is noise in C, and a
    /// name is noise in a dump.
    enum History: Equatable {
        case bytes
        case code
    }
}
