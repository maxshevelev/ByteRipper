import Foundation

/// One group of processors that share a CPUID, as the table of brand names
/// lists it — `IntelCPUIDBrandNames.json` of `github.com/maxshevelev/IntelCPUID`,
/// read at run time (`ProcessorTables`) and generated there by its
/// `update-cpuid-brand-names` skill.
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

    public init(cpuids: [String], codeNames: [String], productFamilies: [String] = [], steppings: [String] = [],
                segments: [String] = [], processors: [ProcessorModel] = [], cores: [String] = []) {
        self.cpuids = cpuids
        self.codeNames = codeNames
        self.productFamilies = productFamilies
        self.steppings = steppings
        self.segments = segments
        self.processors = processors
        self.cores = cores
    }

    private enum CodingKeys: String, CodingKey {
        case cpuids, codeNames, productFamilies, steppings, segments, processors, cores
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        cpuids = try c.decode([String].self, forKey: .cpuids)
        codeNames = try c.decode([String].self, forKey: .codeNames)
        productFamilies = try c.decode([String].self, forKey: .productFamilies)
        steppings = try c.decode([String].self, forKey: .steppings)
        segments = try c.decode([String].self, forKey: .segments)
        processors = try c.decode([ProcessorModel].self, forKey: .processors)
        cores = try c.decodeIfPresent([String].self, forKey: .cores) ?? []
    }

    /// Whether `cpuid` — five hex digits, upper case, as a microcode header's
    /// signature is written — is one of this group's.
    public func matches(_ cpuid: String) -> Bool {
        cpuids.contains { pattern in
            pattern.count == cpuid.count && zip(pattern, cpuid).allSatisfy { $0 == "X" || $0 == $1 }
        }
    }

    /// What names this group among the others with a CPUID of its: its CPUIDs
    /// and code names, as the generator's notes are keyed (`EntryNotes`).
    public var key: String { cpuids.joined(separator: ",") + "|" + codeNames.joined(separator: ",") }
}

/// One model: its name, and the S-SPECs it is sold under with this CPUID.
public struct ProcessorModel: Equatable, Sendable, Decodable {
    public var name: String
    public var sSpec: [String]
    /// Where a code that is not the article's came from: `ark`, `wikipedia`,
    /// or what IntelCPUID's `find-sspec` found — `intel`, `database`, `marking`.
    public var sSpecSource: [String: String]?
    /// A line that names a series rather than its models.
    public var series: Bool?

    public init(name: String, sSpec: [String] = [], sSpecSource: [String: String]? = nil, series: Bool? = nil) {
        self.name = name
        self.sSpec = sSpec
        self.sSpecSource = sSpecSource
        self.series = series
    }

    private enum CodingKeys: String, CodingKey { case name, sSpec, sSpecSource, series }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        sSpec = try c.decodeIfPresent([String].self, forKey: .sSpec) ?? []
        sSpecSource = try c.decodeIfPresent([String: String].self, forKey: .sSpecSource)
        series = try c.decodeIfPresent(Bool.self, forKey: .series)
    }

    /// Every name is Intel's, so the word says nothing in a list of them.
    public var shortName: String { name.hasPrefix("Intel ") ? String(name.dropFirst(6)) : name }
}

/// What the repository says of a group beyond the table: the note on a CPUID
/// the article lacks, and the pages each of its facts was read from. Kept in
/// the generator's `extra-entries.json`, which the lookup page reads too; a
/// group the article has carries none.
public struct EntryNotes: Equatable, Sendable, Decodable {
    public struct Evidence: Equatable, Sendable, Decodable {
        public var url: String
        public var quote: String
        /// What the page gives the entry — `cpuids`, `steppings`, `processors`.
        public var gives: [String]

        public init(url: String, quote: String, gives: [String]) {
            self.url = url
            self.quote = quote
            self.gives = gives
        }

        private enum CodingKeys: String, CodingKey { case url, quote, gives }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            url = try c.decode(String.self, forKey: .url)
            quote = try c.decodeIfPresent(String.self, forKey: .quote) ?? ""
            gives = try c.decodeIfPresent([String].self, forKey: .gives) ?? []
        }
    }

    /// In English, as the generator writes it.
    public var note: String?
    public var evidence: [Evidence]

    public init(note: String?, evidence: [Evidence]) {
        self.note = note
        self.evidence = evidence
    }

    /// The pages that say something of the CPUID itself: a page that only
    /// lists models is a source of the table below, not of the entry.
    public var sources: [Evidence] { evidence.filter { $0.gives != ["processors"] } }
}
