import Foundation
import Localization
import MEFirmware

// help: panel.me.manufacturing
/// The three facts a repair bench asks of a dump it is about to flash: whether
/// the image closes Manufacturing on its first boot, which Boot Guard profile
/// it is built for, and which OEM public key hash it carries. Ours —
/// MEAnalyzer prints none of them — and each of them says what the *dump*
/// shows rather than what a vendor usually does.
///
/// Their **values** are English in every language, like the tools' own option
/// words: "Will close on the EOM flag", "5 - FVME", `Disabled`. The row names
/// around them are translated; the finding a technician quotes is not.
extension MEAText {
    /// The Manufacturing verdict as one phrase, naming the mechanism that
    /// decided it: two of them do, and which one is at work is the difference
    /// between an image the workshop built to stay open and one straight from a
    /// manufacturer (`ManufacturingBasis.flag` is the one it turns on).
    public static func manufacturingState(_ state: ManufacturingState,
                                          basis: ManufacturingBasis?) -> String {
        let byFlag = basis?.flag == true
        switch state {
        case .willClose:
            return byFlag
                ? "Will close on the EOM flag"
                : "Will close on the descriptor's rights"
        case .willNotClose:
            return "Will not close"
        case .unexpectedCombination:
            return "Will close on the EOM flag, with the descriptor open"
        case .unknown:
            return "Not readable from this image"
        case .noSwitch:
            return "No such switch in this firmware"
        }
    }

    /// What the Manufacturing verdict was read from, as short as it can be
    /// said: "EOM: off, descriptor: open".
    /// The row puts it in brackets after the verdict, and draws it in the
    /// ordinary font and colour — it is evidence, not a second verdict, and the
    /// colour belongs to the answer alone.
    ///
    /// A fact the image could not supply is left out rather than filled with a
    /// dash: an image with no such record says so in the verdict itself
    /// (`Not readable from this image`) and needs no "EOM: unknown" beside it.
    /// Returns "" when there is nothing to say.
    public static func manufacturingEvidence(_ state: ManufacturingState,
                                             basis: ManufacturingBasis?) -> String {
        guard let basis else { return "" }
        var clauses: [String] = []
        if let flag = basis.flag {
            clauses.append(flag ? "EOM: on" : "EOM: off")
        }
        // The verdict names the open descriptor in its own words, so the clause
        // would only repeat it.
        if state != .unexpectedCombination, let open = basis.descriptorOpen {
            clauses.append(open ? "descriptor: open" : "descriptor: locked")
        }
        return clauses.joined(separator: ", ")
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
    /// The three findings that are not a value say which they are rather than
    /// "no key" (`OEMKeyHash`): a key field reading zeros is the manufacturer's
    /// own "signing disabled", an erased one was never written, and one this
    /// reader cannot walk is a layout it does not know. Three different states
    /// of a boot chain, and the help explains what to do about each.
    /// Whether the platform binds its SPI part to the chipset — the fact the
    /// tool calls "Hardware Binding Enabled" and its own help names the FPF
    /// hardware and RPMC / RPMB binding. The value words are the tool's value
    /// class (`DisabledEnabledValues`), kept in every language as its option
    /// labels are.
    public static func hardwareBinding(_ value: HardwareBinding, in language: AppLanguage) -> String {
        switch value {
        // The row is already named "RPMC Hardware Binding", so the value is
        // the finding alone: the tool's own option words, which stay English
        // in every language as every option label of the tool does.
        case .disabled: return "Disabled"
        case .enabled: return "Enabled"
        case .other(let byte):
            return L("Unexpected value %1$@", in: language,
                     String(format: "0x%02X", byte))
        case .notInImage: return L("Not recorded in this image", in: language)
        }
    }

    public static func oemPublicKeyHash(_ value: OEMKeyHash, in language: AppLanguage) -> String {
        switch value {
        case .hash(let hex):
            return spacedBytes(hex)
        case .allZeros:
            return L("Not set (all zeros)", in: language)
        case .erased:
            return L("Not set (the area is erased)", in: language)
        case .unrecognized:
            return L("Layout not recognized", in: language)
        }
    }

    /// A key's hex as a row shows it: **byte by byte, a space between them**, so
    /// a bench can hold it against a repair tool's report without counting
    /// characters. The model keeps the hash unspaced — a value is not a layout,
    /// and two dumps' hashes are compared as they are stored — so the grouping
    /// is this function's, and it is the one every row and answer goes through.
    static func spacedBytes(_ hex: String) -> String {
        stride(from: 0, to: hex.count, by: 2).map { offset -> String in
            let from = hex.index(hex.startIndex, offsetBy: offset)
            let to = hex.index(from, offsetBy: min(2, hex.count - offset))
            return String(hex[from..<to])
        }.joined(separator: " ")
    }
}
