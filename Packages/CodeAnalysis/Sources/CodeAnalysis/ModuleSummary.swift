import Foundation

/// The summary of a module description: the paragraph under its `# <Module>`
/// title and before the first `## ` section (`reference/description.md`,
/// "`# <ModuleName>` and the summary") — what someone reads who reads nothing
/// else. The UEFI tree shows it beside a module's file without opening the
/// code.
public enum ModuleSummary {
    /// The summary of `description` as plain text: its lines joined, the
    /// paragraphs kept apart by a blank line, the inline Markdown taken off
    /// (`code`, **bold**, *italic*, ~~struck~~, [text](target) → text). Nil
    /// when the description has no text before its first section.
    public static func of(description: String) -> String? {
        var paragraphs: [[String]] = [[]]
        var seenTitle = false
        for raw in description.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("## ") || line == "##" { break }
            if line.hasPrefix("# ") || line == "#" {
                // The title; a second one would be a section the rules do not
                // have, and ends the summary as well.
                if seenTitle { break }
                seenTitle = true
                continue
            }
            if line.isEmpty {
                if !(paragraphs.last ?? []).isEmpty { paragraphs.append([]) }
                continue
            }
            paragraphs[paragraphs.count - 1].append(line)
        }
        let text = paragraphs.filter { !$0.isEmpty }
            .map { plain($0.joined(separator: " ")) }
            .joined(separator: "\n\n")
        return text.isEmpty ? nil : text
    }

    /// `text` with its inline Markdown taken off.
    static func plain(_ text: String) -> String {
        var result = text
        // [text](target) → text
        result = result.replacingOccurrences(of: #"\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        for mark in ["**", "__", "~~"] {
            result = result.replacingOccurrences(of: mark, with: "")
        }
        result = result.replacingOccurrences(of: "`", with: "")
        // *italic* and _italic_, only around a word, so `a * b` and
        // `Name_With_Underscores` stay as they are.
        result = result.replacingOccurrences(of: #"(?<![\w*])\*(?=\S)([^*]+?)(?<=\S)\*(?![\w*])"#, with: "$1",
                                             options: .regularExpression)
        result = result.replacingOccurrences(of: #"(?<![\w_])_(?=\S)([^_]+?)(?<=\S)_(?![\w_])"#, with: "$1",
                                             options: .regularExpression)
        return result
    }
}
