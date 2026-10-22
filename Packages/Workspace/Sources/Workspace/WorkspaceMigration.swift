import Foundation

/// How a workspace written by an earlier build is brought up to this one's
/// version (`Design/WORKSPACE_PLAN.md`, "Versions").
///
/// A project and the session are the person's work, so a build reads what
/// the builds before it wrote — back to `oldestReadable`, the first version
/// this promise was made for. Each step takes the file's JSON from one
/// version to the next and is written against the JSON, not against the
/// types: those are this build's, and describe only the newest version.
///
/// A version is raised only by a change an earlier file cannot be read
/// through: a field that is required, renamed, or means something else, a
/// case taken away. An added optional field needs none — an earlier file
/// simply has not got it.
public enum WorkspaceMigration {
    /// The oldest version this build reads. Earlier ones were written before
    /// workspaces were migrated, and are refused.
    public static let oldestReadable = 4

    /// Takes a workspace's top-level JSON object from one version to the next.
    public typealias Step = (inout [String: Any]) throws -> Void

    /// The steps, by the version each one reads: `steps[4]` makes version 5
    /// out of version 4. One for every version from `oldestReadable` up to
    /// `Workspace.currentVersion`.
    static let steps: [Int: Step] = [:]

    public enum Failure: Error, Equatable {
        /// Not a workspace file at all, or one damaged.
        case unreadable
        /// Written before `oldestReadable`.
        case tooOld(version: Int)
        /// Written by a newer build, which this one cannot know the meaning of.
        case newer(version: Int)
    }

    /// `data` as JSON of version `target`. `data` itself when it already is.
    static func migrate(_ data: Data, to target: Int = Workspace.currentVersion,
                        oldest: Int = oldestReadable, steps: [Int: Step] = steps) throws -> Data {
        guard var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let version = object["version"] as? Int else { throw Failure.unreadable }
        if version == target { return data }
        if version > target { throw Failure.newer(version: version) }
        if version < oldest { throw Failure.tooOld(version: version) }
        for from in version..<target {
            // A version with no step is a hole in the chain, not a file to guess at.
            guard let step = steps[from] else { throw Failure.unreadable }
            do { try step(&object) } catch { throw Failure.unreadable }
            object["version"] = from + 1
        }
        return try JSONSerialization.data(withJSONObject: object)
    }
}
