import Cocoa
import IntelCPUID
import Localization

/// What the lookup window says over its table for a query that is one CPUID:
/// the entry's code names, steppings, product families, segments, cores and
/// number of models; the microcode updates it shares with other CPUIDs, each
/// a link that looks that CPUID up; and, for an entry the article lacks, the
/// repository's note and the pages its facts were read from.
///
/// The note and the pages are folded under a line that opens them — unless
/// the table below is empty, when they are all the window has to say.
enum CPUIDHeadingText {
    /// `cpuid:B06F5`: look this CPUID up.
    static let lookUpScheme = "cpuid"
    /// `cpuidsection:notes-0-B06F5`: open or fold a section. Neither has a
    /// host, so neither is lowercased on the way back (`argument(of:)`).
    static let toggleScheme = "cpuidsection"

    /// What follows the scheme, as written.
    static func argument(of url: URL) -> String {
        String(url.absoluteString.drop { $0 != ":" }.dropFirst())
    }

    @MainActor
    static func make(_ headings: [CPUIDLookup.Heading], opened: Set<String>, expanded: Bool) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let body = NSFont.systemFont(ofSize: 13)
        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacing = 2
        let facts = NSMutableParagraphStyle()
        facts.tabStops = [NSTextTab(textAlignment: .left, location: 150)]
        facts.headIndent = 150
        facts.paragraphSpacing = 1
        let plain: [NSAttributedString.Key: Any] = [.font: body, .foregroundColor: NSColor.labelColor,
                                                    .paragraphStyle: paragraph]
        let muted: [NSAttributedString.Key: Any] = [.font: body, .foregroundColor: NSColor.secondaryLabelColor,
                                                    .paragraphStyle: paragraph]
        let mono = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

        func add(_ text: String, _ attributes: [NSAttributedString.Key: Any]) {
            out.append(NSAttributedString(string: text, attributes: attributes))
        }
        func cpuidLink(_ cpuid: String) -> NSAttributedString {
            NSAttributedString(string: cpuid, attributes: [
                .font: mono, .link: URL(string: "\(lookUpScheme):\(cpuid)")!, .paragraphStyle: facts
            ])
        }
        func fact(_ label: String, _ value: NSAttributedString) {
            add(label + "\t", [.font: body, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: facts])
            out.append(value)
            add("\n", plain)
        }
        func fact(_ label: String, _ values: [String]) {
            guard !values.isEmpty else { return }
            fact(label, NSAttributedString(string: values.joined(separator: ", "), attributes: [
                .font: body, .foregroundColor: NSColor.labelColor, .paragraphStyle: facts
            ]))
        }
        func fold(_ key: String, _ title: String, open: Bool) {
            add((open ? "▾ " : "▸ "), muted)
            out.append(NSAttributedString(string: title, attributes: [
                .font: body, .link: URL(string: "\(toggleScheme):\(key)")!, .paragraphStyle: paragraph
            ]))
            add("\n", plain)
        }

        for (index, heading) in headings.enumerated() {
            if index > 0 { add("\n", plain) }
            add(heading.cpuids.joined(separator: ", "),
                [.font: NSFont.monospacedSystemFont(ofSize: 16, weight: .bold), .foregroundColor: NSColor.labelColor])
            add("  ·  ", muted)
            if let family = heading.family {
                add(family.codeNames.joined(separator: ", "),
                    [.font: NSFont.systemFont(ofSize: 15, weight: .semibold), .foregroundColor: NSColor.labelColor])
                if heading.cpuids.contains(where: { $0.contains("X") }) {
                    add("  (" + L("X stands for any digit") + ")", muted)
                }
            } else {
                add(L("not in the table"), [.font: NSFont.systemFont(ofSize: 15), .foregroundColor: NSColor.secondaryLabelColor])
            }
            add("\n", plain)

            if let family = heading.family {
                fact(L("Steppings"), family.steppings)
                fact(L("Product family"), family.productFamilies)
                fact(L("Segment"), family.segments)
                fact(L("Cores"), family.cores)
                fact(L("Models"), [String(family.processors.count)])
            }
            if !heading.shared.isEmpty {
                let value = NSMutableAttributedString()
                for (k, shared) in heading.shared.enumerated() {
                    if k > 0 { value.append(NSAttributedString(string: "\n", attributes: plain)) }
                    let others = NSMutableAttributedString()
                    for (n, cpuid) in shared.others.enumerated() {
                        if n > 0 { others.append(NSAttributedString(string: ", ", attributes: plain)) }
                        others.append(cpuidLink(cpuid))
                    }
                    let line = L("update %1$@ of %2$@ also serves %3$@", "0x" + shared.update.revision,
                                 shared.update.date, "\u{FFFC}")
                    let parts = line.components(separatedBy: "\u{FFFC}")
                    value.append(NSAttributedString(string: parts[0], attributes: [
                        .font: body, .foregroundColor: NSColor.labelColor, .paragraphStyle: facts]))
                    value.append(others)
                    if parts.count > 1 {
                        value.append(NSAttributedString(string: parts[1], attributes: [
                            .font: body, .foregroundColor: NSColor.labelColor, .paragraphStyle: facts]))
                    }
                }
                fact(L("Shared microcode"), value)
            }
            if heading.family == nil {
                add(L("The table has no entry for this CPUID.") + "\n", muted)
            }

            // URL-safe: hex digits, X and the heading's place.
            let id = "\(index)-" + heading.cpuids.joined(separator: "_")
            if let note = heading.notes?.note, !note.isEmpty {
                let key = "notes-" + id
                let open = expanded || opened.contains(key)
                fold(key, L("Notes (in English)"), open: open)
                if open { add(note + "\n", plain) }
            }
            if let sources = heading.notes?.sources, !sources.isEmpty {
                let key = "sources-" + id
                let open = expanded || opened.contains(key)
                fold(key, L("Sources (%1$@)", String(sources.count)), open: open)
                if open {
                    for source in sources {
                        add("•  ", muted)
                        if let url = URL(string: source.url) {
                            out.append(NSAttributedString(string: url.host ?? source.url, attributes: [
                                .font: body, .link: url, .toolTip: source.url, .paragraphStyle: paragraph
                            ]))
                        } else {
                            add(source.url, plain)
                        }
                        add("  " + source.quote + "\n",
                            [.font: NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular),
                             .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: paragraph])
                    }
                }
            }
        }
        return out
    }
}
