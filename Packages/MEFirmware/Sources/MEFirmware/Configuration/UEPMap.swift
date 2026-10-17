import Foundation

/// The FPF/UEP settings a generation's tool writes into the `$UEP` area — the
/// bits the platform would burn at End of Manufacturing, as the tool's own
/// documents lay them out.
///
/// The area itself is described nowhere public; the tools' documents are the
/// only statement of it. Each setting has a declaration (`RpmcSupported`,
/// "RPMC Supported", section `RpmcConfiguration`) and a `GetBitArrayValue`
/// action giving its place — one of several arrays the container keeps
/// (`UepBitsArray0`, `…2`, `…4`). **Only the first array is read**: it is the
/// one `BootGuardReader` takes the Boot Guard profile from, on both
/// generations whose container is one, and a setting the tool places only in
/// another array is not in a map.
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
        /// Which of the container's arrays; always the first in a map.
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

        public init(name: String, placement: Placement, label: String? = nil,
                    section: String? = nil, help: String? = nil) {
            self.name = name
            self.placement = placement
            self.label = label
            self.section = section
            self.help = help
        }
    }

    /// What the map is — the generation and the tool it came from.
    public var name: String
    public var settings: [Setting]

    public init(name: String, settings: [Setting]) {
        self.name = name
        self.settings = settings
    }

    /// The map for a generation's major number, or nil where the area is not
    /// one the engine reads — CSME 12 to 14 keep the profile in a record, not
    /// in these arrays, and no later generation has a map yet.
    public static func forME(major: Int) -> UEPMap? {
        switch major {
        case 15: return .csme15
        case 16: return .csme16
        default: return nil
        }
    }

    public static var all: [UEPMap] { [.csme15, .csme16] }
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

/// Reading the area's first bit array: the container's `$UEP` signature, its
/// first array 0x0C bytes past it (measured — the Boot Guard word's
/// `offset 0x60, startBit 16` lands at byte 0x6E, which is where
/// `BootGuardReader` reads the profile from), and each setting's bits from
/// its offset, little-endian. A field may run past the word it starts in, so
/// up to eight bytes are read and the mask shifted out of them.
public enum UEPReader {
    /// How far past the container's signature the first array begins.
    public static let firstArrayOffset = 0x0C

    /// The values of every setting of `map` the area holds. Nil where the area
    /// has no container, or is too short for a setting it is asked about — an
    /// area erased past reading answers nothing rather than zeros.
    public static func readings(in area: Data, map: UEPMap) -> [UEPReading]? {
        guard let container = BootGuardReader.containerOffset(in: area) else { return nil }
        let array = container + firstArrayOffset
        var readings: [UEPReading] = []
        for setting in map.settings {
            let place = setting.placement
            guard place.count > 0, place.count <= 64, place.bit >= 0,
                  place.bit + place.count <= 64 else { continue }
            let at = array + place.offset
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
