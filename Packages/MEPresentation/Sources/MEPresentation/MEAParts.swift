import Foundation
import PartCodec

/// What a row of the ME tree opens as in a fragment panel — a double-click on
/// it, in the ME Analyzer and in the UEFI Structure's ME branch alike.
///
/// A row with one range opens as a copy of those bytes. An MFS or EFS file
/// opens as its chunks gathered in the file's order (`GatherPartCodec`) — the
/// stored chain, Integrity table included — and goes back to the same places.
/// A row without bytes of its own, and an empty file, opens nothing.
public enum MEAParts {
    public struct Open {
        /// The fragment's name: the row's title, a file's last path component.
        public var name: String
        /// What the fragment is linked to in the dump — a scattered file's span.
        public var source: Range<UInt64>
        public var codec: any PartCodec
    }

    public static func open(_ node: MEANode) -> Open? {
        let name = partName(node.title)
        if let range = node.range, !range.isEmpty {
            return Open(name: name, source: range, codec: CopyPartCodec())
        }
        guard let extents = node.extents?.filter({ !$0.isEmpty }), !extents.isEmpty else { return nil }
        if extents.count == 1 {
            return Open(name: name, source: extents[0], codec: CopyPartCodec())
        }
        let span = extents.map(\.lowerBound).min()!..<extents.map(\.upperBound).max()!
        return Open(name: name, source: span, codec: GatherPartCodec(stretches: extents))
    }

    /// A file's row is titled by its path — `/home/mctp/smt2_devices` — and a
    /// fragment is named as it would be saved: the last component.
    private static func partName(_ title: String) -> String {
        let last = title.split(separator: "/").last.map(String.init) ?? title
        return last.isEmpty ? "(unnamed)" : last
    }
}
