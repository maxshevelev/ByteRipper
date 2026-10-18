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
        guard parts.count > 1 else { return String(parts[0][0]) }
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
    /// The tables at hand, one per section length.
    static var all: [DescriptorStrapMap] {
        [.pch66, .pch69, .pch70, .pch74, .pch88, .pch90, .pch101, .pch114,
         .pch115, .pch130, .pch139]
    }

    /// The layout of a strap section of `words` words, or nil where no tool at
    /// hand carries one: the words then stand as numbers, as they did before,
    /// and nothing about them is claimed.
    static func forSection(words: Int) -> DescriptorStrapMap? {
        all.first { $0.words == words }
    }

    /// The processor strap section's tables, one per length the tools state.
    /// Their layout is the weaker key — the documents of one length can
    /// disagree, and a table carries only what they agree on (`StrapMap+CPU`)
    /// — so they are kept apart from the PCH tables above.
    static var processorTables: [DescriptorStrapMap] {
        [.cpu1, .cpu3, .cpu7, .cpu10, .cpu14, .cpu15,
         .cpu17, .cpu18, .cpu20, .cpu21, .cpu22, .cpu25]
    }

    /// The processor section's layout of `words` words, or nil where the tools
    /// state none.
    static func forProcessorSection(words: Int) -> DescriptorStrapMap? {
        processorTables.first { $0.words == words }
    }

    /// The CPU strap **message**'s tables, by length — the form from Tiger
    /// Point on, where the descriptor's MIP area carries the message instead
    /// of a strap section (`StrapMap+MIP`, from MFIT's `CpuStrapsLayout`). A
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
