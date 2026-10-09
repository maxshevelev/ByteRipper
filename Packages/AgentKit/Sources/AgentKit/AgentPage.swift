import Foundation

/// One page of a list answer, cut to fit the answer bound
/// (`Design/AGENT_PLAN.md`, stage 10).
///
/// An answer over the bound is refused whole by the connection, and a model
/// cannot tell beforehand what `limit` will fit: an item's size depends on the
/// data. So `limit` is a ceiling, and a page stops at whichever comes first —
/// `limit` items, or the item that would take the answer over the bound. Either
/// way the page ends with `next`, the cursor to pass back as `after`, or null
/// when nothing is left; a page cut by size says `truncated: "size"`, so a model
/// can tell "all I asked for, and there is more" from "shortened to fit".
///
/// The size is the answer's own: the fields around the list are encoded once,
/// with room kept for the longest `next` and for `truncated`, and each item adds
/// what it encodes to. The JSON is compact with its keys sorted, so the sum is
/// the length to the byte and nothing has to be taken back.
///
/// A list may be several lists in turn — what only one document holds, then
/// what only the other does — paged as one sequence: each keeps its key, empty
/// on a page that holds none of it, and the cursor counts across them.
public struct AgentPage: Sendable {
    /// Where this page starts in the whole sequence.
    public let first: Int
    /// What the cursor is bound to: the content of the documents and the
    /// question, so a `next` is refused once either changed.
    public let fingerprint: String

    /// Reads `after` against the fingerprint of the question now. `changed` is
    /// the sentence for a cursor from another question or older content.
    public init(_ arguments: AgentArguments, fingerprint: String,
                changed: String = "A document changed since that page, or the question did; ask again without `after`.") throws {
        self.fingerprint = fingerprint
        guard let after = try arguments.optionalString("after") else {
            first = 0
            return
        }
        let parts = after.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, let index = Int(parts[0]), index >= 0 else {
            throw AgentToolError("`after` is not a `next` this tool gave.")
        }
        guard parts[1] == Substring(fingerprint) else { throw AgentToolError(changed) }
        first = index
    }

    /// A fingerprint of the parts — content versions and the arguments that
    /// shape the list. Good for this run of the app, which is as long as a
    /// cursor lives.
    public static func fingerprint(_ parts: [AnyHashable?]) -> String {
        var hasher = Hasher()
        for part in parts { hasher.combine(part) }
        return String(UInt(bitPattern: hasher.finalize()), radix: 16)
    }

    /// The answer: `envelope`, each list under its key, `next`, and
    /// `truncated` when the bound cut it.
    ///
    /// `items` are the candidates from `first` on, in order, each with the key
    /// of the list it belongs to, at most `limit` of them; `total` is the length
    /// of the whole sequence. `keys` are every list's key, so a list with
    /// nothing on this page is still there, empty. An item that would not fit
    /// even on a page of its own is given smaller by `shorten` — marked by the
    /// tool, as `truncated: "item"` — and when that does not fit either, or
    /// there is none, it ends the page, or is refused by name when it is the
    /// page's first.
    public func answer(_ envelope: [String: JSONValue], keys: [String],
                       items: [(key: String, item: JSONValue)], total: Int, bound: Int,
                       shorten: (JSONValue) -> JSONValue? = { _ in nil }) throws -> JSONValue {
        var reserved = envelope
        for key in keys { reserved[key] = .array([]) }
        reserved["next"] = .string("\(total):\(fingerprint)")
        reserved["truncated"] = "size"
        let base = reserved.jsonByteCount
        var size = base
        var lists: [String: [JSONValue]] = Dictionary(uniqueKeysWithValues: keys.map { ($0, []) })
        var taken = 0
        for (key, item) in items {
            var item = item
            var length = item.encoded().count
            // Too large for any page, even alone: shortened wherever it falls.
            // One that would fit a page of its own waits for the next one.
            if base + length > bound {
                guard let shorter = shorten(item), base + shorter.encoded().count <= bound else {
                    guard taken == 0 else { break }
                    throw AgentToolError("Item \(first) alone is over the \(bound)-byte bound for one answer, "
                        + "even shortened; narrow the question so it is not among the answers.")
                }
                item = shorter
                length = item.encoded().count
            }
            let cost = length + (lists[key, default: []].isEmpty ? 0 : 1)
            guard size + cost <= bound else { break }
            lists[key, default: []].append(item)
            size += cost
            taken += 1
        }
        var answer = envelope
        for (key, list) in lists { answer[key] = .array(list) }
        let following = first + taken
        answer["next"] = following < total ? .string("\(following):\(fingerprint)") : .null
        if taken < items.count { answer["truncated"] = "size" }
        return .object(answer)
    }

    /// The answer for a page that is one list.
    public func answer(_ envelope: [String: JSONValue], key: String, items: [JSONValue], total: Int,
                       bound: Int, shorten: (JSONValue) -> JSONValue? = { _ in nil }) throws -> JSONValue {
        try answer(envelope, keys: [key], items: items.map { (key, $0) }, total: total, bound: bound, shorten: shorten)
    }
}

extension Dictionary where Key == String, Value == JSONValue {
    var jsonByteCount: Int { JSONValue.object(self).encoded().count }
}
