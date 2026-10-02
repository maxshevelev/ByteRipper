import Foundation

/// The maker of an SPI flash chip, from the first byte of its JEDEC id.
///
/// That byte is the manufacturer code of JEDEC JEP106, so it names the vendor
/// even for a part `JedecIDs` does not list. The two device bytes after it are
/// the vendor's own and say nothing across vendors. Only codes seen on SPI
/// flash are here, taken from the vendors the generated `JedecIDs` table groups
/// and from flashrom's `flashchips.h`; a code with a continuation prefix
/// (`7F`…) is not read. A vendor that sells under a code it does not own — XMC
/// uses Micron's `20` — is named by the code's owner, never guessed.
enum FlashVendors {
    static func name(ofJedecID id: UInt32) -> String? {
        table[UInt8(truncatingIfNeeded: id >> 16)]
    }

    private static let table: [UInt8: String] = [
        0x01: "AMD / Spansion",
        0x04: "Fujitsu",
        0x0B: "XTX",
        0x0E: "Zbit",
        0x1C: "EON",
        0x1F: "Atmel / Adesto",
        0x20: "Micron / ST",
        0x37: "AMIC",
        0x62: "Sanyo",
        0x89: "Intel",
        0x8C: "ESMT",
        0x9D: "ISSI / PMC",
        0xBA: "Zetta",
        0xBF: "SST / Microchip",
        0xC2: "Macronix",
        0xC8: "GigaDevice",
        0xEF: "Winbond",
        0xF8: "Fidelix",
    ]
}
