import Foundation
import Localization
import MEFirmware

// help: panel.me.state-basis
/// What the File System State was decided from, as short as it can be put: the
/// state is the row's answer, and this is what stands behind it, in brackets
/// after it — "Initialized (EFS: holds files)". The panel draws it in the
/// ordinary font and colour, because it is evidence and not a second answer;
/// it is English in every language, as the state it stands behind is.
///
/// The long explanation lives in the help, where there is room for what each
/// clause means: the three criteria, the reserved indices, and what an EFS
/// volume that could not be read leaves unknown. The state itself is
/// upstream's; the brackets are ours (`MFSStateBasis`).
extension MEAText {
    /// The evidence, as clauses joined by "; " — the deciding fact first, then
    /// the caveat a step that could not be taken leaves. Returns "" when there
    /// is nothing to say.
    public static func fileSystemStateEvidence(_ state: MFSState,
                                               _ basis: MFSStateBasis) -> String {
        var clauses: [String] = []
        switch basis.decidedBy {
        case .reservedFiles:
            switch basis.reservedFiles {
            case .initializing(let indices), .configuring(let indices):
                clauses.append("reserved files: "
                               + indices.map(String.init).joined(separator: ", "))
            case .none, .notRead:
                break
            }
        case .efs:
            clauses.append("EFS: holds files")
        case .configuration:
            clauses.append("configuration: "
                           + basis.configuration.joined(separator: ", "))
        case .nothing:
            clauses.append("nothing found")
        }
        // A step that could have raised the state and was not taken: the row's
        // tone turns to a caution for it, and the clause says which step.
        switch basis.efs {
        case .unreadable where basis.isIncomplete:
            clauses.append("EFS: unreadable")
        case .filesNotNamed where basis.isIncomplete:
            clauses.append("EFS: files not named")
        default:
            break
        }
        return clauses.joined(separator: "; ")
    }

    /// The row as one line for a copy of it: the state, then its evidence in
    /// brackets where there is any.
    public static func fileSystemState(_ state: MFSState,
                                       basis: MFSStateBasis?) -> String {
        let name = title(state.rawValue)
        guard let basis else { return name }
        let evidence = fileSystemStateEvidence(state, basis)
        return evidence.isEmpty ? name : "\(name) (\(evidence))"
    }
}
