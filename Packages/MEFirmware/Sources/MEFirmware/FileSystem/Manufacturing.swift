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
/// MFIT — as the two records that carry it can be read from an image.
///
/// **Two records, two pages.** The setting itself is the MFS file
/// `/home/mca/eom_config` (2 bytes: bit 0 `EomFirstBootEnabled`, bits 1–2
/// `FlexibleEomSettings`), and the state is `/home/mca/eom` (1 byte: 1 means
/// Manufacturing has been closed on this board). Both appear twice in an
/// image, and the two pages mean different things:
///
///   * the **OEM Configuration** partition (`FITC`, an FPT region) holds the
///     records the build wrote — what the platform will apply when it enters
///     End of Manufacturing. This is the page MFIT writes and the one the
///     firmware reads, so it is the page the verdict is taken from;
///   * the **MFS volume's own files** hold what the file system has now. On a
///     built image that has never run they are still empty; on a dump taken
///     from a board in service `/home/mca/eom` reads 1, which is the only
///     evidence a dump can carry that Manufacturing is already closed.
///
/// So the decision is: the live `eom` record first (it says what happened),
/// then the image's own flag (it says what will happen).
///
/// The engine reads no fuses — those are burned into the chip and no dump
/// carries them — and it never guesses: a firmware whose generation has no such
/// switch is answered `noSwitch`, and an image whose records cannot be read is
/// answered `unknown` rather than by an assumption about what a vendor does.
enum ManufacturingDecoder {

    /// The `FTBL` keys that name the three files this switch is about
    /// (`FileTable.dat`'s own IDs, the ones the panel's tree prints beside
    /// `/home/mca/eom`). They are stable across CSME 15/16 images; a record
    /// with another ID is some other setting and is ignored.
    enum FileID {
        /// `/home/mca/eom` — 1 byte, 1 = Manufacturing closed.
        static let eom = 0x1002_0000
        /// `/home/mca/eom_config` — 2 bytes, the setting.
        static let eomConfig = 0x1001_EE00
        /// `/home/mca/manuf_lock` — 1 byte, the manufacturing lock. Read
        /// beside them for the basis; it takes no part in the verdict.
        static let manufLock = 0x1002_0100
    }

    /// What both pages said, as the analyzer read them out of the image.
    struct Inputs {
        /// The live `/home/mca/eom` byte: 1 = closed. nil when the volume
        /// carries no such file, or its File IDs are not in hand.
        var eom: Int? = nil
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
        // fallback — an extracted ME region can carry the live records with no
        // OEM Configuration partition beside them.
        let flagWord = inputs.imageEOMConfig ?? inputs.liveEOMConfig
        let page: ManufacturingBasis.Page? = flagWord == nil
            ? nil
            : (inputs.imageEOMConfig != nil ? .imageConfiguration : .liveMFS)
        let basis = ManufacturingBasis(
            eom: inputs.eom,
            flag: flagWord.map { $0 & 1 != 0 },
            flexible: flagWord.map { ($0 >> 1) & 0x3 },
            page: page,
            descriptorOpen: inputs.descriptorOpen,
            liveFilesResolved: inputs.liveFilesResolved)

        // 1. The platform has closed Manufacturing already: the live record
        //    says so, and nothing the image now carries can undo it.
        if let eom = inputs.eom, eom != 0 {
            return (.closed, basis)
        }
        // 2. No switch in this firmware.
        guard inputs.hasSwitch else { return (.noSwitch, basis) }
        // 3. The switch is there but its bytes are not: say so rather than
        //    assume the vendor left it off.
        guard let flag = basis.flag else { return (.unknown, basis) }
        // 4. The flag set with the descriptor open is a combination MFIT
        //    refuses to build (CsePlugin:EomNvar) — worth its own verdict.
        if flag, inputs.descriptorOpen == true { return (.unexpectedCombination, basis) }
        return (flag ? .willClose : .willNotClose, basis)
    }
}
