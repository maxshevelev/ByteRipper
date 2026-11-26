import CodeAnalysis
import Foundation

extension GhidraHost {
    /// `ghidra_profile`'s answer: the analysis profile the module's facts
    /// derive (`AnalysisProfile.derive`), with what applies to it, its type
    /// group as this host decides it, and the profile the module's latest
    /// revision was made under when that revision recorded one. Read from the
    /// project's state and the store: no owner is started.
    struct ProfileAnswer: Encodable {
        var module: String
        var kind: String
        var profile: AnalysisProfile?
        /// `"<id>@<version>"` of `profile`.
        var stamp: String?
        var typeGroup: String
        /// Why there is no profile, when there is none.
        var note: String?
        var latestRevision: Int?
        /// The profile the latest revision recorded; nil before the first
        /// revision or in one published before revisions recorded it.
        var latestRevisionProfile: String?

        private enum CodingKeys: String, CodingKey {
            case module, kind, profile, stamp, note
            case typeGroup = "type_group"
            case latestRevision = "latest_revision"
            case latestRevisionProfile = "latest_revision_profile"
        }
    }

    func profileAnswer(_ module: SHA256Digest) async throws -> Data {
        let state = try project(module).state()
        let profile = AnalysisProfile.derive(kind: state.module.kind, ecFamily: state.module.ec?.family)
        let latest = try await writer.latestRevision(module: module)
        let answer = ProfileAnswer(
            module: module.hex, kind: state.module.kind, profile: profile, stamp: profile?.stamp,
            typeGroup: Self.typeGroup(state),
            note: profile == nil ? "no analysis profile covers a module of kind \(state.module.kind)"
                + (state.module.ec.map { ", family \($0.family)" } ?? "") : nil,
            latestRevision: latest?.rev, latestRevisionProfile: latest?.profile)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(answer)
    }
}
