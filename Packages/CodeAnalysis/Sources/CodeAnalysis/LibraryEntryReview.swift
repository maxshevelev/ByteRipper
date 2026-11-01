import Foundation

/// What a registry entry's review lacks, read from its object alone: the same
/// words a function's gaps use (`name`, `plate`, `comments`, `params`,
/// `locals`, `return`), so a function and the entry it matches can be put side
/// by side in one line. Computed rather than stored: an entry written before
/// this rule reads by it like a new one, and the index needs no field.
///
/// The rules are the analysis's own, without the decompiler
/// (`ExportCode.placeholder` and `undefined`): a name Ghidra invented, a type
/// it could not infer, a missing plate or step comments, a placeholder return
/// type. What names cannot say — a 64-bit value split into two variables —
/// is a reading of the C, and stays one.
public enum LibraryEntryReview {
    /// The words a gap may be, in the order the panel and the tools list them.
    public static let gapWords = ["name", "plate", "comments", "params", "locals", "return"]

    /// The gaps of one entry object, as `put-object` stored it.
    public static func gaps(of entry: Data) -> [String] {
        guard let object = (try? JSONSerialization.jsonObject(with: entry)) as? [String: Any] else {
            return []
        }
        var gaps: [String] = []
        if isPlaceholder(object["name"] as? String) { gaps.append("name") }
        let plate = object["plate"] as? String ?? ""
        if plate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { gaps.append("plate") }
        if (object["comments"] as? [Any] ?? []).isEmpty { gaps.append("comments") }
        let params = object["params"] as? [[String: Any]] ?? []
        if params.contains(where: { isPlaceholder($0["name"] as? String) || isUndefined($0["type"] as? String) }) {
            gaps.append("params")
        }
        let locals = object["locals"] as? [[String: Any]] ?? []
        if locals.contains(where: { local in
            // A register or a value split over registers is the decompiler's
            // piece, as `assess` reads it; a stack slot is the review's.
            guard (local["storage"] as? String ?? "").hasPrefix("Stack") else { return false }
            return isPlaceholder(local["name"] as? String) || isUndefined(local["type"] as? String)
        }) {
            gaps.append("locals")
        }
        if isUndefined(object["return_type"] as? String) { gaps.append("return") }
        return gaps
    }

    /// Ghidra's placeholders — the names that say a review has not passed:
    /// `param_1`, `local_8`, `uVar3`, `FUN_00001000`, `extraout_EAX`,
    /// `in_EAX`, `unaff_EBP`. The function's own name is judged by its symbol
    /// source in the analysis; an entry object keeps only the text.
    public static func isPlaceholder(_ name: String?) -> Bool {
        guard let name, !name.isEmpty else { return true }
        let range = NSRange(name.startIndex..<name.endIndex, in: name)
        return placeholder?.firstMatch(in: name, options: [], range: range) != nil
    }

    /// A type the decompiler could not infer: `undefined`, `undefined4`,
    /// `undefined8`, or none at all.
    public static func isUndefined(_ type: String?) -> Bool {
        guard let type else { return true }
        return type.hasPrefix("undefined")
    }

    /// Whether a prototype's return type is Ghidra's placeholder — `undefined`
    /// or `undefined8` — which no review filled in. A prototype keeps its
    /// return type first, so its first word is that.
    public static func hasPlaceholderReturn(_ signature: String?) -> Bool {
        guard let signature else { return false }
        let returnType = signature.split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
        return returnType.hasPrefix("undefined")
    }

    private static let placeholder: NSRegularExpression? = try? NSRegularExpression(
        pattern: "^(param_\\d+|local_[0-9a-fA-F]+|FUN_[0-9a-fA-F]+|[A-Za-z_][A-Za-z0-9_]*Var\\d+"
            + "|extraout_[A-Z0-9]+|in_[A-Z0-9]+|unaff_[A-Z0-9]+|undefined.*)$")
}
