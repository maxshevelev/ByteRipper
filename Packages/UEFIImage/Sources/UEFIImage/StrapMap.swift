import Foundation

/// The chipset's own layout of a descriptor's strap section: every field the
/// build can set, the word and bits it takes, and the value Flash Image Tool
/// writes into it when a setting does not override it.
///
/// Nothing in a dump names these fields, and no published specification names
/// them either — `UEFI_IMAGE_FORMAT.md` §2.6 has the section and the length
/// field and stops there. The tables here are Intel's own, taken from the strap
/// layout the Flash Image Tool executables carry
/// (`Skills/me-eom-structures/scripts/strap_map.py`, and
/// `Design/ME_STRUCTURES.md` for what was checked against which dump).
///
/// **A table belongs to a length, not to a generation.** What an image states
/// about its section is how many words it has (`FLMAP1`), and the length is
/// what tells the layouts apart in practice: the 69-word and 74-word sections
/// are the same field for field in every tool that carries them, the two
/// 70-word tables differ only in their defaults and in two spellings, and the
/// tool's documents carry no platform name of their own. So a length that the
/// tools do not agree on is not here at all rather than guessed at — the
/// sections a bench meets are the ones the dumps at hand showed.
///
/// **The generation-keyed sets are FIT 11's SPT tables and the legacy
/// guides'.** SPT's lengths overlap the shared ones — 90 words is a PCH section
/// in both, 3 words a processor section — without being the same section, and
/// the fields carry their CamelCase names. Sunrise Point and Lewisburg read
/// those, and only where the descriptor's generation is certain: an uncertain
/// one is read with the shared tables, which is what every generation had
/// before. The generations before FIT's layout documents — Ibex Peak, Cougar
/// Point and Lynx Point — read flashrom's structures written from Intel's SPI
/// Programming Guides (`intel_strap_map.py`): their sections are 16, 18 and 21
/// words, and a length is only theirs on the generation that states it. On
/// Cougar Point and Lynx Point the tool package's own `newfiletmpl.xml` adds
/// what the guide leaves out — each field's default, the tool's option words,
/// and Lynx Point's words 14 and 19, whose positions the dumps at hand read
/// back; Ibex Peak's package states defaults too, but its table is the guide's
/// alone until its template is read.
public struct DescriptorStrapMap: Sendable {
    /// One named field of the section: where it sits and what the tool writes
    /// there by default. The name is the tool's own identifier —
    /// `PCH_Strap_SPI_ec_max_freq` — in every language, as the ME Analyzer
    /// project's labels are, so that it can be looked up in the tool.
    public struct Field: Sendable, Equatable {
        public var name: String
        public var word: Int
        public var bits: ClosedRange<Int>
        /// What the tool builds the strap with: its default for the field, not
        /// the chipset's reset value, which is not documented anywhere. Nil
        /// where the document states values per reference platform rather than
        /// a default — the CPU strap message's layout does — and no value is
        /// claimed for it.
        public var defaultValue: UInt32?
        /// What the tool's panel calls the field, where the document says —
        /// "Disable Hyperthreading" for `CPU_Strap_SMT_Disable`. Nil for the
        /// tables emitted from layout entries that carry no interface text,
        /// and the panel then shows the identifier.
        public var label: String?
        /// The words a value may stand for, where the tool states them —
        /// `0: No, 1: Yes` for a `no_yes_options` field. Nil otherwise, and
        /// the panel shows the number.
        public var options: [Int: String]?

        public init(name: String, word: Int, bits: ClosedRange<Int>,
                    defaultValue: UInt32? = nil, label: String? = nil,
                    options: [Int: String]? = nil) {
            self.name = name
            self.word = word
            self.bits = bits
            self.defaultValue = defaultValue
            self.label = label
            self.options = options
        }

        /// The bits of `word` this field takes, as the number they stand for.
        public func value(in word: UInt32) -> UInt32 {
            let width = bits.upperBound - bits.lowerBound + 1
            let mask: UInt32 = width >= 32 ? .max : (1 << UInt32(width)) - 1
            return word >> UInt32(bits.lowerBound) & mask
        }
    }

    /// A field with what an image's own section holds there.
    public struct Reading: Sendable, Equatable {
        public var field: Field
        public var value: UInt32

        /// The image does not leave the field at the value the tool builds
        /// with: its own build set it. A table that states no default has
        /// nothing to compare against, and no field of it is emphasised.
        public var isSet: Bool { field.defaultValue.map { value != $0 } ?? false }

        public init(field: Field, value: UInt32) {
            self.field = field
            self.value = value
        }
    }

    /// The name of the document the table was read from, where the tool gives
    /// one (`cnp_h_rvp.xml`); the tool and the length otherwise. For people,
    /// not for the screen.
    public var name: String
    /// How many words the section has: what picks this table.
    public var words: Int
    public var fields: [Field]

    public init(name: String, words: Int, fields: [Field]) {
        self.name = name
        self.words = words
        self.fields = fields
    }

    /// The section as its fields, in the table's order — its words, not the
    /// table's, decide how far this reaches: a section cut short by the end of
    /// the descriptor names only the fields still inside it.
    public func readings(in section: [UInt32]) -> [Reading] {
        fields.compactMap { field in
            guard field.word < section.count else { return nil }
            return Reading(field: field, value: field.value(in: section[field.word]))
        }
    }

    /// The fields of one word, in the table's order.
    public func fields(inWord word: Int) -> [Field] {
        fields.filter { $0.word == word }
    }

    /// What the fields of one word have in common, as the tool spells it —
    /// `GPCOM4_gpio_sstrap`, `SPI`, `CSME_SMT1` — or nil where they have
    /// nothing.
    ///
    /// The tool gives a strap word no name of its own: its documents mark the
    /// words with their offsets and nothing else (`<!--Strap: 0x04-->`). But
    /// its field names are the block that owns the field, then the field —
    /// `PCH_Strap_GPCOM4_gpio_sstrap_sataxpcie_0` — and a word's fields belong
    /// to one block, so the words they share say what the word is. Reserved
    /// and spare fields are left out: they are named after their place, not
    /// their block. A word of one named field gives its block, the first word
    /// of the name, and not the field's own name over again.
    public func group(ofWord word: Int) -> String? {
        Self.group(of: fields(inWord: word))
    }

    /// The same, for the fields of one word however they were come by — the
    /// readings of a section carry their fields, not the table.
    public static func group(of fields: [Field]) -> String? {
        let names = fields.map { localName($0.name) }
            .filter { !isReserved($0) }
        guard !names.isEmpty else { return nil }
        let parts = names.map { $0.split(separator: "_", omittingEmptySubsequences: false) }
        // A word of one field gives its block, the first word of the name —
        // but only where the name is underscore-separated. FIT 11's CamelCase
        // spellings (`PchStrapSMB0RQ`) have no block to give, and the word
        // gets no group rather than its field's name over again.
        if parts.count == 1 {
            return parts[0].count > 1 ? String(parts[0][0]) : nil
        }
        var shared = 0
        while parts.allSatisfy({ shared < $0.count && $0[shared] == parts[0][shared] }) {
            shared += 1
        }
        // A prefix that is a whole name is that field, not the word's block.
        if parts.contains(where: { $0.count == shared }) { shared -= 1 }
        guard shared > 0 else { return nil }
        return parts[0].prefix(shared).joined(separator: "_")
    }

    /// A field's name without the section's namespace (`PCH_Strap_`).
    static func localName(_ name: String) -> String {
        guard let range = name.range(of: "_Strap_") else { return name }
        return String(name[range.upperBound...])
    }

    /// A field the tool names after its place rather than its block.
    static func isReserved(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.hasPrefix("rsvd") || lower.hasPrefix("reserved") || lower.hasPrefix("spare")
    }
}

public extension DescriptorStrapMap {
    /// The tables at hand, one per section length — the PCH set first, then
    /// FIT 11's SPT set, which shares some lengths without sharing their
    /// layout. They are read from `StrapMaps.bin` (`StrapMapData`); a resource
    /// that cannot be used leaves the list empty, and the panel then shows a
    /// section's words as numbers.
    static var all: [DescriptorStrapMap] {
        StrapMapData.pchMaps + StrapMapData.sptMaps
    }

    /// SPT's own tables — FIT 11's SPT documents, which name the straps in
    /// CamelCase with no underscore after the prefix and lay some words out
    /// differently from the newer builds (`Num_Active_Cores` is three bits
    /// here, four there). Sunrise Point and Lewisburg read these; every other
    /// generation reads the tables above, keyed by length alone.
    static var sptTables: [DescriptorStrapMap] {
        StrapMapData.sptMaps
    }

    /// Whether the generation's straps are FIT 11's SPT spellings — the
    /// Sunrise Point boards, whose descriptor is the one FIT 11 builds.
    static func usesSPTLayout(_ generation: DescriptorGeneration) -> Bool {
        switch generation {
        case .sunrisePoint, .lewisburg: return true
        default: return false
        }
    }

    /// The PCH table for a section of `words` words on `generation`: SPT's
    /// table set where the board is Sunrise Point or Lewisburg, the legacy
    /// guides' own table where the board is Ibex Peak, Cougar Point or Lynx
    /// Point, the shared ones otherwise. The sets are kept apart because their
    /// lengths overlap (90 words is a section in both) without being the
    /// section, and because the legacy tables are keyed by generation as well
    /// as length: 16, 18 and 21 words belong to those boards' sections, and a
    /// section of one of those lengths is only read when the generation is
    /// certain.
    static func forSection(words: Int,
                           generation: DescriptorGeneration,
                           generationIsCertain: Bool = true) -> DescriptorStrapMap? {
        if generationIsCertain, usesSPTLayout(generation) {
            return sptTables.first { $0.words == words }
        }
        if generationIsCertain, let table = legacyTable(for: generation),
           table.words == words {
            return table
        }
        return forSection(words: words)
    }

    /// The tables of the generations before FIT's layout documents: flashrom's
    /// descriptor structures, written from Intel's SPI Programming Guides
    /// (`intel_strap_map.py`). A section of another length is not theirs.
    static var legacyTables: [DescriptorStrapMap] { [.pch16, .pch18, .pch21] }

    /// The legacy table of a generation, or nil where the generations at hand
    /// have none. Lynx Point's 21-word section is read with the Cougar Point
    /// field set carried forward — `legacy-lpt.json` says why, and which
    /// words that covers.
    static func legacyTable(for generation: DescriptorGeneration)
        -> DescriptorStrapMap? {
        switch generation {
        case .ibexPeak: return .pch16
        case .cougarPoint: return .pch18
        case .lynxPoint: return .pch21
        default: return nil
        }
    }

    /// The layout of a strap section of `words` words, or nil where no tool at
    /// hand carries one: the words then stand as numbers, as they did before,
    /// and nothing about them is claimed.
    static func forSection(words: Int) -> DescriptorStrapMap? {
        all.first { $0.words == words }
    }

    /// The processor strap section's tables, one per length the tools state.
    /// Their layout is the weaker key — the documents of one length can
    /// disagree, and a table carries only what they agree on (`cpu.json`)
    /// — so they are kept apart from the PCH tables above.
    static var processorTables: [DescriptorStrapMap] {
        [.cpu1, .cpu3, .cpu7, .cpu10, .cpu11, .cpu14, .cpu15,
         .cpu17, .cpu18, .cpu20, .cpu21, .cpu22, .cpu25]
    }

    /// The processor section's layout of `words` words, or nil where the tools
    /// state none.
    static func forProcessorSection(words: Int) -> DescriptorStrapMap? {
        processorTables.first { $0.words == words }
    }

    /// SPT's processor table: three words, the Skylake/Kaby section, whose
    /// fields (`CpuStrapHtDisable`, `CpuStrapFlexRatio`) are not the newer
    /// three-word table's.
    static var sptProcessorTables: [DescriptorStrapMap] { [.sptCpu3] }

    /// The processor table for a section of `words` words on `generation`:
    /// SPT's where the board is Sunrise Point or Lewisburg, the shared ones
    /// otherwise. Three words is a section in both sets without being the
    /// same section.
    static func forProcessorSection(
        words: Int, generation: DescriptorGeneration,
        generationIsCertain: Bool = true
    ) -> DescriptorStrapMap? {
        if generationIsCertain, usesSPTLayout(generation) {
            return sptProcessorTables.first { $0.words == words }
        }
        return forProcessorSection(words: words)
    }

    /// The PMC soft straps' tables, keyed by the words the MIP area's PMC and
    /// CPU block holds before the CPU strap message — the block's length less
    /// the message `FLMAP2` states. They are a list of their own: a PMC length
    /// and a PCH one are the same number by accident, never the section.
    static var pmcTables: [DescriptorStrapMap] {
        [.pmc7, .pmc20, .pmc21, .pmc22]
    }

    /// The PMC block's layout of `words` words, or nil where no tool at hand
    /// states one.
    static func forPMC(words: Int) -> DescriptorStrapMap? {
        pmcTables.first { $0.words == words }
    }

    /// The CPU strap **message**'s tables, by length — the form from Tiger
    /// Point on, where the descriptor's MIP area carries the message instead
    /// of a strap section (`mip.json`, from MFIT's `CpuStrapsLayout`). A
    /// message's fields say what they are ("Disable Hyperthreading") and what
    /// their values mean, and state no default: the documents give values per
    /// reference platform.
    static var mipProcessorTables: [DescriptorStrapMap] {
        [.mipCpu17, .mipCpu20]
    }

    /// The message's layout of `words` words, or nil where the tool states none.
    static func forMIPProcessorSection(words: Int) -> DescriptorStrapMap? {
        mipProcessorTables.first { $0.words == words }
    }

    /// The word the SPI controller loads its GPR0 register from — the flash
    /// range the chipset protects from the host. Its name is the tool's, and it
    /// is the same layout word the engine reads as `ProtectedRange`. Nil on a
    /// generation whose table does not carry it.
    var protectedRangeField: Field? {
        fields.first { $0.name.hasSuffix("_SPI_GLOBAL_PROTECTED_RNG_DEF") }
    }

    /// The bits of the word the chipset drives the eSPI bus to the EC at. Nil
    /// where the section's table does not carry it: the clock is a strap of
    /// the desktop layouts, and the 69- and 74-word mobile sections have no
    /// such field at all.
    var espiClockField: Field? {
        fields.first { $0.name.hasSuffix("_SPI_ec_max_freq") }
    }
}
