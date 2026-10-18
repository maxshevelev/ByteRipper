import Foundation

/// The FPF/UEP settings a generation's tool writes into the `$UEP` area — the
/// bits the platform would burn at End of Manufacturing, as the tool's own
/// documents lay them out.
///
/// The area itself is described nowhere public; the tools' documents are the
/// only statement of it. Each setting has a declaration (`RpmcSupported`,
/// "RPMC Supported", section `RpmcConfiguration`) and a `GetBitArrayValue`
/// action giving its place — one of several arrays the container keeps
/// (`UepBitsArray0`, `…2`, `…4`). The first array is the one
/// `BootGuardReader` takes the Boot Guard profile from, on the generations
/// whose container is one. A map says whether it names later arrays:
/// Flash Image Tool 15/16 place every setting in the first; CSME 18's
/// rewritten database puts a few in the second (`PLAT_ID`, `DNX`,
/// `RPMC_RB` and the validity bits beside them). Flash Image Tool 12's CNP
/// document fills four arrays of 0x80 bytes and its 13 and 14 builds six
/// (Ice Lake) and four (Comet Lake), a few settings — the SB SVNs, the TPM
/// seed bits — in the later ones only.
///
/// What an image's array holds is the state the build wrote. On the dumps at
/// hand most settings read zero, and the profile's own bits are the ones that
/// do not — which is why the profile is read there and not from fuses the image
/// does not describe (`Design/ME_STRUCTURES.md`).
public struct UEPMap: Sendable {
    /// Where a setting's bits sit: a byte offset into the array, and the bit
    /// the field starts at, counted little-endian from that byte — the shape
    /// the tool's action states. A field may run past the 32-bit word it
    /// starts in: `sb_bsmm_svn` is bit 30, 15 bits long.
    public struct Placement: Sendable, Equatable {
        /// Which of the container's arrays — zero where the map keeps to the
        /// first, which is every setting of 15/16 and most of 18's.
        public var array: Int
        /// Byte offset into the array.
        public var offset: Int
        /// The bit the field starts at, counted from `offset`.
        public var bit: Int
        public var count: Int

        public init(array: Int, offset: Int, bit: Int, count: Int) {
            self.array = array
            self.offset = offset
            self.bit = bit
            self.count = count
        }
    }

    /// One setting of the area, as the tool declares it.
    public struct Setting: Sendable, Equatable {
        /// The tool's identifier for the bit (`RpmcSupported`, `oem_cfg_done`).
        public var name: String
        public var placement: Placement
        /// The tool's own name for it in its interface, where it has one —
        /// "RPMC Supported". The low-level bits Flash Image Tool names by their
        /// identifier alone carry none.
        public var label: String?
        /// The tool's section for it (`PlatformIntegrity`, `RpmcConfiguration`),
        /// which is how its interface groups them; nil where it states none.
        public var section: String?
        /// What the tool's panel says about it, where it says anything.
        public var help: String?
        /// The tool's words for the values of an enumerated setting (0 "No",
        /// 1 "Yes"; the Boot Guard profile's 0/3/4/5), where it enumerates one.
        /// A bit the tool leaves as a bare switch has none.
        public var options: [Int: String]?

        public init(name: String, placement: Placement, label: String? = nil,
                    section: String? = nil, help: String? = nil,
                    options: [Int: String]? = nil) {
            self.name = name
            self.placement = placement
            self.label = label
            self.section = section
            self.help = help
            self.options = options
        }
    }

    /// What the map is — the generation and the tool it came from.
    public var name: String
    public var settings: [Setting]
    /// How far past the container's signature the first bit array begins. The
    /// CSME 15/16 area keeps it at 0x0C — measured off the Boot Guard word that
    /// lands at +0x6E — while the CSME 18 container is the tool's own 8-byte
    /// `$UEP` header (signature, CRC-16, reserved) followed directly by the
    /// arrays, so its first array begins at +8.
    public var arrayStart: Int
    /// The size of one array where the container's arrays are laid
    /// contiguously and a map names later ones (CSME 18: 0x80). Zero where a
    /// map keeps to the first array and the tool's offsets are already places
    /// in it — the 15/16 area.
    public var arraySize: Int

    public init(name: String, settings: [Setting], arrayStart: Int = 0x0C,
                arraySize: Int = 0) {
        self.name = name
        self.settings = settings
        self.arrayStart = arrayStart
        self.arraySize = arraySize
    }

    /// The map for a generation's major number, or nil where the area is not
    /// one the engine reads. CSME 12 to 14 keep the Boot Guard profile in a
    /// record rather than these arrays, but the area still holds the other
    /// FPF settings; each reads through its own FIT build's platform document
    /// (CNP, Ice Lake, Comet Lake). 17 has no map of its own yet.
    public static func forME(major: Int) -> UEPMap? {
        switch major {
        case 12: return .csme12
        case 13: return .csme13
        case 14: return .csme14
        case 15: return .csme15
        case 16: return .csme16
        case 18: return .csme18
        default: return nil
        }
    }

    public static var all: [UEPMap] {
        [.csme12, .csme13, .csme14, .csme15, .csme16, .csme18]
    }
}

/// One setting of the area as an image holds it.
public struct UEPReading: Codable, Sendable, Equatable {
    public var name: String
    public var value: Int

    public init(name: String, value: Int) {
        self.name = name
        self.value = value
    }
}

/// Reading the area's bit arrays: the container's `$UEP` signature, its
/// first array `arrayStart` bytes past it (0x0C for 15/16, measured — the
/// Boot Guard word's `offset 0x60, startBit 16` lands at byte 0x6E, which is
/// where `BootGuardReader` reads the profile from; 8 for 18, the tool's own
/// header), and each setting's bits from its array and offset,
/// little-endian. A field may run past the word it starts in, so up to eight
/// bytes are read and the mask shifted out of them.
public enum UEPReader {
    /// How far past the container's signature the first array begins in the
    /// CSME 15/16 area — the default of `UEPMap.arrayStart`.
    public static let firstArrayOffset = 0x0C

    /// The values of every setting of `map` the area holds. Nil where the area
    /// has no container, or is too short for a setting it is asked about — an
    /// area erased past reading answers nothing rather than zeros.
    public static func readings(in area: Data, map: UEPMap) -> [UEPReading]? {
        guard let container = BootGuardReader.containerOffset(in: area) else { return nil }
        let arrays = container + map.arrayStart
        var readings: [UEPReading] = []
        for setting in map.settings {
            let place = setting.placement
            guard place.count > 0, place.count <= 64, place.bit >= 0,
                  place.bit + place.count <= 64 else { continue }
            let at = arrays
                + (map.arraySize > 0 ? place.array * map.arraySize : 0)
                + place.offset
            // The bytes the field's last bit touches, no more: an offset near
            // the area's end still reads where the field fits.
            let touched = (place.bit + place.count + 7) / 8
            guard at >= 0, touched <= 8, at + touched <= area.endIndex else { continue }
            let start = area.startIndex + at
            var word: UInt64 = 0
            for index in 0..<touched {
                word |= UInt64(area[start + index]) << (8 * index)
            }
            let mask: UInt64 = place.count == 64 ? .max : (1 << UInt64(place.count)) - 1
            readings.append(UEPReading(name: setting.name,
                                       value: Int(word >> UInt64(place.bit) & mask)))
        }
        return readings.isEmpty ? nil : readings
    }
}
