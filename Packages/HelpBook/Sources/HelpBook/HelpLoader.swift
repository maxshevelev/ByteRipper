import Foundation
import Localization

/// Reads the book off disk.
///
/// The language is a *directory*, not an `.lproj` bundle: `Help/en/Topics/…`,
/// `Help/de/Topics/…`. Adding German is adding `Help/de` with the same file
/// names in it — no manifest to edit, no build setting, and a file that has not
/// been translated yet falls back to the one in `Help/en` rather than leaving a
/// blank page.
public enum HelpLoader {
    /// The language every file exists in, and what a half-translated book falls
    /// back to word by word.
    public static let fallbackLanguage = "en"

    /// The directory the resources live under, inside whichever bundle holds
    /// them.
    static let root = "Help"

    public enum LoadError: Error, CustomStringConvertible {
        case noResources
        case missingTopic(HelpTopicID)

        public var description: String {
            switch self {
            case .noResources: return "the help resources are missing from the bundle"
            case .missingTopic(let id): return "no help page for \(id.rawValue)"
            }
        }
    }

    /// The book in `language`, from the package's own bundle.
    ///
    /// Which language that is has one answer for the whole app and it is not
    /// this package's to give: `Localization.resolvedLanguage()` combines the
    /// Mac's own languages with the user's override in Settings, and `Help`
    /// asks it. This takes the answer, so a test can load any language it
    /// likes without moving the app's setting.
    ///
    /// A language with no directory of its own falls back to English rather
    /// than throwing: the app may ship a translated UI before its help has
    /// caught up, and an English page is worth more than no page.
    public static func load(language: String, bundle: Bundle? = nil) throws -> HelpBook {
        // `Bundle.module` is internal to the target, so it cannot stand as a
        // default argument of a public function — it is resolved here instead.
        guard let base = (bundle ?? .module).url(forResource: root, withExtension: nil) else {
            throw LoadError.noResources
        }
        let available = (try? FileManager.default.contentsOfDirectory(
            at: base, includingPropertiesForKeys: nil
        ))?.filter(\.hasDirectoryPath).map { $0.lastPathComponent } ?? []
        return try load(language: available.contains(language) ? language : fallbackLanguage,
                        base: base)
    }

    static func load(language: String, base: URL) throws -> HelpBook {
        let directory = base.appendingPathComponent(language, isDirectory: true)
        let fallback = base.appendingPathComponent(fallbackLanguage, isDirectory: true)

        /// One file, from the reader's language or — when that language has not
        /// got to it yet — from English.
        func read(_ path: String) -> String? {
            for folder in [directory, fallback] {
                let url = folder.appendingPathComponent(path)
                if let text = try? String(contentsOf: url, encoding: .utf8) { return text }
            }
            return nil
        }

        let sectionNames = HelpSectionFile.parse(read("Sections.md") ?? "")
        let sections = HelpContents.sections.map { section in
            HelpSection(id: section.id,
                        // A section whose name nobody wrote reads as its id:
                        // ugly, and visibly so, which is the point — the tests
                        // catch it first.
                        name: sectionNames[section.id] ?? section.id,
                        topics: section.topics)
        }

        var topics: [HelpTopic] = []
        for id in HelpContents.allTopics {
            guard let text = read("Topics/\(id.rawValue).md") else {
                throw LoadError.missingTopic(id)
            }
            topics.append(HelpTopicFile.parse(text, id: id))
        }

        let terms = HelpTermGroup.allCases.flatMap { group in
            HelpTermFile.parse(read("Terms/\(group.rawValue).md") ?? "", group: group)
        }

        let glossaryNames = Dictionary(uniqueKeysWithValues: HelpTermGroup.allCases.compactMap {
            group -> (HelpTermGroup, String)? in
            sectionNames["glossary-" + group.rawValue].map { (group, $0) }
        })
        return HelpBook(language: language, sections: sections, topics: topics,
                        terms: terms, glossaryNames: glossaryNames)
    }
}

/// `Sections.md`: the contents' group names, which are words and so translate,
/// keyed by the ids `HelpContents` holds.
///
///     @section getting-started
///     @name Getting started
enum HelpSectionFile {
    static func parse(_ source: String) -> [String: String] {
        var names: [String: String] = [:]
        var current: String?
        for line in source.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let id = value(of: "@section", in: trimmed) {
                current = id
            } else if let name = value(of: "@name", in: trimmed), let id = current {
                names[id] = name
            }
        }
        return names
    }

    /// The text after a `@keyword` on its own line, or nil when the line is
    /// something else.
    static func value(of keyword: String, in line: String) -> String? {
        guard line.hasPrefix(keyword + " ") else { return nil }
        return String(line.dropFirst(keyword.count + 1)).trimmingCharacters(in: .whitespaces)
    }
}

/// A page: `# Title` on the first line, an optional `> ` summary, then markup.
///
/// Lines beginning `@` are **metadata, not prose** — `@covers` names the piece
/// of functionality this page explains (`Skills/help-coverage`) and
/// `@source-sha` records the English a translation was made from. They are
/// read out here and never reach the reader: a page is judged on what it says,
/// and the bookkeeping that keeps it honest is not part of that.
enum HelpTopicFile {
    static func parse(_ source: String, id: HelpTopicID) -> HelpTopic {
        var title = ""
        var summary = ""
        var body: [String] = []
        var covers: [String] = []
        var inHeader = true

        for line in source.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let anchor = HelpSectionFile.value(of: "@covers", in: trimmed) {
                covers.append(anchor)
                continue
            }
            if trimmed.hasPrefix("@") { continue }
            if inHeader {
                if trimmed.isEmpty { continue }
                if title.isEmpty, trimmed.hasPrefix("# ") {
                    title = String(trimmed.dropFirst(2))
                    continue
                }
                if summary.isEmpty, trimmed.hasPrefix("> ") {
                    summary = String(trimmed.dropFirst(2))
                    continue
                }
                inHeader = false
            }
            body.append(line)
        }
        return HelpTopic(id: id,
                         title: title.isEmpty ? id.rawValue : title,
                         summary: summary,
                         blocks: HelpMarkup.parse(body.joined(separator: "\n")),
                         covers: covers)
    }
}

/// A glossary file: one `@term` block per word.
///
///     @term fpt
///     @name Flash Partition Table (`$FPT`)
///     @short The list of what is in the ME region and where.
///
///     Body, in the same markup as a page.
///
///     @see term:cpd
enum HelpTermFile {
    static func parse(_ source: String, group: HelpTermGroup) -> [HelpTerm] {
        var terms: [HelpTerm] = []
        var id: String?
        var name = ""
        var short = ""
        var seeAlso: [HelpLink] = []
        var body: [String] = []

        func flush() {
            guard let current = id else { return }
            terms.append(HelpTerm(id: HelpTermID(current),
                                  name: name.isEmpty ? current : name,
                                  summary: short,
                                  blocks: HelpMarkup.parse(body.joined(separator: "\n")),
                                  seeAlso: seeAlso,
                                  group: group))
            id = nil
            name = ""
            short = ""
            seeAlso = []
            body = []
        }

        for line in source.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let next = HelpSectionFile.value(of: "@term", in: trimmed) {
                flush()
                id = next
            } else if let value = HelpSectionFile.value(of: "@name", in: trimmed) {
                name = value
            } else if let value = HelpSectionFile.value(of: "@short", in: trimmed) {
                short = value
            } else if let value = HelpSectionFile.value(of: "@see", in: trimmed) {
                if let link = parseLink(value) { seeAlso.append(link) }
            } else if trimmed.hasPrefix("@") {
                // Metadata (`@covers`, `@source-sha`): read by the coverage
                // script, never shown to a reader.
                continue
            } else if id != nil {
                body.append(line)
            }
        }
        flush()
        return terms
    }

    /// `term:fpt` / `topic:tool-me`, the same two forms an inline link takes.
    static func parseLink(_ text: String) -> HelpLink? {
        guard let colon = text.firstIndex(of: ":") else { return nil }
        let id = String(text[text.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty else { return nil }
        switch text[text.startIndex..<colon] {
        case "topic": return .topic(HelpTopicID(id))
        case "term": return .term(HelpTermID(id))
        default: return nil
        }
    }
}
