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

    /// The Manufacturing row's tone. A machine that will **not** close
    /// Manufacturing boots on and can still be worked on, which is the state a
    /// bench wants to see: green. One that **will** close on its next boot is
    /// committing itself — the same tone the File System State draws for
    /// `Initialized`, since both say "this has run, or is about to, and what is
    /// written after that is final". The flag set with an open descriptor is
    /// the combination MFIT refuses to build and reads the same way: it will
    /// close, and the descriptor it locks is not the one a build would leave.
    public static func manufacturingState(_ state: ManufacturingState) -> ToolValueTone {
        switch state {
        case .willNotClose: return .good
        case .willClose, .unexpectedCombination: return .caution
        case .unknown, .noSwitch: return .standard
        }
    }

    // The Manufacturing basis row has no tone of its own: it states the flag,
    // where it was read and what the descriptor says, and none of that is a
    // verdict — so it is drawn as an ordinary value, exactly as the File System
    // State's basis is. The verdict's own colour sits on the row above it.

    /// The Boot Guard profile's tone. Profile 0 has Boot Guard switched off —
    /// the machine boots unverified, and that is a state a bench works with
    /// rather than against: green, the tone a known-good state gets. A profile
    /// that names a level is the same tone as `Initialized`: the platform is
    /// protected, and what the protection means for an edit has to be read in
    /// the help rather than guessed from a colour. `standard` where the row is
    /// only saying that the image carries no profile record — nothing is known
    /// either way.
    public static func bootGuardProfile(_ profile: BootGuardProfile?) -> ToolValueTone {
        switch profile {
        case .some(.noFVME): return .good
        case .some: return .caution
        case nil: return .standard
        }
    }
}
