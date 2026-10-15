import Foundation
import MEFirmware
import ToolModuleKit

/// The tone for each ME fact that carries a status rather than just a value.
///
/// Shared rather than written where it is drawn: the Summary tab's row and the
/// tree's detail row describe the same fact, and a reader comparing the two
/// should not find two colours — nor one panel that says "Configured" in green
/// and another that says it in the ordinary label colour.
public enum MEATones {
    /// The File System State's tone. The two settled states — the volume has no
    /// files yet (`unconfigured`) and it is fully set up (`configured`) — read as
    /// green; a volume mid-lifecycle (`initialized`) is brown; a failed decode
    /// (`error`) is red.
    public static func fileSystemState(_ state: MFSState) -> ToolValueTone {
        switch state {
        case .unconfigured, .configured: return .good
        case .initialized: return .caution
        case .error: return .bad
        }
    }

    /// The File System State's tone once what it rests on is known. A state
    /// a step that could not be taken left standing — an EFS partition that
    /// could not be read, whose files would have made it Initialized — is not
    /// a settled one, and green would say it is: it reads as a caution at
    /// best, and keeps red where the state itself is an error.
    public static func fileSystemState(_ state: MFSState, basis: MFSStateBasis?) -> ToolValueTone {
        let own = fileSystemState(state)
        guard let basis, basis.isIncomplete else { return own }
        return own == .bad ? .bad : .caution
    }

    /// The State basis row's tone: a caution when the basis is incomplete,
    /// so the row that says why the state cannot be relied on is not passed
    /// over; plain otherwise.
    public static func stateBasis(_ basis: MFSStateBasis) -> ToolValueTone {
        basis.isIncomplete ? .caution : .standard
    }

    /// The Manufacturing row's tone. "Already closed" is the settled state of a
    /// board in service and reads green; a machine that will close on its next
    /// boot is about to be committed but intact, so brown; one that will *not*
    /// close is a machine about to be shipped with Manufacturing open — red,
    /// the same red the warnings use. The flag set with an open descriptor is
    /// the combination MFIT refuses to build: also red.
    public static func manufacturingState(_ state: ManufacturingState) -> ToolValueTone {
        switch state {
        case .closed: return .good
        case .willClose: return .caution
        case .willNotClose, .unexpectedCombination: return .bad
        case .unknown, .noSwitch: return .standard
        }
    }

    /// The Manufacturing basis row: a caution wherever the verdict rests on
    /// something less than both pages — an open descriptor, or a file system
    /// that could not be looked in. Plain when the answer is settled.
    public static func manufacturingBasis(_ basis: ManufacturingBasis) -> ToolValueTone {
        switch basis.descriptorOpen {
        case true: return .caution
        case false: return basis.liveFilesResolved ? .standard : .caution
        case nil: return basis.liveFilesResolved ? .standard : .caution
        }
    }

    /// The Boot Guard profile's tone. Profile 0 has Boot Guard switched off —
    /// the machine boots unverified, which a bench should notice; a profile
    /// with a name is a protected board. `standard` where the row is only
    /// saying that the image carries no profile record at all.
    public static func bootGuardProfile(_ profile: BootGuardProfile?) -> ToolValueTone {
        guard let profile else { return .standard }
        return profile == .noFVME ? .caution : .good
    }
}
