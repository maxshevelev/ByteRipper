import Foundation

/// The parts of a recorded function that outweigh the rest of its entry: its
/// instructions and what marks up its C. An entry's answer goes without them, so
/// recording a function's C does not put the entry past the answer bound of the
/// tools that read it; they are read apart, a page at a time.
public enum LibraryEntryParts {
    public static let names = ["instructions", "c_spans", "c_fields"]

    /// What an entry's header leaves out besides `names`: the function's C and
    /// its call sites, and the review's constants, locals and step comments.
    /// `library_registry` answers an entry with its header — signature, plate,
    /// parameters — and these are read apart with `part`.
    public static let bodyNames = ["c", "c_sites", "constants", "locals", "comments"]

    /// Every part `part(_:of:)` reads.
    public static var allNames: [String] { bodyNames + names }

    /// The parts that live in the review's `function`; the rest are the
    /// review's own keys.
    static let functionKeys: Set<String> = Set(names + ["c", "c_sites"])

    /// How much of a part an answer left out.
    public struct Size: Equatable, Sendable {
        public var items: Int
        public var bytes: Int
    }

    /// The review without the parts, and the size of each it had. A review
    /// that is not an object, or has no `function`, comes back as it is.
    public static func lighter(_ review: Data) -> (review: Data, parts: [String: Size]) {
        guard var object = (try? JSONSerialization.jsonObject(with: review)) as? [String: Any],
              var function = object["function"] as? [String: Any] else { return (review, [:]) }
        var parts: [String: Size] = [:]
        for name in names {
            guard let items = function[name] as? [Any] else { continue }
            let bytes = (try? JSONSerialization.data(withJSONObject: items).count) ?? 0
            parts[name] = Size(items: items.count, bytes: bytes)
            function[name] = nil
        }
        guard !parts.isEmpty else { return (review, [:]) }
        object["function"] = function
        guard let lighter = try? JSONSerialization.data(withJSONObject: object, options: .sortedKeys) else {
            return (review, [:])
        }
        return (lighter, parts)
    }

    /// The review's header: `lighter`, and without `bodyNames` too, with the
    /// size of each part it had. A string counts its lines as items, an array
    /// or an object its members.
    public static func header(_ review: Data) -> (review: Data, parts: [String: Size]) {
        let (lighter, parts) = lighter(review)
        guard var object = (try? JSONSerialization.jsonObject(with: lighter)) as? [String: Any] else {
            return (review, [:])
        }
        var all = parts
        var function = object["function"] as? [String: Any]
        for name in bodyNames {
            let value: Any?
            if functionKeys.contains(name) {
                value = function?.removeValue(forKey: name)
            } else {
                value = object.removeValue(forKey: name)
            }
            guard let value, !(value is NSNull) else { continue }
            all[name] = Size(items: count(value), bytes: bytes(value))
        }
        if let function { object["function"] = function }
        guard all.count > parts.count,
              let header = try? JSONSerialization.data(withJSONObject: object, options: .sortedKeys) else {
            return (lighter, parts)
        }
        return (header, all)
    }

    /// One part, as JSON text — an array, a string or an object as the review
    /// holds it; nil when the review has none.
    public static func part(_ name: String, of review: Data) -> Data? {
        guard allNames.contains(name),
              let object = (try? JSONSerialization.jsonObject(with: review)) as? [String: Any] else { return nil }
        let value = functionKeys.contains(name) ? (object["function"] as? [String: Any])?[name] : object[name]
        guard let value, !(value is NSNull) else { return nil }
        return try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed])
    }

    private static func count(_ value: Any) -> Int {
        switch value {
        case let text as String: return text.isEmpty ? 0 : text.split(separator: "\n", omittingEmptySubsequences: false).count
        case let items as [Any]: return items.count
        case let members as [String: Any]: return members.count
        default: return 1
        }
    }

    private static func bytes(_ value: Any) -> Int {
        (try? JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed).count) ?? 0
    }
}
