import Foundation
import Localization
import MEFirmware

// help: panel.me.state-basis
/// What the File System State was decided from, in one paragraph — the
/// Firmware row's detail in the panels, and the agent's `explanation`, which
/// reads it in English. The state is upstream's; the paragraph is ours, so a
/// state left standing by a step that could not be taken is not read as one
/// the flash shows (`MFSStateBasis`).
extension MEAText {
    public static func fileSystemStateBasis(_ state: MFSState, _ basis: MFSStateBasis) -> String {
        let name = title(state.rawValue)
        var sentences: [String] = []
        switch basis.decidedBy {
        case .reservedFiles:
            sentences.append(L("%1$@, from the reserved MFS files present.", name))
        case .efs:
            sentences.append(L("%1$@, because the EFS volume holds file content: the engine has run and written its files.", name))
        case .configuration:
            sentences.append(L("%1$@, from the configuration found (%2$@), not from files the engine wrote.",
                               name, basis.configuration.joined(separator: ", ")))
        case .nothing:
            sentences.append(L("%1$@: no reserved MFS file, no EFS content and no configuration partition.", name))
        }
        if basis.isIncomplete {
            switch basis.efs {
            case .unreadable(let offset):
                sentences.append(L("The EFS partition at %1$@ could not be read, so whether it holds files — which would make the state Initialized — is unknown. Check its system page before relying on this state.",
                                   offsetText(offset)))
            case .filesNotNamed:
                sentences.append(L("The EFS volume's files cannot be told without the firmware database's file table, so whether it holds files — which would make the state Initialized — is unknown."))
            default:
                break
            }
        }
        if basis.reservedFiles == .notRead, basis.decidedBy != .efs {
            sentences.append(L("This volume does not name its reserved files by index, so only the EFS and the configuration decide."))
        }
        return sentences.joined(separator: " ")
    }

    private static func offsetText(_ offset: Int) -> String {
        String(format: "0x%llX", UInt64(max(0, offset)))
    }
}
