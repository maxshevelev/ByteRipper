// The End of Manufacturing switch: which records the platform reads to decide
// whether its first boot closes Manufacturing, and what their bytes mean.
//
// A package of its own would be a package with one enum in it: this belongs to
// MEFirmware, beside the MFS decoders whose records it interprets, and the
// addresses and values behind it are written down in
// Skills/me-eom-structures/reference/structures.md (verified on real dumps and
// against MFIT's own build report).

import Foundation

/// The End of Manufacturing switch of CSME 15/16 — `CsePlugin:EomNvar` in
/// MFIT — as the record that carries it can be read from an image.
///
/// **One setting, two places it may be written.** The setting is the MFS file
/// `/home/mca/eom_config` (2 bytes: bit 0 `EomFirstBootEnabled`, bits 1–2
/// `FlexibleEomSettings`), and it appears in an image twice:
///
///   * the **OEM Configuration** partition (`FITC`, an FPT region) holds the
///     record the build wrote — what the platform will apply when it enters
///     End of Manufacturing. This is the page MFIT writes and the one the
///     firmware reads, so it is the page the verdict is taken from;
///   * the **MFS volume's own files** hold the record as the file system
///     carries it. An extracted region may be handed over without its OEM
///     Configuration partition, and then this is the only copy there is.
///
/// What the *board* has already done is deliberately not read. The live file
/// system also holds `/home/mca/eom`, which is 1 once Manufacturing has been
/// closed on the board the dump came from — but the question the row answers is
/// about the machine the image is about to be written to, whose chipset is
/// fresh, and a record of some other board's history does not bear on it.
///
/// The engine reads no fuses — those are burned into the chip and no dump
/// carries them — and it never guesses: a firmware whose generation has no such
/// switch is answered `noSwitch`, and an image whose records cannot be read is
/// answered `unknown` rather than by an assumption about what a vendor does.
enum ManufacturingDecoder {

    /// The `FTBL` keys that name the two files this switch is about
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
        /// Whether the image carries a switch of this kind at all: an OEM
        /// Configuration partition holding such a record, or an MFS volume
        /// whose files could be resolved to File IDs. False for a firmware
        /// that predates the setting.
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

        // No switch in this firmware.
        guard inputs.hasSwitch else { return (.noSwitch, basis) }
        // The switch is there but its bytes are not: say so rather than
        // assume the vendor left it off.
        guard let flag = basis.flag else { return (.unknown, basis) }
        // The flag set with the descriptor open is a combination MFIT
        // refuses to build (CsePlugin:EomNvar) — worth its own verdict.
        if flag, inputs.descriptorOpen == true { return (.unexpectedCombination, basis) }
        return (flag ? .willClose : .willNotClose, basis)
    }
}
