import Foundation

/// The chipset generation a flash descriptor was written for, told from the
/// descriptor's own layout (`UEFI_IMAGE_FORMAT.md` §2.5).
///
/// Nothing in a descriptor states it. The version field is reserved before
/// Cannon Point and says nothing after it — a Skylake board leaves it
/// `0xFFFFFFFF` and a Cougar Point one writes `0x25` there — yet the
/// generation decides how the rest reads: how many regions the table holds,
/// whether a master's masks are a byte or twelve bits, how wide a chip's
/// density is and what a clock code means. What does tell generations apart
/// is where each one puts its sections and how long it makes them, and the
/// rules here are those flashrom's `ich_descriptors.c` uses for a dump, which
/// agree with the ME region's own chipset on every dump at hand.
///
/// Several generations share one layout and cannot be told apart by it — 6
/// and 7 series, 8 and 9, 300 and 400, 600 and 700 — so a case names both.
public enum DescriptorGeneration: Sendable, Equatable, CaseIterable {
    case ich8, ich9, ich10, ibexPeak, cougarPoint, bayTrail, lynxPoint
    case sunrisePoint, lewisburg, emmitsburg, apolloLake, geminiLake
    case cannonPoint, tigerPoint, alderPoint, elkhartLake, jasperLake
    case meteorLake, pantherLake, wildcatLake, novaLake

    /// What a bench calls it: Intel's code names, which are the same in every
    /// language.
    public var codeName: String {
        switch self {
        case .ich8: return "ICH8"
        case .ich9: return "ICH9"
        case .ich10: return "ICH10"
        case .ibexPeak: return "Ibex Peak"
        case .cougarPoint: return "Cougar Point / Panther Point"
        case .bayTrail: return "Bay Trail"
        case .lynxPoint: return "Lynx Point / Wildcat Point"
        case .sunrisePoint: return "Sunrise Point / Union Point"
        case .lewisburg: return "Lewisburg"
        case .emmitsburg: return "Emmitsburg"
        case .apolloLake: return "Apollo Lake"
        case .geminiLake: return "Gemini Lake"
        case .cannonPoint: return "Cannon Point / Comet Point"
        case .tigerPoint: return "Tiger Point"
        case .alderPoint: return "Alder Point / Raptor Point"
        case .elkhartLake: return "Elkhart Lake"
        case .jasperLake: return "Jasper Lake"
        case .meteorLake: return "Meteor Lake"
        case .pantherLake: return "Panther Lake"
        case .wildcatLake: return "Wildcat Lake"
        case .novaLake: return "Nova Lake"
        }
    }

    /// The chipset series the code name is sold as, where it is one.
    public var series: String? {
        switch self {
        case .ibexPeak: return "5"
        case .cougarPoint: return "6/7"
        case .lynxPoint: return "8/9"
        case .sunrisePoint: return "100/200"
        case .lewisburg: return "C620"
        case .emmitsburg: return "C740"
        case .cannonPoint: return "300/400"
        case .tigerPoint: return "500"
        case .alderPoint: return "600/700"
        default: return nil
        }
    }

    /// How many base/limit pairs the region section holds.
    var regionCount: Int {
        switch self {
        case .ich8, .ich9, .ich10, .ibexPeak, .cougarPoint, .bayTrail: return 5
        case .lynxPoint: return 7
        case .apolloLake, .geminiLake: return 6
        case .sunrisePoint: return 10
        default: return 16
        }
    }

    /// Twelve bits of read and twelve of write in one dword per master,
    /// rather than a byte of each.
    var hasWideMasks: Bool {
        switch self {
        case .ich8, .ich9, .ich10, .ibexPeak, .cougarPoint, .bayTrail, .lynxPoint: return false
        default: return true
        }
    }

    /// A chip's density is three bits up to Panther Point and four from
    /// Lynx Point on, which is what lets a chip be 32 or 64 MB.
    var densityBits: Int {
        switch self {
        case .ich8, .ich9, .ich10, .ibexPeak, .cougarPoint, .bayTrail: return 3
        default: return 4
        }
    }

    /// From Sunrise Point on the partition boundary register holds four more
    /// forbidden opcodes instead.
    var hasEightInvalidInstructions: Bool {
        switch self {
        case .ich8, .ich9, .ich10, .ibexPeak, .cougarPoint, .bayTrail, .lynxPoint: return false
        default: return true
        }
    }

    /// The PCH strap bit that soft-disables the ME, as ifdtool and me_cleaner
    /// set it: `ICH_MeDisable` in the first word up to ICH10, `AltMeDisable`
    /// in the eleventh from Ibex Peak to Wildcat Point, and HAP in the first
    /// from Sunrise Point on. Nil where neither tool names one — Bay Trail's
    /// TXE, and Emmitsburg, which ifdtool does not know.
    var meDisableBit: (name: String, word: Int, bit: Int)? {
        switch self {
        case .ich8, .ich9, .ich10: return ("ICH_MeDisable", 0, 0)
        case .ibexPeak, .cougarPoint, .lynxPoint: return ("AltMeDisable", 10, 7)
        case .bayTrail, .emmitsburg: return nil
        default: return ("HAP", 0, 16)
        }
    }

    /// Which strap words hold the eSPI clock and the GPR0 range, for a strap
    /// section of `count` words. A layout is the generation's *and* the
    /// length's: the mobile and desktop parts of one generation make the
    /// section different lengths and put the same field in different words.
    /// So only the layouts ifdtool's offsets were checked against are here —
    /// Tiger and Alder Point mobile, 70 words — and on Tiger Point H (101) or
    /// Alder Point S (115) the same words are other fields (§2.6).
    func strapFields(count: Int) -> (espiClockWord: Int, gpr0Word: Int)? {
        switch (self, count) {
        case (.tigerPoint, 70), (.alderPoint, 70): return (22, 21)
        default: return nil
        }
    }

    /// The eSPI clock a three-bit strap code stands for, in MHz, on the
    /// generations `strapFields` knows: ifdtool's 500-series table.
    func espiClock(_ code: UInt8) -> [Int]? {
        [0: [20], 1: [24], 2: [25], 3: [48], 4: [60]][code]
    }

    /// The SPI clock a three-bit code stands for, in MHz. A code the
    /// generation reserves has none; Apollo and Gemini Lake give one code two
    /// clocks.
    func clock(_ code: UInt8) -> [Int]? {
        let table: [UInt8: [Int]]
        switch self {
        case .ich8, .ich9, .ich10:
            table = [0: [20], 1: [33]]
        case .ibexPeak, .cougarPoint, .bayTrail, .lynxPoint:
            table = [0: [20], 1: [33], 4: [50]]
        case .sunrisePoint, .lewisburg, .cannonPoint, .jasperLake:
            table = [2: [48], 4: [30], 6: [17]]
        case .apolloLake, .geminiLake:
            table = [1: [50], 2: [40], 4: [25], 6: [14, 17]]
        case .elkhartLake:
            table = [1: [50], 4: [33], 5: [20]]
        case .tigerPoint, .alderPoint, .emmitsburg, .meteorLake, .pantherLake, .wildcatLake, .novaLake:
            table = [0: [100], 1: [50], 3: [33], 4: [25], 6: [14]]
        }
        return table[code]
    }
}

extension DescriptorGeneration {
    /// The generation the descriptor at `base` was written for, and whether
    /// its layout is one the rules know or the nearest they assume. Nil when
    /// the map cannot be read.
    static func read(at base: UInt64, in reader: ImageReader) -> (generation: DescriptorGeneration, isCertain: Bool)? {
        guard let map1 = reader.uint32(at: base + Descriptor.map1Offset),
              let map2 = reader.uint32(at: base + Descriptor.map2Offset)
        else { return nil }
        // A descriptor cut short before its upper map reads as erased there.
        let upper = reader.uint32(at: base + DescriptorInfo.UpperMap.offset) ?? 0xFFFF_FFFF
        let pchStrapLength = map1 >> 24
        let masterCount = map1 >> 8 & 0x7
        let procStrapBase = map2 & 0xFF
        let procStrapLength = map2 >> 8 & 0xFF
        // ICC register init base, new with Sandy Bridge.
        let iccBase = map2 >> 16 & 0xFF
        // The MIP descriptor table base, new with Cannon Point.
        let mipBase = upper >> 24
        // From Tiger Point on the third map word says where the CPU straps
        // sit in the PMC's space instead.
        let cpuStrapOffset = map2 >> 2 & 0x3FF
        let cpuStrapLength = map2 >> 16 & 0xFF

        if iccBase == 0 {
            if procStrapLength == 0 && pchStrapLength <= 2 { return (.ich8, true) }
            if pchStrapLength <= 2 { return (.ich9, true) }
            if pchStrapLength <= 10 { return (.ich10, true) }
            if pchStrapLength <= 16 { return (.ibexPeak, true) }
            if map2 == 0 {
                if pchStrapLength == 19 { return (.apolloLake, true) }
                return (.geminiLake, pchStrapLength == 23)
            }
            if pchStrapLength == 0x50 { return (.emmitsburg, true) }
            return (.ibexPeak, false)
        }
        if mipBase == 0 {
            if iccBase < 0x31 && procStrapBase < 0x30 {
                if procStrapLength == 0 && pchStrapLength <= 17 { return (.bayTrail, true) }
                if procStrapLength <= 1 && pchStrapLength <= 18 { return (.cougarPoint, true) }
                return (.lynxPoint, procStrapLength <= 1 && pchStrapLength <= 21)
            }
            if masterCount == 6 { return (.lewisburg, iccBase <= 0x34) }
            return (.sunrisePoint, iccBase == 0x31)
        }
        if iccBase == 0x34 { return (.cannonPoint, true) }
        switch (cpuStrapLength, cpuStrapOffset) {
        // flashrom names Tiger Point by an offset of 0x68; Tiger Point H
        // boards (`1.bin`) write 0x6C, and nothing else at hand has a length
        // of 0x11 — so the length alone names it, unless the offset is
        // Alder Point's.
        case (0x11, 0x5C): return (.alderPoint, true)
        case (0x11, _): return (.tigerPoint, true)
        case (0x14, _): return (.alderPoint, true)
        case (0x03, 0x58): return (.elkhartLake, true)
        case (0x03, 0x6C): return (.jasperLake, true)
        case (0x03, 0x70): return (.meteorLake, true)
        case (0x03, 0x60):
            switch pchStrapLength {
            case 0x78: return (.wildcatLake, true)
            case 0xA9: return (.novaLake, true)
            default: return (.pantherLake, true)
            }
        default:
            return (.tigerPoint, false)
        }
    }
}
