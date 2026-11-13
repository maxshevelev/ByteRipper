import Foundation
import UEFIImage

/// Which Intel microcode updates serve several CPUIDs: the extended signature
/// tables of the updates the catalogue holds.
///
/// One update can name, after its data, more processors than the one in its
/// header (Intel SDM vol. 3A, §10.11.2) — the same bytes for each. The
/// collection the catalogue is read from files such an update once under each
/// of them, `cpuB06F2_…` and `cpuB06F5_…`, and its file names say nothing of
/// the rest. that repository's `microcode_signatures.py`
/// reads the files at one commit into `github.com/maxshevelev/IntelCPUID`,
/// which the app reads at run time (`ProcessorTables`), so the form and the
/// processors popover can say it without downloading a microcode.
///
/// A file newer than that commit is matched by what its name says of the
/// update — revision, date, platforms and size, which a copy keeps — and one
/// that matches nothing has no extended CPUIDs said for it: unknown, not none.
public struct MicrocodeSignatures: Sendable {
    /// One update that serves several CPUIDs.
    public struct Update: Equatable, Sendable, Decodable {
        public struct Signature: Equatable, Sendable, Decodable {
            /// Five hex digits, as the file name writes it.
            public var cpuid: String
            /// The platform ids for that CPUID, as a two-digit mask.
            public var platforms: String
        }
        /// Hexadecimal, without leading zeros, as the catalogue writes it.
        public var revision: String
        /// `2025-10-12`, from the header.
        public var date: String
        public var signatures: [Signature]
        /// The collection's copies of the update, one per CPUID it serves.
        public var files: [String]
    }

    public var updates: [Update]

    public init(updates: [Update]) {
        self.updates = updates
        for (index, update) in updates.enumerated() {
            for file in update.files { byFile[file] = index }
        }
    }

    private var byFile: [String: Int] = [:]

    /// The table as last read from `github.com/maxshevelev/IntelCPUID`
    /// (`ProcessorTables`): empty until a copy has been read.
    public static var current: MicrocodeSignatures { ProcessorTables.current.microcode }

    /// The update a catalogue file is a copy of, where it serves several
    /// CPUIDs: by its path, or else by what its name says of the update.
    public func update(for entry: MicrocodeCatalogueEntry) -> Update? {
        guard entry.vendor == .intel else { return nil }
        if let index = byFile[entry.path] { return updates[index] }
        // A copy the table has not seen: same revision, date and
        // platforms as one it has, under a CPUID that update names.
        return updates.first { update in
            update.revision == entry.revisionText && update.date == entry.date
                && update.signatures.contains {
                    $0.cpuid == entry.cpuidText
                        && UInt32($0.platforms, radix: 16) == entry.platformID
                }
        }
    }

    /// The other CPUIDs a catalogue file's update serves, in the update's
    /// order, each once. Empty for an update that serves one.
    public func extendedCPUIDs(of entry: MicrocodeCatalogueEntry) -> [String] {
        guard let update = update(for: entry) else { return [] }
        var seen: Set<String> = [entry.cpuidText]
        return update.signatures.map(\.cpuid).filter { seen.insert($0).inserted }
    }

    /// The CPUIDs that share a microcode update with this one: those of the
    /// newest update that serves it and others, without it, each once.
    public func sharing(_ cpuid: UInt32) -> [String] {
        let text = MicrocodeHeader.cpuid(cpuid)
        let newest = updates
            .filter { $0.signatures.contains { $0.cpuid == text } }
            .max { $0.date < $1.date }
        guard let newest else { return [] }
        var seen: Set<String> = [text]
        return newest.signatures.map(\.cpuid).filter { seen.insert($0).inserted }
    }
}
