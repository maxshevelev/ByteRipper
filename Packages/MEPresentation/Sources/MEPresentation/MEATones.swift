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

    // The State basis row has no tone of its own any more: it is drawn in
    // brackets on the state's row, in the ordinary font and colour, and the
    // caution for a step that could not be taken sits on the state itself
    // (`fileSystemState(_:basis:)`).

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

    /// The RPMC Hardware Binding row's tone. The tool's two values are both
    /// settled states, and they read as the bench needs them: **Disabled** —
    /// the SPI part is not bound to the chipset, which is the state a part can
    /// be replaced in — is green; **Enabled** is the caution the File System
    /// State draws for `Initialized`, a state that has been committed to and
    /// that the board now enforces. A byte the tool's class does not name, and
    /// an image that does not record one, are ordinary values: neither says
    /// which state the board is in.
    public static func hardwareBinding(_ binding: HardwareBinding) -> ToolValueTone {
        switch binding {
        case .disabled: return .good
        case .enabled: return .caution
        case .other, .notInImage: return .standard
        }
    }

    /// The Boot Guard row's tone. Profile 0 — `No_FVME`, the boot chain is not
    /// verifying or measuring anything — is green. Every other profile is a
    /// state the board has been committed to, and reads as the caution the
    /// File System State draws for `Initialized`; the number itself still says
    /// which, and what a level means for an edit is the help's to explain, not
    /// the colour's. An image with no profile record keeps the ordinary tone.
    public static func bootGuardProfile(_ profile: BootGuardProfile) -> ToolValueTone {
        profile == .noFVME ? .good : .caution
    }
}
