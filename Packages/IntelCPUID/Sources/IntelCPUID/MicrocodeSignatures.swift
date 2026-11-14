import Foundation

/// Which Intel microcode updates serve several CPUIDs: the extended signature
/// tables of the updates platomav/CPUMicrocodes holds.
///
/// One update can name, after its data, more processors than the one in its
/// header (Intel SDM vol. 3A, §10.11.2) — the same bytes for each. The
/// collection files such an update once under each of them, `cpuB06F2_…` and
/// `cpuB06F5_…`, and its file names say nothing of the rest. IntelCPUID's
/// `microcode_signatures.py` reads the files at one commit into
/// `IntelMicrocodeSignatures.json`, which the app reads at run time
/// (`ProcessorTables`).
public struct MicrocodeSignatures: Sendable {
    /// One update that serves several CPUIDs.
    public struct Update: Equatable, Sendable, Decodable {
        public struct Signature: Equatable, Sendable, Decodable {
            /// Five hex digits, as the file name writes it.
            public var cpuid: String
            /// The platform ids for that CPUID, as a two-digit mask.
            public var platforms: String

            public init(cpuid: String, platforms: String) {
                self.cpuid = cpuid
                self.platforms = platforms
            }
        }
        /// Hexadecimal, without leading zeros, as the catalogue writes it.
        public var revision: String
        /// `2025-10-12`, from the header.
        public var date: String
        public var signatures: [Signature]
        /// The collection's copies of the update, one per CPUID it serves.
        public var files: [String]

        public init(revision: String, date: String, signatures: [Signature], files: [String]) {
            self.revision = revision
            self.date = date
            self.signatures = signatures
            self.files = files
        }

        /// Its CPUIDs other than `cpuids`, in the update's order, each once.
        public func others(than cpuids: [String]) -> [String] {
            var seen = Set(cpuids)
            return signatures.map(\.cpuid).filter { seen.insert($0).inserted }
        }
    }

    public var updates: [Update]
    private var byFile: [String: Int] = [:]

    public init(updates: [Update]) {
        self.updates = updates
        for (index, update) in updates.enumerated() {
            for file in update.files { byFile[file] = index }
        }
    }

    /// The table as last read from `github.com/maxshevelev/IntelCPUID`
    /// (`ProcessorTables`): empty until a copy has been read.
    public static var current: MicrocodeSignatures { ProcessorTables.current.microcode }

    /// The update a file of the collection is a copy of, by its path.
    public func update(file path: String) -> Update? {
        byFile[path].map { updates[$0] }
    }

    /// The updates that serve `cpuid` — five hex digits — among others,
    /// newest first.
    public func updates(serving cpuid: String) -> [Update] {
        updates.filter { $0.signatures.contains { $0.cpuid == cpuid } }.sorted { $0.date > $1.date }
    }

    /// The CPUIDs that share a microcode update with this one: those of the
    /// newest update that serves it and others, without it, each once.
    public func sharing(_ cpuid: String) -> [String] {
        updates(serving: cpuid).first?.others(than: [cpuid]) ?? []
    }

    /// Every CPUID an update names, each once.
    public var cpuids: Set<String> { Set(updates.flatMap { $0.signatures.map(\.cpuid) }) }
}
