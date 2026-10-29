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

    /// Whether this launch's install succeeded. Settings ▸ Agent hands out the
    /// installed copy only then: a copy left there by an earlier build is not
    /// this app's relay, and an install that failed says nothing about it.
    private(set) static var installedAtLaunch = false

    /// The install the app runs once as it starts, remembered for the settings.
    static func installAtLaunch() {
        installedAtLaunch = install()
    }

    /// Copies the bundled helper over the installed one and makes it
    /// executable, and records `app` beside it (`AgentEndpoint.appRecordName`):
    /// the installed copy is not inside a bundle, and this is how it knows which
    /// app to start. Answers whether the installed copy is the app's own — false
    /// when there was nothing to copy, or the copy failed, and the settings then
    /// hand out the bundled path, which is what they did before this existed.
    ///
    /// The new file is staged beside the old one and renamed over it, so a relay
    /// that is *running* while the app launches goes on running the file it was
    /// started from, and the next client to start one gets this app's version.
    @discardableResult
    static func install(helper: URL = AgentRelayInstall.bundledHelper,
                        at destination: URL = AgentRelayInstall.installed,
                        app: URL = Bundle.main.bundleURL) -> Bool {
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
            try Data(app.path.utf8).write(to: folder.appendingPathComponent(AgentEndpoint.appRecordName),
                                          options: .atomic)
            return true
        } catch {
            try? manager.removeItem(at: staged)
            return false
        }
    }
}
