import AgentKit
import Foundation

/// Keeps the relay a client's configuration names where that configuration can
/// go on pointing at it: **beside the socket**, in the user's Application
/// Support folder, rather than inside the app bundle the person happened to run.
///
/// A configuration made once is meant to stay good. The helper inside a bundle
/// gives it no chance of that: the app under Xcode lives in DerivedData, whose
/// folder is named after the *project's path*, so a second copy of the
/// repository — or a build an agent made in its own scratch folder — hands out
/// another path, and the client is left naming a file that copy will never
/// rebuild. The installed copy is one path for every copy of the app on this
/// account, and each launch brings it up to that app's version.
///
/// Nothing here decides anything about a client: what it changes is the path
/// Settings ▸ Agent hands out (`AgentClientConfiguration.relayPath`), which
/// keeps the bundled helper as the answer whenever this has not run.
enum AgentRelayInstall {
    /// The helper inside the running app bundle — what gets installed.
    static var bundledHelper: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/\(AgentEndpoint.relayName)")
    }

    /// Where the client is told to find it.
    static var installed: URL {
        URL(fileURLWithPath: AgentEndpoint.relayPath())
    }

    /// Copies the bundled helper over the installed one and makes it
    /// executable. Answers whether the installed copy is the app's own — false
    /// when there was nothing to copy, or the copy failed, and the settings then
    /// hand out the bundled path, which is what they did before this existed.
    ///
    /// The new file is staged beside the old one and renamed over it, so a relay
    /// that is *running* while the app launches goes on running the file it was
    /// started from, and the next client to start one gets this app's version.
    @discardableResult
    static func install(helper: URL = AgentRelayInstall.bundledHelper,
                        at destination: URL = AgentRelayInstall.installed) -> Bool {
        let manager = FileManager.default
        guard manager.isReadableFile(atPath: helper.path) else { return false }
        let folder = destination.deletingLastPathComponent()
        let staged = folder.appendingPathComponent("\(AgentEndpoint.relayName).new")
        do {
            try manager.createDirectory(at: folder, withIntermediateDirectories: true)
            try? manager.removeItem(at: staged)
            try manager.copyItem(at: helper, to: staged)
            try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staged.path)
            if manager.fileExists(atPath: destination.path) {
                _ = try manager.replaceItemAt(destination, withItemAt: staged)
            } else {
                try manager.moveItem(at: staged, to: destination)
            }
            return true
        } catch {
            try? manager.removeItem(at: staged)
            return false
        }
    }
}
