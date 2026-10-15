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
    /// The Manufacturing verdict as one phrase, naming the mechanism that
    /// decided it: two of them do, and which one is at work is the difference
    /// between an image the workshop built to stay open and one straight from a
    /// manufacturer (`ManufacturingBasis.flag` is the one it turns on).
    public static func manufacturingState(_ state: ManufacturingState,
                                          basis: ManufacturingBasis?,
                                          in language: AppLanguage) -> String {
        let byFlag = basis?.flag == true
        switch state {
        case .willClose:
            return byFlag
                ? L("Will close on the EOM flag", in: language)
                : L("Will close on the descriptor's rights", in: language)
        case .willNotClose:
            return L("Will not close", in: language)
        case .unexpectedCombination:
            return L("Will close on the EOM flag, with the descriptor open", in: language)
        case .unknown:
            return L("Not readable from this image", in: language)
        case .noSwitch:
            return L("No such switch in this firmware", in: language)
        }
    }

    /// What the Manufacturing verdict was read from, in one short paragraph —
    /// the same idea as the File System State's basis, and shown the same way
    /// under its row.
    ///
    /// The flag is named only when the image carries one, because a clear flag
    /// is not an answer by itself: what a serial image does is what its
    /// descriptor rights say, and the second sentence is the one that carries
    /// the verdict in that case.
    public static func manufacturingBasis(_ basis: ManufacturingBasis, in language: AppLanguage) -> String {
        var sentences: [String] = []
        if let flag = basis.flag, let page = basis.page {
            // German wants the dative here, so the two sources are whole
            // phrases rather than a noun glued onto a preposition.
            let source = page == .liveMFS
                ? L("the file system", in: language)
                : L("the image's OEM Configuration", in: language)
            sentences.append(L("The End of Manufacturing flag is %1$@ in %2$@.",
                               in: language,
                               flag ? L("set", in: language) : L("clear", in: language),
                               source))
            if flag, let flexible = basis.flexible {
                sentences.append(flexibleText(flexible, in: language))
            }
        }
        // With the flag set the descriptor decides nothing, and with it clear
        // the descriptor is the whole answer.
        if basis.flag != true {
            switch basis.descriptorOpen {
            case .some(false):
                sentences.append(L("The descriptor's access rights are what close Manufacturing.",
                                   in: language))
            case .some(true):
                sentences.append(L("The descriptor is open, so nothing closes it.", in: language))
            case nil:
                break
            }
        }
        return sentences.isEmpty
            ? L("No End of Manufacturing record in this image.", in: language)
            : sentences.joined(separator: " ")
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
