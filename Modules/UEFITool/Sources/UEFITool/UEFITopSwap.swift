import Foundation
import Localization
import UEFIImage

/// What the structure panel says about the Top Swap copy of the boot block
/// (`TopSwapCopy`), decided here so it is tested without a window.
///
/// The copy is the top block again, one block lower: the same volumes, which
/// the tree would otherwise list a second time with nothing to say what they
/// are. The outermost nodes of the copy — those lying wholly inside it whose
/// parent does not — carry that in their name, and both blocks' outermost
/// nodes say in their details where the other copy is and whether the two
/// still agree.
public enum UEFITopSwap {
    public enum Role: Equatable, Sendable {
        /// The node is in the copy; `of` is the top block it copies.
        case copy(of: Range<UInt64>)
        /// The node is in the top block; `at` is where its copy is.
        case original(copiedAt: Range<UInt64>)
    }

    /// The node's role, when it is outermost in either block of an image
    /// whose Top Swap copy has been found.
    public static func role(of node: UEFINode, in image: UEFIImage) -> Role? {
        guard node.space == .file, let copy = image.protectedRanges?.topSwap else { return nil }
        if isOutermost(node, in: copy.backup, image: image) { return .copy(of: copy.top) }
        if isOutermost(node, in: copy.top, image: image) { return .original(copiedAt: copy.backup) }
        return nil
    }

    /// Where a node's twin in the other block is: the same bytes one block
    /// up or down, and a node of the same kind. Any node of the file lying
    /// wholly inside either block has one — a file in the copy, a section in
    /// the top block — so a reader can step between the two and see what
    /// stands for what.
    public struct Counterpart: Equatable, Sendable {
        /// The twin's range.
        public var range: Range<UInt64>
        public var kind: UEFINodeKind
        /// Whether the twin is in the copy, so the step goes down.
        public var isInCopy: Bool

        /// The menu item that steps there.
        public var menuTitle: String {
            isInCopy ? L("Go to Top Swap Copy") : L("Go to Original")
        }
    }

    public static func counterpart(of node: UEFINode, in image: UEFIImage) -> Counterpart? {
        guard node.space == .file, let copy = image.protectedRanges?.topSwap else { return nil }
        if encloses(copy.top, node.range) {
            return Counterpart(range: shifted(node.range, by: -Int64(copy.size)), kind: node.kind, isInCopy: true)
        }
        if encloses(copy.backup, node.range) {
            return Counterpart(range: shifted(node.range, by: Int64(copy.size)), kind: node.kind, isInCopy: false)
        }
        return nil
    }

    /// The twin among `chain` — the nodes covering its first byte, outermost
    /// first: the one with the same range and kind. Where the copies have
    /// drifted apart and no node matches, the innermost node that still holds
    /// the whole range, so the step lands as near as the tree allows.
    public static func twin(of counterpart: Counterpart, in chain: [UEFINode]) -> UEFINode? {
        chain.last { $0.range == counterpart.range && $0.kind == counterpart.kind }
            ?? chain.last { $0.space == .file && encloses($0.range, counterpart.range) }
    }

    private static func shifted(_ range: Range<UInt64>, by delta: Int64) -> Range<UInt64> {
        let lower = UInt64(Int64(range.lowerBound) + delta)
        return lower..<(lower + UInt64(range.count))
    }

    private static func isOutermost(_ node: UEFINode, in block: Range<UInt64>, image: UEFIImage) -> Bool {
        guard encloses(block, node.range) else { return false }
        guard !node.id.path.isEmpty, let parent = image.node(NodeID(Array(node.id.path.dropLast()))) else {
            return true
        }
        return parent.space != .file || !encloses(block, parent.range)
    }

    private static func encloses(_ block: Range<UInt64>, _ range: Range<UInt64>) -> Bool {
        !range.isEmpty && block.lowerBound <= range.lowerBound && range.upperBound <= block.upperBound
    }

    /// The row's name, with what it is when it is the copy.
    static func name(_ name: String, for node: UEFINode, in image: UEFIImage) -> String {
        guard case .copy = role(of: node, in: image) else { return name }
        return L("%1$@ (Top Swap copy)", name)
    }

    /// The detail row: where the other copy is, and whether the two agree.
    static func detail(for node: UEFINode, in image: UEFIImage) -> String? {
        guard let role = role(of: node, in: image), let ranges = image.protectedRanges else { return nil }
        let agreement = ranges.topSwapCopiesMatch ? L("the copies match") : L("the copies differ")
        switch role {
        case .copy(let top):
            return L("Copy of %1$@–%2$@; %3$@", hex(top.lowerBound), hex(top.upperBound), agreement)
        case .original(let backup):
            return L("Copied at %1$@–%2$@; %3$@", hex(backup.lowerBound), hex(backup.upperBound), agreement)
        }
    }

    private static func hex(_ value: UInt64) -> String {
        String(format: "0x%llX", value)
    }
}
