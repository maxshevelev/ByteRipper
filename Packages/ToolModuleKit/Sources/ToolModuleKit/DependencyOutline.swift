/// A module's dependency expression as the code panel shows it: what must all
/// hold for the dispatcher to start the module, each interface by its name and
/// GUID, a choice as a group of its own. The UEFI tool reads it from the
/// module's firmware file; the code panel only draws it, so neither has to
/// know the other's types.
public struct DependencyOutline: Equatable, Sendable {
    public indirect enum Condition: Equatable, Sendable {
        /// A PPI or protocol that must be installed: its GUID, and its name
        /// where the catalogue has one.
        case interface(guid: String, name: String?)
        case not(Condition)
        /// Every one of these holds.
        case allOf([Condition])
        /// One of these, at least, holds.
        case anyOf([Condition])
        case always
        case never
    }

    /// What must all hold, in the expression's order. Empty when the file
    /// has no expression.
    public var conditions: [Condition]
    /// `BEFORE`, `AFTER` or `SOR` ahead of the expression, as the format
    /// spells it; nil when there is none.
    public var prefix: String?
    /// The expression is there but does not read: its conditions are not
    /// known.
    public var unreadable: Bool

    public init(conditions: [Condition], prefix: String? = nil, unreadable: Bool = false) {
        self.conditions = conditions
        self.prefix = prefix
        self.unreadable = unreadable
    }

    /// A file with no expression.
    public static let none = DependencyOutline(conditions: [])

    /// Whether there is nothing to show under the heading.
    public var isEmpty: Bool { conditions.isEmpty && prefix == nil && !unreadable }
}
