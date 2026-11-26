// The analysis profiles are declared in their own package; the store's part is
// mapping a module's facts to one. Re-exported, so a reader of the store sees
// `AnalysisProfile` as before.
@_exported import AnalysisProfiles

extension AnalysisProfile {
    /// The profile of the module `identity` names.
    public static func derive(for identity: ModuleIdentity) -> AnalysisProfile? {
        derive(kind: identity.kind, ecFamily: identity.ec?.family)
    }

    /// `libraryKinds` as the store's kinds; a raw value the store does not
    /// know is left out.
    public var libraryKindValues: [LibraryKind] { libraryKinds.compactMap(LibraryKind.init(rawValue:)) }
}
