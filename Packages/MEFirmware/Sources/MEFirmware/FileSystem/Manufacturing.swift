// The End of Manufacturing switch: which records the platform reads to decide
// whether its first boot closes Manufacturing, and what their bytes mean.
//
// A package of its own would be a package with one enum in it: this belongs to
// MEFirmware, beside the MFS decoders whose records it interprets, and the
// addresses and values behind it are written down in
// Skills/me-eom-structures/reference/structures.md (verified on real dumps and
// against MFIT's own build report).

import Foundation

/// Whether an image closes Manufacturing on the first boot of a board, and what
/// says so.
///
/// **Two mechanisms, and the descriptor's is the one that is usually at work.**
///
///   * The **access rights in the flash descriptor** are what a manufacturer
///     normally relies on. A serial image leaves the host CPU / BIOS master
///     with the factory rights (`0x00F` / `0x00A` in these dumps, not the
///     `0xFFF` / `0xFFF` of a service image that lets the host rewrite the
///     whole flash), and the platform closes Manufacturing on its first boot.
///     That is how End of Manufacturing was done before the flag existed, and
///     it is still how the serial images that carry no flag are done.
///   * The **`CsePlugin:EomNvar` flag** — bit 0 of the MFS file
///     `/home/mca/eom_config` — is an explicit order on top of that, which only
///     MFIT sets. It appears in an image twice: in the **OEM Configuration**
///     partition (`FITC`, an FPT region), which holds the record the build
///     wrote, and in the **MFS volume's own files**, which is the only copy in
///     a region handed over without its OEM Configuration partition. The page
///     the verdict is taken from is the image's own; the file system's is the
///     fallback. Bits 1–2 of the record are `FlexibleEomSettings` — what EOM
///     commits.
///
/// So a flag reading **0 does not mean Manufacturing stays open**: what a serial
/// image with the flag clear does is exactly what its descriptor rights say.
/// `false` is therefore read as "the flag is not the reason", and the
/// descriptor answers — the one case where nothing closes Manufacturing is an
/// image with the flag clear *and* the descriptor open, which is the service
/// image a bench prepares for itself. The flag set with the descriptor open is
/// the combination MFIT refuses to build.
///
/// What the *board* has already done is deliberately not read. The live file
/// system also holds `/home/mca/eom`, which is 1 once Manufacturing has been
/// closed on the board the dump came from — but the question is about the
/// machine the image is about to be written to, whose chipset is fresh, and a
/// record of some other board's history does not bear on it.
///
/// The engine reads no fuses — those are burned into the chip and no dump
/// carries them — and it never guesses: a firmware of a generation that does
/// not decide this (before CSME 11, whose era is the one whose descriptor
/// rights this reads) is answered `noSwitch`, and an image whose bytes cannot
/// be read — the flag clear with no descriptor in hand — is answered `unknown`.
enum ManufacturingDecoder {

    /// The `FTBL` keys that name the record this switch is about
    /// (`FileTable.dat`'s own IDs, the ones the panel's tree prints beside
    /// `/home/mca/eom`). They are stable across CSME 15/16 images; a record
    /// with another ID is some other setting and is ignored.
    enum FileID {
        /// `/home/mca/eom_config` — 2 bytes, the setting.
        static let eomConfig = 0x1001_EE00
        /// `/home/mca/eom` — 1 byte, the board's own record that Manufacturing
        /// has been closed. Read only to tell that the file system was read at
        /// all; it takes no part in the verdict.
        static let eom = 0x1002_0000
        /// `/home/mca/manuf_lock` — 1 byte, the manufacturing lock. Not read.
        static let manufLock = 0x1002_0100
    }

    /// What the pages said, as the analyzer read them out of the image.
    struct Inputs {
        /// The **image configuration** record for `/home/mca/eom_config` —
        /// what the build wrote and the platform applies at EOM.
        var imageEOMConfig: Int? = nil
        /// The live `/home/mca/eom_config` record of the MFS volume.
        var liveEOMConfig: Int? = nil
        /// Whether the descriptor's BIOS master is open (`0xFFFF` in both
        /// masks). nil when no descriptor was handed to the analyzer.
        var descriptorOpen: Bool? = nil
        /// Whether this generation decides End of Manufacturing at all: CSME
        /// 11 and later, whose descriptors carry the v2 access rights the
        /// verdict is read from (`FlashDescriptor.biosMaster`). False for a
        /// family or a generation that does not — those answer `noSwitch`.
        var hasSwitch: Bool = false
        /// Whether the live file system could be looked in: false when the
        /// image has an MFS volume but `FileTable.dat` is not in hand, so its
        /// files carry no File IDs. A missing database, not a finding.
        var liveFilesResolved: Bool = false
    }

    /// The verdict and what it was decided from.
    static func decide(_ inputs: Inputs) -> (state: ManufacturingState, basis: ManufacturingBasis) {
        // The flag: the image's own record first (that is the page the
        // platform applies at End of Manufacturing), the live one as the
        // fallback for a region handed over without its OEM Configuration.
        let flagWord = inputs.imageEOMConfig ?? inputs.liveEOMConfig
        let page: ManufacturingBasis.Page? = flagWord == nil
            ? nil
            : (inputs.imageEOMConfig != nil ? .imageConfiguration : .liveMFS)
        let basis = ManufacturingBasis(
            flag: flagWord.map { $0 & 1 != 0 },
            flexible: flagWord.map { ($0 >> 1) & 0x3 },
            page: page,
            descriptorOpen: inputs.descriptorOpen,
            liveFilesResolved: inputs.liveFilesResolved)

        // No End of Manufacturing machinery in this firmware.
        guard inputs.hasSwitch else { return (.noSwitch, basis) }
        // The flag set is an explicit order, MFIT's own: it closes
        // Manufacturing whatever the descriptor says, which is why the pair
        // with an open descriptor is a combination MFIT refuses to build.
        if basis.flag == true {
            return inputs.descriptorOpen == true ? (.unexpectedCombination, basis) : (.willClose, basis)
        }
        // The flag is clear, or the image carries no such record at all — a
        // serial image that relies on its descriptor rights, which is how
        // manufacturers make them. So it is the descriptor that answers here:
        // open rights are the one state in which nothing closes Manufacturing,
        // and an unreadable descriptor leaves the question open.
        switch inputs.descriptorOpen {
        case false: return (.willClose, basis)
        case true: return (.willNotClose, basis)
        case nil: return (.unknown, basis)
        }
    }
}
