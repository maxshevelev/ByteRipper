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
        case .unexpectedCombination:
            return L("Close on first boot, with the descriptor open", in: language)
        case .unknown:
            return L("Not readable from this image", in: language)
        case .noSwitch:
            return L("No such switch in this firmware", in: language)
        }
    }

    /// What the Manufacturing verdict was read from, in one short paragraph —
    /// the same idea as the File System State's basis, and shown the same way
    /// under its row. Kept to what the verdict rests on: the flag, where it was
    /// read, what End of Manufacturing commits, and a descriptor that is open,
    /// which is the one descriptor state worth naming.
    public static func manufacturingBasis(_ basis: ManufacturingBasis, in language: AppLanguage) -> String {
        guard let flag = basis.flag, let page = basis.page else {
            return L("No End of Manufacturing record in this image.", in: language)
        }
        // German wants the dative here, so the two sources are whole phrases
        // rather than a noun glued onto a preposition.
        let source = page == .liveMFS
            ? L("the file system", in: language)
            : L("the image's OEM Configuration", in: language)
        var sentences = [L("The End of Manufacturing flag is %1$@ in %2$@.",
                           in: language,
                           flag ? L("set", in: language) : L("clear", in: language),
                           source)]
        if flag, let flexible = basis.flexible {
            sentences.append(flexibleText(flexible, in: language))
        }
        if basis.descriptorOpen == true {
            sentences.append(L("The descriptor is open.", in: language))
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
