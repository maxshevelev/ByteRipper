import Foundation
import Localization
import ToolModuleKit
import UEFIImage

/// What a row of the FIT table wears besides its text (`Design/ROW_MARKS.md`
/// §5.2), decided here so it is tested without a window — in the icons and
/// colours of the one catalogue every firmware panel draws from
/// (`ToolRowMark`), so a red octagon here means what it means in the UEFI tree.
///
/// Two slots in the Type column: the verdict — how the microcode stands against
/// the catalogue — and, after it, the problem: what the validator found wrong
/// with the row, and a microcode image whose own checksum does not add up. A
/// row can wear both: a microcode that is not the newest *and* is broken.
public enum FITRowMarks {
    /// Every mark this table draws — what its legend lists.
    public static let legendMarks: [ToolRowMark] = [
        .protectedIBB, .protectedFirmware,
        .newest, .newerListed, .newerMaybe, .error, .caution, .holdsChecks, .partlyProtected
    ]

    /// The words on the badge of a row whose component holds what the IBB is
    /// checked against — the Boot Guard Key Manifest and Boot Policy — nil for
    /// every other row.
    public static func holdsChecks(type: UInt8) -> String? {
        switch type {
        case FIT.keyManifestType:
            return L("Holds the Boot Guard Key Manifest: the key the Boot Policy is signed with")
        case FIT.bootPolicyType:
            return L("Holds the Boot Guard Boot Policy: the IBB segments and the hash they are checked against")
        default:
            return nil
        }
    }

    /// The row's marks, from its own problems in `problems` and what it points
    /// at.
    public static func marks(for row: FITDisplayRow, problems: [FITProblem]) -> ToolRowMarks {
        var errors: [String] = []
        var cautions: [String] = []
        for problem in problems where problem.entryIndex == row.index && problem.inBackup == row.isBackup {
            switch problem.severity {
            case .error: errors.append(problem.message)
            case .warning: cautions.append(problem.message)
            }
        }
        if case .microcode(let header) = row.model.target, !header.checksumIsCorrect {
            if let computed = header.computedChecksum {
                errors.append(L("Invalid microcode image checksum: %1$@, should be %2$@",
                                hex(header.checksum), hex(computed)))
            } else {
                cautions.append(L("The microcode image cannot be read whole, so its checksum is not checked"))
            }
        }
        var roles = holdsChecks(type: row.model.entry.type).map { [ToolRowMarks.Role.holdsChecks($0)] } ?? []
        // The background by the same rule as the UEFI tree's: wholly inside the
        // IBB, wholly inside what the firmware checks, or — for bytes only
        // partly covered — no tint and the badge (ROW_MARKS.md §2).
        var protection: ToolRowMarks.Protection?
        switch row.protection {
        case .ibb: protection = .ibb
        case .protected: protection = .firmware
        case .partial: roles.append(.partlyProtected)
        case nil: break
        }
        return ToolRowMarks(protection: protection,
                            problem: .worst(errors: errors, cautions: cautions), roles: roles)
    }

    /// The verdict a row's "latest" state is drawn as, and what the pointer
    /// reads on it — nil where there is no basis for one.
    public static func verdict(of state: MicrocodeLatest) -> (mark: ToolRowMark, toolTip: String)? {
        switch state {
        case .latest:
            return (.newest, L("Newest revision the catalogue lists for this processor and platform"))
        case .outdated(let newest):
            return (.newerListed, L("Catalogue lists a newer revision (r.%1$@)", revision(newest)))
        case .undecided(let newest):
            return (.newerMaybe,
                    L("Catalogue lists a newer revision (r.%1$@) whose platforms only partly overlap this one's — whether it serves this board depends on the board's own platform ID, which the image does not carry",
                      revision(newest)))
        case .notRated:
            return nil
        }
    }

    private static func revision(_ value: UInt32) -> String {
        String(value, radix: 16, uppercase: true)
    }

    private static func hex(_ value: UInt32) -> String {
        let digits = String(value, radix: 16, uppercase: true)
        return "0x" + String(repeating: "0", count: max(0, 8 - digits.count)) + digits
    }
}
