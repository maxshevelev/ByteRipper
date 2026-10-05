import Foundation
import UEFIImage

/// What the tree's search asks for: a piece of a name or a GUID, and a type,
/// and with a file or a section a subtype — the three the Name, Type and
/// Subtype columns already show. Everything the query holds is a code or a
/// string typed, never a word of the interface, so a change of language
/// leaves it as it was (`Design/UEFI_STRUCTURE_TOOL.md`, "Searching the tree").
public struct UEFITreeQuery: Equatable, Sendable {
    /// Matched anywhere in the name and in the GUID, whatever the case.
    public var text: String
    /// An item type, `UEFITypes.Item`'s raw value — what the Type column says.
    public var type: UInt8?
    /// A file's or a section's type byte — what the Subtype column says. Only
    /// read with a type of `file` or `section`.
    public var subtype: UInt8?

    public init(text: String = "", type: UInt8? = nil, subtype: UInt8? = nil) {
        self.text = text
        self.type = type
        self.subtype = subtype
    }

    /// The text with the whitespace around it gone: a trailing space is not
    /// part of what anyone looks for.
    public var needle: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// A query that asks for nothing has nothing to find.
    public var isEmpty: Bool { needle.isEmpty && type == nil }

    /// Whether a subtype means anything for the type: a file and a section have
    /// one worth choosing among.
    public static func hasSubtypes(_ type: UInt8?) -> Bool {
        type == UEFITypes.Item.file.rawValue || type == UEFITypes.Item.section.rawValue
    }

    /// Whether `node` answers it. `name` is the name the row shows, which the
    /// caller works out (it needs the GUID catalogue); the node's own name — a
    /// file's, the one its name section gives — and its GUID are read here, so
    /// a file is found as `Setup` and as `899407D7-…` alike.
    public func matches(_ node: UEFINode, name: String) -> Bool {
        if let type, node.uefiItemType != type { return false }
        if let subtype, Self.hasSubtypes(type), node.uefiItemSubtype != subtype { return false }
        let needle = needle
        guard !needle.isEmpty else { return true }
        if Self.contains(name, needle) || Self.contains(node.name, needle) { return true }
        guard let guid = node.guid else { return false }
        let text = guid.description
        if Self.contains(text, needle) { return true }
        // Hex typed without the dashes: the GUID as the bytes are read off.
        return Self.isHex(needle) && Self.contains(text.replacingOccurrences(of: "-", with: ""), needle)
    }

    private static func contains(_ haystack: String, _ needle: String) -> Bool {
        haystack.range(of: needle, options: [.caseInsensitive]) != nil
    }

    private static func isHex(_ text: String) -> Bool {
        text.allSatisfy(\.isHexDigit)
    }
}

/// The types and subtypes the pop-ups offer. A fixed list rather than the types
/// the open image happens to hold: the query is kept from one file to the
/// next, and a choice that left the menu with the file would be a query the
/// reader can no longer see.
public enum UEFITreeSearchChoices {
    public struct Choice: Equatable, Sendable {
        public let code: UInt8
        public let name: String
    }

    /// Every type a node of the tree can be, by the word the Type column uses
    /// — but for `Root`, which no row has.
    public static let types: [Choice] = (0x3D...0x69).map { code in
        Choice(code: UInt8(code), name: UEFITypes.typeName(UInt8(code)))
    }

    /// The subtypes of a type, by the word the Subtype column uses; none for a
    /// type that has none worth choosing among.
    public static func subtypes(of type: UInt8?) -> [Choice] {
        switch type {
        case UEFITypes.Item.file.rawValue:
            return UEFITypeNames.fileTypes.map { Choice(code: $0, name: UEFITypeNames.file($0)) }
        case UEFITypes.Item.section.rawValue:
            return UEFITypeNames.sectionTypes.map { Choice(code: $0, name: UEFITypeNames.section($0)) }
        default:
            return []
        }
    }
}

/// What the search reads of the tree: the rows the outline lists, and whether
/// a branch has been read yet. Nothing about how they are drawn — which is what
/// lets the walk be tested over a table of ids.
public struct UEFITreeSearchSource {
    /// The outline's top level, as listed.
    public var topRows: () -> [NodeID]

    /// The rows listed under `id`, or nil when the branch has not been read
    /// and has to be before anything can be said about what is in it. A node
    /// the search does not go into — a leaf, the ME region — lists none.
    public var listedChildren: (NodeID) -> [NodeID]?

    public init(topRows: @escaping () -> [NodeID], listedChildren: @escaping (NodeID) -> [NodeID]?) {
        self.topRows = topRows
        self.listedChildren = listedChildren
    }
}

/// A walk over the tree's rows, one at a time, in the order the outline lists
/// them with everything open — down into a node before across to the next —
/// forward or back, coming round to the other end once.
///
/// It decides nothing about what matches. It hands back each row in turn and
/// the caller tests it; and where the next row lies in a branch nobody has read,
/// it says which branch to read first and waits, so the caller can read it off
/// the main thread and ask again. The row the walk starts from is not handed
/// back until the walk has come all the way round to it.
public struct UEFITreeSearch: Equatable {
    public enum Direction: Equatable, Sendable {
        case forward, backward
    }

    public enum Advance: Equatable {
        /// The next row to test.
        case candidate(NodeID)
        /// A branch to read before the walk can go on; ask again once it is.
        case expand(NodeID)
        /// Every row has been offered.
        case exhausted
    }

    public let origin: NodeID?
    public let direction: Direction
    /// Whether the walk has gone off one end and come in at the other.
    public private(set) var wrapped = false
    private var current: NodeID?
    private var finished = false

    /// A walk from `origin` — the row selected, or nil for none, which starts
    /// at the top (or the bottom, going back) and does not come round.
    public init(origin: NodeID?, direction: Direction) {
        self.origin = origin
        self.direction = direction
        current = origin
    }

    public mutating func advance(in source: UEFITreeSearchSource) -> Advance {
        while !finished {
            switch position(after: current, in: source) {
            case .expand(let id):
                return .expand(id)
            case .row(let id):
                current = id
                // The origin comes last, once the walk is round to it: a lone
                // match is found again, as a find in the hex view finds it.
                if wrapped, id == origin { finished = true }
                return .candidate(id)
            case .end:
                guard !wrapped, origin != nil else {
                    finished = true
                    return .exhausted
                }
                wrapped = true
                current = nil
            }
        }
        return .exhausted
    }

    private enum Position {
        case row(NodeID)
        case expand(NodeID)
        case end
    }

    private func position(after id: NodeID?, in source: UEFITreeSearchSource) -> Position {
        switch direction {
        case .forward: return forward(from: id, in: source)
        case .backward: return backward(from: id, in: source)
        }
    }

    private func forward(from id: NodeID?, in source: UEFITreeSearchSource) -> Position {
        guard let id else {
            return source.topRows().first.map(Position.row) ?? .end
        }
        guard let children = source.listedChildren(id) else { return .expand(id) }
        if let first = children.first { return .row(first) }
        // Nothing under it: the next row across, or across from the nearest
        // row above that has one.
        var row = id
        while true {
            let siblings = Self.siblings(of: row, in: source)
            guard let index = siblings.firstIndex(of: row) else { return .end }
            if index + 1 < siblings.count { return .row(siblings[index + 1]) }
            guard let parent = Self.parent(of: row, in: source) else { return .end }
            row = parent
        }
    }

    private func backward(from id: NodeID?, in source: UEFITreeSearchSource) -> Position {
        guard let id else {
            guard let last = source.topRows().last else { return .end }
            return Self.deepestLast(under: last, in: source)
        }
        let siblings = Self.siblings(of: id, in: source)
        guard let index = siblings.firstIndex(of: id) else { return .end }
        if index > 0 { return Self.deepestLast(under: siblings[index - 1], in: source) }
        return Self.parent(of: id, in: source).map(Position.row) ?? .end
    }

    /// The last row at or under `id`: back through a row means through
    /// everything in it first.
    private static func deepestLast(under id: NodeID, in source: UEFITreeSearchSource) -> Position {
        var row = id
        while true {
            guard let children = source.listedChildren(row) else { return .expand(row) }
            guard let last = children.last else { return .row(row) }
            row = last
        }
    }

    private static func siblings(of id: NodeID, in source: UEFITreeSearchSource) -> [NodeID] {
        if source.topRows().contains(id) { return source.topRows() }
        return source.listedChildren(NodeID(Array(id.path.dropLast()))) ?? []
    }

    private static func parent(of id: NodeID, in source: UEFITreeSearchSource) -> NodeID? {
        source.topRows().contains(id) ? nil : NodeID(Array(id.path.dropLast()))
    }
}

/// What the search has opened in the tree, so it can shut it again. A row the
/// reader opened is theirs and stays; a row the search opened for a match it
/// has since left is shut, deepest first, when the walk lands somewhere that does
/// not need it — and a row the reader then opens or shuts on a match is theirs
/// from that moment.
public struct UEFISearchOpenings: Equatable, Sendable {
    /// The rows the search opened and has not shut, in the order it opened them.
    public private(set) var opened: [NodeID] = []

    public init() {}

    public var isEmpty: Bool { opened.isEmpty }

    /// The search opened `id`.
    public mutating func record(_ id: NodeID) {
        if !opened.contains(id) { opened.append(id) }
    }

    /// `id` is no longer the search's to shut: the reader opened or shut it
    /// themselves, or it is shut already.
    public mutating func forget(_ id: NodeID) {
        opened.removeAll { $0 == id }
    }

    /// Everything the search opened becomes the reader's: they left by a click,
    /// closed the bar or changed what they look for, and the tree stays as it is.
    public mutating func release() {
        opened = []
    }

    /// The rows to shut when the walk lands on `target`, deepest first: those
    /// the search opened that are neither the match nor above it. A row above the
    /// match is on the way to it and stays open as long as the match is.
    public func closings(whenLandingOn target: NodeID) -> [NodeID] {
        opened
            .filter { $0 != target && !target.path.starts(with: $0.path) }
            .sorted { $0.path.count > $1.path.count }
    }
}
