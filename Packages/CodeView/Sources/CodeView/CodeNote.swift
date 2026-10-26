import CodeAnalysis
import Foundation

/// An annotation on a place in the code, as the Code panel shows it: beside
/// the function in the list, at the end of the instruction's row, and as a
/// comment over the function's C. The app hands the pane the annotations on
/// its module; the pane does not read the annotation store.
public struct CodeNote: Equatable, Sendable {
    public let id: String
    public let title: String
    public let note: String
    public let location: CodeLocation
    /// The person's note rather than an agent's: drawn in the person's hue.
    public let byPerson: Bool

    public init(id: String, title: String, note: String, location: CodeLocation, byPerson: Bool) {
        self.id = id
        self.title = title
        self.note = note
        self.location = location
        self.byPerson = byPerson
    }

    var kind: CodeToken.Kind { byPerson ? .personNote : .note }

    /// "a3 Reads the boot mode": the line a row or the C carries.
    var heading: String { "\(id) \(title)" }
}
