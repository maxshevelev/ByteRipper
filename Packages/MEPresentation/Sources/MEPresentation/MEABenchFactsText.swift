import Foundation
import Localization
import MEFirmware

// help: panel.me.manufacturing
/// The three facts a repair bench asks of a dump it is about to flash, in the
/// reader's language: whether the image closes Manufacturing on its first boot,
/// which Boot Guard profile it is built for, and which OEM public key hash it
/// carries. Ours — MEAnalyzer prints none of them — so the words are ours too,
/// and each of them says what the *dump* shows rather than what a vendor
/// usually does.
extension MEAText {
    /// The Manufacturing verdict as one phrase.
    public static func manufacturingState(_ state: ManufacturingState, in language: AppLanguage) -> String {
        switch state {
        case .willClose:
            return L("Will close on first boot", in: language)
        case .willNotClose:
            return L("Will not close", in: language)
        case .closed:
            return L("Already closed", in: language)
        case .unexpectedCombination:
            return L("Close on first boot, with the descriptor open", in: language)
        case .unknown:
            return L("Not readable from this image", in: language)
        case .noSwitch:
            return L("No such switch in this firmware", in: language)
        }
    }

    /// What the Manufacturing verdict was read from, in one paragraph — the
    /// same idea as the File System State's basis, and shown the same way under
    /// its row.
    public static func manufacturingBasis(_ basis: ManufacturingBasis, in language: AppLanguage) -> String {
        var sentences: [String] = []
        if let eom = basis.eom {
            if eom == 0 {
                sentences.append(L("The file %1$@ in the file system reads 0: Manufacturing has not been closed on this board.", in: language, "/home/mca/eom"))
            } else {
                sentences.append(L("The file %1$@ in the file system reads %2$d: Manufacturing has been closed on this board already, whatever this image is set to do.", in: language, "/home/mca/eom", eom))
            }
        } else if basis.liveFilesResolved {
            sentences.append(L("The file system carries no %1$@ record, so the board has not closed Manufacturing itself.", in: language, "/home/mca/eom"))
        }
        switch (basis.flag, basis.page) {
        case (let flag?, let page?):
            let setting = (flag ? L("set", in: language) : L("clear", in: language))
            let source = page == .liveMFS
                ? L("the file system's own %1$@", in: language, "/home/mca/eom_config")
                : L("the image's OEM Configuration (the record the platform applies when it enters End of Manufacturing)", in: language)
            sentences.append(L("The End of Manufacturing setting is %1$@ in %2$@.", in: language, setting, source))
            if let flexible = basis.flexible {
                sentences.append(flexibleText(flexible, in: language))
            }
        default:
            sentences.append(L("Neither the image's OEM Configuration nor the file system carries the setting, so what this image will do cannot be read from it.", in: language))
        }
        if basis.descriptorOpen == true {
            sentences.append(L("The descriptor's BIOS master is open — it may read and write the whole flash — which is the state a service dump is handed out in.", in: language))
        } else if basis.descriptorOpen == false {
            sentences.append(L("The descriptor's BIOS master is locked.", in: language))
        }
        if !basis.liveFilesResolved {
            sentences.append(L("The file system's files could not be resolved to File IDs without the firmware database, so only the image's own records were read.", in: language))
        }
        return sentences.joined(separator: " ")
    }

    /// The Boot Guard profile as MFIT and MEInfo print it: the number first,
    /// because that is what a technician quotes and what a fuse is burned to.
    public static func bootGuardProfile(_ profile: BootGuardProfile) -> String {
        "\(profile.rawValue) - \(profileName(profile))"
    }

    /// The profile's own name. Intel's abbreviations, kept in every language —
    /// they are what the field documents and the fuses are described by.
    public static func profileName(_ profile: BootGuardProfile) -> String {
        switch profile {
        case .noFVME: return "No_FVME"
        case .vm: return "VM"
        case .fve: return "FVE"
        case .fvme: return "FVME"
        }
    }

    /// The OEM public key hash: the value, printed as 96 hex digits exactly as
    /// MFIT's own build report and ECFinder print it — a technician comparing
    /// two of them compares them as text.
    ///
    /// There is no wording for "the hash is all zeros, so OEM signing is off":
    /// a 48-byte run of zeros is what an unwritten area looks like too, so the
    /// reader claims a hash only where the area repeats a value that carries
    /// key material at all, and the row's absence is the honest answer for both
    /// (`BootGuardReader.oemPublicKeyHash`). The help says so.
    public static func oemPublicKeyHash(_ hash: String) -> String {
        hash
    }

    private static func flexibleText(_ flexible: Int, in language: AppLanguage) -> String {
        switch flexible {
        case 0: return L("End of Manufacturing will lock the descriptor and the OEM configuration.", in: language)
        case 1: return L("End of Manufacturing will lock the OEM configuration only.", in: language)
        case 2: return L("End of Manufacturing will lock the descriptor only.", in: language)
        default: return L("End of Manufacturing will lock neither the descriptor nor the OEM configuration.", in: language)
        }
    }
}
