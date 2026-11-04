import Foundation

/// What a module stores of a function the registry holds: its own facts and the
/// link. Where the function is, who calls it, its instructions, its body and its
/// mark stay; its name, signature, C and review are the entry's, and a reader
/// takes them from there (`LibraryView`).
///
/// Works on the exporter's JSON, so a field this build does not know stays as
/// it is. An artifact with nothing to strip comes back byte for byte.
public enum LibraryCopyFree {
    /// What describes a function, and goes.
    private static let description = [
        "signature", "c", "c_spans", "c_sites", "c_fields", "c_unreachable",
        "name_reason", "signature_reason", "custom_storage", "library_kind"
    ]

    public struct Stripped: Sendable {
        public var artifact: Data
        /// The entries of the functions stripped.
        public var functions: Set<String>
        /// Every instruction address in them, for what a review wrote there.
        public var addresses: Set<String>
    }

    /// A function a module stores no text of: read through the registry, and
    /// not this module's change of it. `edited`, `conflict` and `differs` are
    /// the module's own text, which a publish may still have to say something with.
    static func holdsNoText(_ function: [String: Any], in index: LibraryIndex) -> Bool {
        let mark = function["library_entry"] as? [String: Any]
        if let state = mark?["state"] as? String, state != "entry" { return false }
        return LibraryView.entryID(body: function["body"] as? String, mark: mark?["id"] as? String,
                                   external: function["external"] as? Bool ?? false,
                                   thunk: function["thunk"] as? Bool ?? false,
                                   referenceBytes: function["reference_bytes"] as? String, in: index) != nil
    }

    public static func strip(_ raw: Data, index: LibraryIndex) -> Stripped {
        var nothing = Stripped(artifact: raw, functions: [], addresses: [])
        guard var object = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any],
              var functions = object["functions"] as? [[String: Any]] else { return nothing }
        var stripped = Set<String>(), addresses = Set<String>()
        for position in functions.indices where holdsNoText(functions[position], in: index) {
            var function = functions[position]
            guard let entry = function["entry"] as? String, let address = CodeAddress(hex: entry) else { continue }
            for key in description { function[key] = nil }
            // The field stays for a reader from before this: it is the
            // placeholder any unnamed function has, and says nothing of the entry.
            function["name"] = "FUN_" + (LibraryView.hex(address, width: 8) ?? String(address.value, radix: 16))
            function["name_source"] = "DEFAULT"
            function["review_gaps"] = [String]()
            function["copy_free"] = true
            stripped.insert(entry)
            for instruction in function["instructions"] as? [[String: Any]] ?? [] {
                if let at = instruction["address"] as? String { addresses.insert(at) }
            }
            functions[position] = function
        }
        guard !stripped.isEmpty else { return nothing }
        object["functions"] = functions
        if let symbols = object["symbols"] as? [[String: Any]] {
            object["symbols"] = symbols.filter { !stripped.contains($0["address"] as? String ?? "") }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) else {
            return nothing
        }
        nothing = Stripped(artifact: data, functions: stripped, addresses: addresses)
        return nothing
    }

    /// The review document without what it says of those functions: their
    /// decisions, and the comments written at their instructions.
    public static func stripReview(_ document: Data, of stripped: Stripped) -> Data {
        guard !stripped.functions.isEmpty,
              var object = (try? JSONSerialization.jsonObject(with: document)) as? [String: Any] else { return document }
        if var functions = object["functions"] as? [String: Any] {
            for key in stripped.functions { functions[key] = nil }
            object["functions"] = functions
        }
        if let comments = object["comments"] as? [[String: Any]] {
            object["comments"] = comments.filter { !stripped.addresses.contains($0["address"] as? String ?? "") }
        }
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? document
    }
}
