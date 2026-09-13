import Foundation

/// What a firmware panel says about one row besides its text
/// (`Design/ROW_MARKS.md`): a value, decided in a tool-module's pure target
/// and handed to `ToolPanelTable` and `ToolPanelRowView` to draw.
///
/// One vocabulary for every panel, because a reader moves between the UEFI
/// tree, the FIT table and the ME tree on the same image, and a rose row has to
/// mean the same thing in each.
public struct ToolRowMarks: Equatable, Sendable {
    /// Background: what an edit to the row's bytes breaks.
    public enum Protection: Equatable, Sendable {
        /// Wholly inside the Boot Guard IBB.
        case ibb
        /// Wholly inside ranges the firmware checks at boot.
        case firmware
    }

    /// The row's problems, as one icon: an error when any of them is one, a
    /// caution otherwise. Every line is in the icon's tooltip.
    public enum Problem: Equatable, Sendable {
        case error([String])
        case caution([String])

        public var isError: Bool {
            if case .error = self { return true }
            return false
        }

        public var lines: [String] {
            switch self {
            case .error(let lines), .caution(let lines): return lines
            }
        }

        /// The worst of what a row has: nil when it has nothing, errors first
        /// in the tooltip when it has both.
        public static func worst(errors: [String], cautions: [String]) -> Problem? {
            if !errors.isEmpty { return .error(errors + cautions) }
            if !cautions.isEmpty { return .caution(cautions) }
            return nil
        }
    }

    /// A badge: what the row is to the others.
    public enum Role: Equatable, Sendable {
        /// Holds compressed data — `decoded` when this project opens it.
        case compressed(algorithm: String, decoded: Bool)
        /// Holds what other structures are checked against: protected ranges,
        /// or the hashes of other structures. The words say which.
        case holdsChecks(String)
        /// Partly covered by protected ranges.
        case partlyProtected
    }

    public var protection: Protection?
    /// Where the row's bytes were decompressed from, in the words the tooltip
    /// uses — nil for bytes of the file. Non-nil draws the rail.
    public var decompressedFrom: String?
    /// The row is the compressed data, open on the decompressed rows under it:
    /// its bytes are the file's, and it starts their rail, so the rail ties the
    /// subtree to its parent. A panel sets it only while the row is open.
    public var opensDecompressed: Bool
    public var problem: Problem?
    /// At most two are drawn, in this order.
    public var roles: [Role]

    public init(
        protection: Protection? = nil,
        decompressedFrom: String? = nil,
        opensDecompressed: Bool = false,
        problem: Problem? = nil,
        roles: [Role] = []
    ) {
        self.protection = protection
        self.decompressedFrom = decompressedFrom
        self.opensDecompressed = opensDecompressed
        self.problem = problem
        self.roles = roles
    }

    public static let none = ToolRowMarks()

    /// Whether the row wears the rail.
    public var hasRail: Bool { decompressedFrom != nil || opensDecompressed }

    /// The row's background and rail in words, for the row's tooltip — so that
    /// nothing a row says is said by colour alone. Nil when it wears neither.
    public var summary: String? {
        var parts: [String] = []
        switch protection {
        case .ibb: parts.append("Inside the Boot Guard IBB")
        case .firmware: parts.append("Inside a range the firmware checks at boot")
        case nil: break
        }
        if let decompressedFrom { parts.append(decompressedFrom) }
        if opensDecompressed { parts.append("Compressed: what it holds is listed under it, decompressed") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// Every mark a row can wear, as the legend lists them — one catalogue, so the
/// legend and the rows it explains cannot disagree.
public enum ToolRowMark: CaseIterable, Hashable, Sendable {
    case protectedIBB
    case protectedFirmware
    case decompressed
    case error
    case caution
    case compressed
    case compressedUndecoded
    case holdsChecks
    case partlyProtected

    /// The channels of `ROW_MARKS.md` §1, in the order a legend lists them.
    public enum Channel: Int, Comparable, Sendable {
        case background, rail, verdict, problem, role

        public static func < (lhs: Channel, rhs: Channel) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public var channel: Channel {
        switch self {
        case .protectedIBB, .protectedFirmware: return .background
        case .decompressed: return .rail
        case .error, .caution: return .problem
        case .compressed, .compressedUndecoded, .holdsChecks, .partlyProtected: return .role
        }
    }

    /// What the legend says the mark means.
    public var meaning: String {
        switch self {
        case .protectedIBB:
            return "Inside the Boot Guard IBB: an edit stops the platform booting"
        case .protectedFirmware:
            return "Inside a range the firmware checks at boot"
        case .decompressed:
            return "A compressed section that opens here, and what came out of it"
        case .error:
            return "Something is wrong: the pointer says what"
        case .caution:
            return "Could not be checked, or wants a second look"
        case .compressed:
            return "Holds compressed data that opens here"
        case .compressedUndecoded:
            return "Holds compressed data that does not open here"
        case .holdsChecks:
            return "Holds what other structures are checked against"
        case .partlyProtected:
            return "Partly inside protected ranges"
        }
    }
}
