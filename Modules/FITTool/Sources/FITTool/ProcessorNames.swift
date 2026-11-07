import Foundation
import Localization
import UEFIImage

/// One group of processors that share a CPUID, as the table of brand names
/// lists it (`Resources/IntelCPUIDBrandNames.json`,
/// `Skills/update-cpuid-brand-names/scripts/import.py`).
public struct ProcessorFamily: Equatable, Sendable, Decodable {
    /// As written: five hex digits, or a pattern with an `X` for any one digit
    /// (`606AX`).
    public var cpuids: [String]
    public var codeNames: [String]
    public var productFamilies: [String]
    public var steppings: [String]
    public var segments: [String]
    public var processors: [ProcessorModel]
    /// The architectures of its cores — `Golden Cove`, `Gracemont` — which the
    /// article writes in brackets after a code name and the generator moves
    /// here. Empty where the article names none.
    public var cores: [String] = []

    /// Whether `cpuid` — as `MicrocodeHeader.cpuid` writes it — is one of this
    /// group's.
    public func matches(_ cpuid: String) -> Bool {
        cpuids.contains { pattern in
            pattern.count == cpuid.count && zip(pattern, cpuid).allSatisfy { $0 == "X" || $0 == $1 }
        }
    }
}

/// One model: its name, and the S-SPECs it is sold under with this CPUID.
public struct ProcessorModel: Equatable, Sendable, Decodable {
    public var name: String
    public var sSpec: [String]
    /// Where a code that is not the article's came from: `ark`, `wikipedia`,
    /// or what `Skills/find-sspec` found — `intel`, `database`, `marking`.
    public var sSpecSource: [String: String]?
    /// A line that names a series rather than its models.
    public var series: Bool?
}

/// Which processors a microcode is for, by its CPUIDs.
///
/// The list is the one table Intel's own documents do not give in one place;
/// it is incomplete and its source says so. A CPUID it does not know is
/// said to be unknown, never guessed from a neighbour.
public enum ProcessorNames {
    /// The table shipped in this package, read once.
    public static let shipped: [ProcessorFamily] = {
        struct File: Decodable { var entries: [ProcessorFamily] }
        guard let url = Bundle.module.url(forResource: "IntelCPUIDBrandNames", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data)
        else { return [] }
        return file.entries
    }()

    /// The groups for these processor signatures, in the order the signatures
    /// come — the header's own first — and each group once.
    public static func families(
        for signatures: [UInt32], in catalogue: [ProcessorFamily] = shipped
    ) -> [ProcessorFamily] {
        var found: [ProcessorFamily] = []
        for signature in signatures {
            let cpuid = MicrocodeHeader.cpuid(signature)
            for family in catalogue where family.matches(cpuid) && !found.contains(family) {
                found.append(family)
            }
        }
        return found
    }
}

/// The processors behind one CPUID of a microcode: what its row in the
/// panel's tree says, and what the popover off the row's `ⓘ` lists. The
/// processors are not rows of the tree: they are not part of the update, only
/// what is known about who runs it.
public struct FITProcessorGroup: Equatable, Sendable {
    /// Five hex digits, as a bench writes it.
    public var cpuid: String
    /// The code names of the groups the table has for this CPUID, said beside
    /// it on its row — the one thing that tells two CPUIDs of one update apart
    /// at a glance. Empty when nothing is known.
    public var codeNames: [String]
    /// What the table says of each group, one note a group: its code names,
    /// its product families, then the cores' architectures, the stepping and
    /// the segments — a line each. The popover says a CPUID's one group at its
    /// head; where there are several, each is said over its own models, by
    /// the line that names it. Empty when nothing is known.
    public var notes: [String] = []
    /// The popover's list: the models, each with its S-SPECs — under a line
    /// naming its group, and saying the rest of its note, where the CPUID has
    /// more than one.
    public var lines: [FITProcessorLine]

    /// One group per signature, in the order the update names them — the
    /// header's own first. A CPUID the table does not know is a group of one
    /// line that says so.
    public static func groups(
        for signatures: [UInt32], in catalogue: [ProcessorFamily] = ProcessorNames.shipped,
        language: AppLanguage
    ) -> [FITProcessorGroup] {
        signatures.map { signature in
            let cpuid = MicrocodeHeader.cpuid(signature)
            let families = ProcessorNames.families(for: [signature], in: catalogue)
            guard !families.isEmpty else {
                return FITProcessorGroup(cpuid: cpuid, codeNames: [], notes: [], lines: [
                    .init(kind: .unknown,
                          text: L("No processor names known for CPUID %1$@", in: language, cpuid),
                          detail: "")
                ])
            }
            var lines: [FITProcessorLine] = []
            var notes: [String] = []
            for family in families {
                notes.append(note(on: family, language: language))
                if families.count > 1 {
                    lines.append(.init(kind: .family, text: family.codeNames.joined(separator: ", "),
                                       detail: facts(of: family, language: language)))
                }
                if family.processors.isEmpty {
                    // A die whose code name is known and no model sold on it
                    // (Grand Ridge's B0660: Intel lists only B0664's).
                    lines.append(.init(kind: .unknown,
                                       text: L("No processor models known for this CPUID", in: language),
                                       detail: ""))
                }
                for model in family.processors {
                    lines.append(.init(
                        kind: .model,
                        text: FITProcessorLine.shortName(model.name),
                        detail: model.series == true
                            ? L("series, models not listed", in: language)
                            : model.sSpec.joined(separator: ", ")
                    ))
                }
            }
            return FITProcessorGroup(cpuid: cpuid, codeNames: families.flatMap(\.codeNames),
                                     notes: notes, lines: lines)
        }
    }

    /// A group's note: its code names; its product families; and its cores —
    /// a hybrid's two kinds as one part, P + E — stepping and segments on one
    /// line. A line with nothing to say is left out.
    static func note(on family: ProcessorFamily, language: AppLanguage) -> String {
        [family.codeNames.joined(separator: ", "), facts(of: family, language: language)]
            .filter { !$0.isEmpty }.joined(separator: "\n")
    }

    /// A group's note without its names: what the line naming it says under
    /// them.
    static func facts(of family: ProcessorFamily, language: AppLanguage) -> String {
        let cores = family.cores.isEmpty ? [] : [family.cores.joined(separator: " + ")]
        let stepping = family.steppings.isEmpty
            ? [] : [L("Stepping %1$@", in: language, family.steppings.joined(separator: ", "))]
        return [family.productFamilies.joined(separator: ", "),
                (cores + stepping + family.segments).joined(separator: " · ")]
            .filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

/// A line of the popover's list: a model the table of brand names lists for
/// the CPUID, or the name of its group.
public struct FITProcessorLine: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// The code names of the group the models after it belong to, and the
        /// rest of its note as the detail — only where the CPUID has more
        /// than one group.
        case family
        /// One model, with its S-SPECs as the detail.
        case model
        /// Nothing is known for this CPUID.
        case unknown
    }

    public var kind: Kind
    public var text: String
    /// Said after the text, quieter: the S-SPECs of a model.
    public var detail: String

    /// Every name is Intel's, so the word says nothing in a list of them.
    static func shortName(_ name: String) -> String {
        name.hasPrefix("Intel ") ? String(name.dropFirst(6)) : name
    }
}
