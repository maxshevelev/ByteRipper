import Foundation

/// A named stretch of the open file, published by a tool-module for the dump to
/// draw (`Design/TOOL_MODULES_PLAN.md`).
///
/// Zones are the tool-module's alone: the user reads and navigates them, and
/// never makes or edits one. That is what keeps them cheap — nothing has to
/// author them, persist them or carry them across an edit. After the content
/// changes the tool-module publishes a fresh map built by re-reading, rather
/// than the app shifting the old one, which is the anchoring machinery
/// `Design/ZONES_IDEA.md` had budgeted for and this design does not need.
///
/// A zone is a *slice* of what the tool-module knows, not its model: a UEFI
/// parse is a tree of thousands of nodes, and what belongs here is the handful
/// worth drawing — the node in focus and its children. The tree, the
/// diagnostics and everything else stay behind the panel.
public struct Zone: Equatable, Identifiable, Sendable {
    /// Stable within one published map; the focus names a zone by it. A
    /// tool-module that rebuilds its map after an edit should keep the ids it
    /// used before, so the focus survives the rebuild.
    public var id: String
    /// What the dump calls it. May be empty — a region worth showing is worth
    /// showing even before it has a name.
    public var name: String
    /// The stretches of the file the zone is, half-open `[start, end)` like
    /// every other byte range in this project — one for almost everything a
    /// panel points at, several for a thing whose bytes the firmware scattered:
    /// an MFS file is a chain of chunks spread over the volume's pages.
    ///
    /// In the owner's order — for a file, the order its bytes are read in,
    /// which is not address order: wear levelling puts a later chunk before an
    /// earlier one. Disjoint. What draws them sorts a copy; what reads the
    /// zone's bytes reads them in this order.
    public var ranges: [Range<UInt64>]
    /// Reserved. The uses are real — protected by Boot Guard, padding, an empty
    /// slot, a region open for editing (issue #10) — and each of them
    /// wants a tool-module that has something to say first.
    public var kind: ZoneKind

    public init(id: String, name: String, range: Range<UInt64>, kind: ZoneKind = .plain) {
        self.init(id: id, name: name, ranges: [range], kind: kind)
    }

    /// A zone of several stretches, in the owner's order (`ranges`).
    public init(id: String, name: String, ranges: [Range<UInt64>], kind: ZoneKind = .plain) {
        self.id = id
        self.name = name
        self.ranges = ranges
        self.kind = kind
    }

    /// The zone's one stretch, or the span from its lowest start to its
    /// highest end when it has several — which claims the bytes between them
    /// too, so it orders and nests zones and is never read as the zone's bytes.
    public var range: Range<UInt64> {
        guard let first = ranges.first else { return 0..<0 }
        if ranges.count == 1 { return first }
        let lower = ranges.lazy.map(\.lowerBound).min() ?? first.lowerBound
        let upper = ranges.lazy.map(\.upperBound).max() ?? first.upperBound
        return lower..<upper
    }

    /// Where the zone begins for a reader: the first byte of its first stretch
    /// in the owner's order — where a reveal or a focus takes the dump.
    public var start: UInt64 { ranges.first?.lowerBound ?? 0 }

    /// True when the zone is more than one stretch.
    public var isScattered: Bool { ranges.count > 1 }

    /// The stretch `offset` lies in, nil for a byte between two stretches.
    public func stretch(containing offset: UInt64) -> Range<UInt64>? {
        ranges.first { $0.contains(offset) }
    }
}

/// What a zone *is*, as opposed to what it is called. One case for now, on
/// purpose: see `Zone.kind`.
public enum ZoneKind: Equatable, Sendable {
    case plain
}

/// What the dump should draw: the zones, and which of them is in focus.
///
/// A value rather than a call with two arguments, because publishing replaces
/// the whole map — a tool-module that has re-read the file says what is there
/// now, and never patches what it said before. `empty` is how a tool-module
/// says "nothing to show", and it is also what the host holds before the first
/// publish and after the session ends.
public struct ZoneMap: Equatable, Sendable {
    public var zones: [Zone]
    /// The zone drawn as the focused one, if it is still in `zones`.
    public var focus: Zone.ID?

    public static let empty = ZoneMap(zones: [])

    public init(zones: [Zone], focus: Zone.ID? = nil) {
        self.zones = zones
        self.focus = focus
    }

    /// The map as the dump can actually draw it, against a file of
    /// `contentSize` bytes.
    ///
    /// A published map can disagree with the file, and the ordinary way it
    /// happens is not a bug in the tool-module: an edit lands, the map is a
    /// re-read behind, and something asks to draw in between. So this is a
    /// repair rather than a rejection —
    ///
    /// - a stretch reaching past the end is **clamped**, because the part of it
    ///   that is still in the file is still worth drawing;
    /// - a stretch starting at or past the end is **dropped**, since nothing of
    ///   it is left;
    /// - an empty stretch is dropped: a zone is bytes, and a stretch of no
    ///   bytes is a mark, which this app already has in bookmarks (§20);
    /// - a zone left with no stretch is dropped;
    /// - a repeated id is dropped after its first use, so the focus names one
    ///   zone rather than an argument;
    /// - a focus naming nothing that survived becomes `nil`.
    ///
    /// Overlap is *not* an error and is not touched: zones nest — a volume
    /// holds files hold sections — and a tool-module publishing a node with its
    /// children is the ordinary case.
    ///
    /// The order is the drawing order: by start, and for a shared start the
    /// longer range first, so a parent is drawn before the children that sit
    /// inside it — a scattered zone by its span (`Zone.range`), its stretches
    /// keeping the owner's order. Ties beyond that fall back to the id, so the
    /// result is the same map whatever order it arrived in.
    public func normalized(contentSize: UInt64) -> ZoneMap {
        var seen = Set<Zone.ID>()
        var kept: [Zone] = []
        kept.reserveCapacity(zones.count)

        for zone in zones {
            let stretches = zone.ranges.compactMap { stretch -> Range<UInt64>? in
                guard stretch.lowerBound < stretch.upperBound,
                      stretch.lowerBound < contentSize else { return nil }
                return stretch.lowerBound..<min(stretch.upperBound, contentSize)
            }
            guard !stretches.isEmpty else { continue }
            guard seen.insert(zone.id).inserted else { continue }
            var clamped = zone
            clamped.ranges = stretches
            kept.append(clamped)
        }

        kept.sort {
            if $0.range.lowerBound != $1.range.lowerBound {
                return $0.range.lowerBound < $1.range.lowerBound
            }
            if $0.range.upperBound != $1.range.upperBound {
                return $0.range.upperBound > $1.range.upperBound
            }
            return $0.id < $1.id
        }

        let survivingFocus = focus.flatMap { id in kept.contains { $0.id == id } ? id : nil }
        return ZoneMap(zones: kept, focus: survivingFocus)
    }

    /// The zones covering `offset`, outermost first — what a click in the dump
    /// resolves to once the host asks that question (stage 5). By the
    /// stretches, not the span: the gap between two chunks of a file is not
    /// the file.
    public func zones(containing offset: UInt64) -> [Zone] {
        zones.filter { $0.stretch(containing: offset) != nil }
    }
}
