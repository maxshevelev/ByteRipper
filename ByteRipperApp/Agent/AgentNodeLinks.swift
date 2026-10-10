import AgentKit
import Foundation
import LenovoDMI
import PartCodec
import UEFIImage
import UEFITool

/// The same node in the other documents of a parent-and-part pair, written
/// into the UEFI tools' answers (`counterpart`, `decoded_in`).
///
/// A part opened with `open_part` has a tree of its own, with ids that start
/// over: the parent's 0.3.4.1.2.5 is 0.0.5 in the decoded block. An agent
/// that had the parent's id in hand showed the parent's node — the encoded
/// bytes — while the decoded part, the one it meant, was open beside it, and
/// nothing in the answer said so. Every node of an answer whose bytes are also
/// a part's, or a parent's, now names that node there.
///
/// Only where the codec keeps the addresses (`PartCodec.keepsOffsets`): a byte
/// of a decompressed body is no byte of the file, and a node there has no
/// address to be matched by.
@MainActor
struct AgentNodeLinks {
    let desk: AgentDesk

    /// A document the answer's nodes may also be in, and how an address of
    /// the answer's document is one of its own.
    private struct Related {
        let id: String
        let pane: PaneViewModel
        let controller: MainViewController?
        /// The answer's addresses that are this document's too.
        let covers: Range<UInt64>
        /// What to add to an address of the answer's document to get this one's.
        let shift: Int64
        /// "decoded" for a block opened decoded, "encoded" for the parent of
        /// one, "same" for bytes that are the same both sides.
        let relation: String
        /// Whether an address of one is the same byte of the other — not
        /// for a decompressed body, whose bytes are no bytes of the file.
        let keepsOffsets: Bool
    }

    /// `answer` with every node in it that is also in a related document
    /// carrying `counterpart`, and `decoded_in` when that document is the
    /// node's block opened decoded. The answer as it is when `place` is
    /// neither a parent of an open part nor a part.
    func annotate(_ answer: JSONValue, place: AgentDesk.Place) async -> JSONValue {
        let related = self.related(to: place).filter(\.keepsOffsets)
        guard !related.isEmpty else { return answer }
        var found: [String: JSONValue?] = [:]
        return await walk(answer, place: place, related: related, found: &found)
    }

    /// Where else a node id that is not one of `place`'s is one: the open
    /// parts of `place` and its parent, each with the node's name there — for
    /// a refusal to say which `document` the id was listed on.
    func documents(holding text: String, besides place: AgentDesk.Place) async -> [(document: String, name: String)] {
        guard !text.isEmpty, let id = try? UEFIAgentQueries.nodeID(text), id != .root else { return [] }
        var holders: [(document: String, name: String)] = []
        for other in related(to: place) {
            let host = PaneToolHost(pane: other.pane, owner: other.controller, tools: nil)
            guard let tree = try? await UEFIAgentQueries.readyTree(host),
                  await UEFIAgentQueries.reachable(id, in: tree), let node = tree.node(id) else { continue }
            holders.append((other.id, UEFITreeDisplay.ownName(of: node) ?? node.name))
        }
        return holders
    }

    private func related(to place: AgentDesk.Place) -> [Related] {
        var list: [Related] = []
        if let controller = place.controller {
            for panel in controller.fragments.panelsLinked(to: place.pane) {
                guard let part = controller.fragments.pane(panel), let origin = part.origin,
                      let document = part.document else { continue }
                let source = origin.sourceRange
                list.append(Related(id: desk.id(of: document), pane: part, controller: controller,
                                    covers: source, shift: -Int64(source.lowerBound),
                                    relation: Self.decodes(origin.codec) ? "decoded" : "same",
                                    keepsOffsets: origin.codec.keepsOffsets))
            }
        }
        if let origin = place.pane.origin, let parent = origin.parent, let document = parent.document {
            let source = origin.sourceRange
            let holder = desk.places().first { $0.pane === parent }
            list.append(Related(id: desk.id(of: document), pane: parent, controller: holder?.controller,
                                covers: 0..<UInt64(source.count), shift: Int64(source.lowerBound),
                                relation: Self.decodes(origin.codec) ? "encoded" : "same",
                                keepsOffsets: origin.codec.keepsOffsets))
        }
        return list
    }

    /// A block opened decoded, not one stored in the clear.
    private static func decodes(_ codec: any PartCodec) -> Bool {
        (codec as? LenovoDMIBlockCodec)?.encodes ?? false
    }

    private func walk(_ value: JSONValue, place: AgentDesk.Place, related: [Related],
                      found: inout [String: JSONValue?]) async -> JSONValue {
        switch value {
        case .array(let items):
            var out: [JSONValue] = []
            for item in items { out.append(await walk(item, place: place, related: related, found: &found)) }
            return .array(out)
        case .object(var members):
            for key in members.keys.sorted() {
                guard let member = members[key] else { continue }
                members[key] = await walk(member, place: place, related: related, found: &found)
            }
            guard let id = members["id"]?.stringValue,
                  let start = members["start"]?.stringValue.flatMap(Self.address),
                  let end = members["end"]?.stringValue.flatMap(Self.address), start < end,
                  related.contains(where: { $0.covers.lowerBound <= start && end <= $0.covers.upperBound })
            else { return .object(members) }
            // A node that only wraps another of the same bytes — the top of a
            // part, around the block it is — is not the node the other side
            // names; only the innermost of them is linked, both ways.
            let ownKey = "\(place.id):\(start):\(end)"
            if found[ownKey] == nil {
                found[ownKey] = await node(in: place.pane, controller: place.controller, start: start, end: end)
            }
            let own = found[ownKey] ?? nil
            guard own == .string(id) else { return .object(members) }
            var counterparts: [JSONValue] = []
            for other in related where other.covers.lowerBound <= start && end <= other.covers.upperBound {
                let key = "\(other.id):\(start):\(end)"
                let node: JSONValue?
                if let known = found[key] {
                    node = known
                } else {
                    node = await self.node(in: other.pane, controller: other.controller,
                                           start: UInt64(Int64(start) + other.shift),
                                           end: UInt64(Int64(end) + other.shift))
                    found[key] = node
                }
                guard let node else { continue }
                let entry: JSONValue = ["document": .string(other.id), "node": node, "as": .string(other.relation)]
                counterparts.append(entry)
                if other.relation == "decoded" { members["decoded_in"] = ["document": .string(other.id), "node": node] }
            }
            if !counterparts.isEmpty { members["counterpart"] = .array(counterparts) }
            return .object(members)
        default:
            return value
        }
    }

    /// The id of the innermost node of `pane` whose bytes are exactly
    /// `start..<end`, or nil when its tree has none — a stretch of a part
    /// that its own tree reads differently.
    private func node(in pane: PaneViewModel, controller: MainViewController?,
                      start: UInt64, end: UInt64) async -> JSONValue? {
        let host = PaneToolHost(pane: pane, owner: controller, tools: nil)
        guard start < host.contentSize, let tree = try? await UEFIAgentQueries.readyTree(host) else { return nil }
        let chain = await withCheckedContinuation { continuation in
            tree.materialize(containing: start) { continuation.resume(returning: $0) }
        }
        return chain.last { $0.fileRange == start..<end }.map { .string($0.id.description) }
    }

    private static func address(_ text: String) -> UInt64? {
        let lower = text.lowercased()
        return lower.hasPrefix("0x") ? UInt64(lower.dropFirst(2), radix: 16) : UInt64(lower)
    }
}
