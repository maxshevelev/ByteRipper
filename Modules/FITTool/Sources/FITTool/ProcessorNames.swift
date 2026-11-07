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
    /// Where a code that is not the article's came from: `ark` or `wikipedia`.
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

/// The processors behind one CPUID of a microcode: what its node in the
/// panel's tree says, and the lines it opens into.
public struct FITProcessorGroup: Equatable, Sendable {
    /// Five hex digits, as a bench writes it.
    public var cpuid: String
    /// The code names of the groups the table has for this CPUID, said beside
    /// it when the microcode serves several — the one thing that tells two
    /// CPUIDs of one update apart at a glance. Empty when nothing is known.
    public var codeNames: [String]
    /// What the table says of the groups besides their names — the cores'
    /// architectures, the stepping, the segments — one line a group. The
    /// panel puts it under the pointer on the CPUID's row rather than on a
    /// row of its own. A line leads with its group's code names only where
    /// the CPUID has more than one group, since the row already says them.
    public var notes: [String] = []
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
                // A hybrid's two kinds of core read as one part: P + E.
                let cores = family.cores.isEmpty ? [] : [family.cores.joined(separator: " + ")]
                let note = (cores + family.steppings + family.segments).joined(separator: " · ")
                if families.count > 1 {
                    notes.append(family.codeNames.joined(separator: ", ") + (note.isEmpty ? "" : ": " + note))
                } else if !note.isEmpty {
                    notes.append(note)
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
}

/// A line under a CPUID: a model the table of brand names lists for it.
public struct FITProcessorLine: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
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
