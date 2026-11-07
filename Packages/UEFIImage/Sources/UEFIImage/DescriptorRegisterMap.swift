import Foundation

/// The flash descriptor's registers, field by field — the map words, the flash
/// component's registers, the masters' access masks, the recovery policy and
/// the VSCC/MIP map.
///
/// No published document names these bits; the layouts here are Intel's own,
/// taken from the documents Flash Image Tool carries — MFIT 18's serialized
/// items (`descriptor18_map.py`) and the older builds' platform classes
/// (`descriptor_fit_map.py`). A register is
/// placed either absolutely in the descriptor (`FLMAP0/1/2` at 0x14, `FLDRPLCY`
/// at 0x340, `FLUMAP1` at 0xEFC) or at a base the descriptor itself states —
/// `FLCOMP`/`FLIL` at `FCBA << 4`, `FLMSTR` at `FMBA << 4`.
public struct DescriptorRegisterMap: Sendable {
    /// Where a register lives in the descriptor.
    public enum Place: Sendable, Equatable {
        /// At this offset in the descriptor.
        case absolute(Int)
        /// At the flash component base (`FLMAP0[0:8] << 4`), plus an offset.
        case flashComponent(offset: Int)
        /// At the flash master base (`FLMAP1[0:8] << 4`), plus an offset.
        case flashMaster(offset: Int)
    }

    public struct Field: Sendable, Equatable {
        /// The tool's identifier, without its `Base_Descriptor_SOC_Strap_`
        /// prefix (`FLMAP0_Flash_Component_Base_Address`).
        public var name: String
        /// The first bit of the register.
        public var bitOffset: Int
        public var count: Int
        /// The tool's panel name for it, where it gives one.
        public var label: String?
        /// The words a value may stand for, where the tool states them.
        public var options: [Int: String]?

        public init(name: String, bitOffset: Int, count: Int,
                    label: String? = nil, options: [Int: String]? = nil) {
            self.name = name
            self.bitOffset = bitOffset
            self.count = count
            self.label = label
            self.options = options
        }

        /// The bits of `word` this field takes, as the number they stand for.
        public func value(in word: UInt32) -> UInt32 {
            let mask: UInt32 = count >= 32 ? .max : (1 << UInt32(count)) - 1
            return word >> UInt32(bitOffset) & mask
        }
    }

    public struct Register: Sendable, Equatable {
        public var name: String
        public var place: Place
        /// The register's length in dwords.
        public var words: Int
        public var fields: [Field]

        public init(name: String, place: Place, words: Int, fields: [Field]) {
            self.name = name
            self.place = place
            self.words = words
            self.fields = fields
        }
    }

    public var registers: [Register]

    public init(registers: [Register]) {
        self.registers = registers
    }

    /// The map for a generation, or nil where none has been emitted.
    ///
    /// The older maps are partial: a FIT build states only the registers its
    /// platform documents carry, and some of those sit in a common document
    /// the build does not embed (the CNP build's `FLMAP0`, Tiger Point's
    /// masters 1, 2 and 4). What a map does not hold is not named, rather
    /// than named from another generation's layout.
    public static func forGeneration(_ generation: DescriptorGeneration) -> DescriptorRegisterMap? {
        switch generation {
        case .sunrisePoint: return .sunrisePoint
        case .cannonPoint: return .cannonPoint
        case .tigerPoint: return .tigerPoint
        case .elkhartLake: return .elkhartLake
        case .jasperLake: return .jasperLake
        case .meteorLake, .pantherLake, .wildcatLake, .novaLake: return .csme18
        default: return nil
        }
    }

    public static var all: [DescriptorRegisterMap] {
        [.sunrisePoint, .cannonPoint, .elkhartLake, .jasperLake, .tigerPoint,
         .csme18]
    }
}

/// One register as an image holds it: where it is and its words.
public struct DescriptorRegisterReading: Sendable, Equatable {
    public var register: DescriptorRegisterMap.Register
    /// The register's first byte, in the file's own offsets.
    public var base: UInt64
    public var words: [UInt32]

    public init(register: DescriptorRegisterMap.Register, base: UInt64,
                words: [UInt32]) {
        self.register = register
        self.base = base
        self.words = words
    }

    /// Every field of the register with what the image holds there.
    public var readings: [DescriptorStrapMap.Reading] {
        register.fields.compactMap { field in
            let word = field.bitOffset / 32
            let inWord = field.bitOffset % 32
            guard word < words.count, field.count > 0, field.count <= 32,
                  inWord + field.count <= 32 else { return nil }
            let mask: UInt32 = field.count >= 32 ? .max : (1 << UInt32(field.count)) - 1
            let value = words[word] >> UInt32(inWord) & mask
            return DescriptorStrapMap.Reading(
                field: DescriptorStrapMap.Field(
                    name: field.name, word: word,
                    bits: inWord...(inWord + field.count - 1),
                    defaultValue: nil, label: field.label, options: field.options),
                value: value)
        }
    }
}
