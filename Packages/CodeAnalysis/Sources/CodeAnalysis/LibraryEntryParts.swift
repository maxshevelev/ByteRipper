import Foundation

/// The parts of a recorded function that outweigh the rest of its entry: its
/// instructions and what marks up its C. An entry's answer goes without them, so
/// recording a function's C does not put the entry past the answer bound of the
/// tools that read it; they are read apart, a page at a time.
public enum LibraryEntryParts {
    public static let names = ["instructions", "c_spans", "c_fields"]

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

    /// One part's items, as JSON text of an array; nil when the review has none.
    public static func part(_ name: String, of review: Data) -> Data? {
        guard names.contains(name),
              let object = (try? JSONSerialization.jsonObject(with: review)) as? [String: Any],
              let function = object["function"] as? [String: Any],
              let items = function[name] as? [Any] else { return nil }
        return try? JSONSerialization.data(withJSONObject: items, options: .sortedKeys)
    }
}
