import Foundation

/// Where the app and the relay meet, named in one place so the two cannot
/// disagree.
public enum AgentEndpoint {
    /// The variable that moves the socket elsewhere — for a test, or for a
    /// second build of the app run beside the installed one.
    public static let environmentKey = "BYTERIPPER_AGENT_SOCKET"

    /// `~/Library/Application Support/ByteRipper/agent.sock`, unless the
    /// environment names another path — and then that path as it is, file name
    /// and all: a script that reads the same variable connects to exactly it.
    public static func socketPath(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let path = environment[environmentKey], !path.isEmpty { return path }
        return folder(environment: environment).appendingPathComponent("agent.sock").path
    }

    /// The name the relay is installed under, beside the socket.
    public static let relayName = "byteripper-mcp"

    /// The relay a client's configuration names: **a copy of the app's helper
    /// kept beside the socket**, not the helper inside whichever bundle happens
    /// to be running.
    ///
    /// A path inside a bundle is not one to put in a client's configuration.
    /// The app under Xcode lives in DerivedData, whose folder is named after the
    /// *project's path* — so running the app from a second copy of the
    /// repository, or from a build an agent made in its own scratch folder,
    /// hands out a different path, and the configuration copied yesterday names
    /// a file that copy will never rebuild. This path is the same for every copy
    /// of the app on the account, and the app keeps the file itself at each
    /// launch (`AgentRelayInstall`), so it is also the current app's relay
    /// whatever the app was launched from.
    public static func relayPath(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        folder(environment: environment).appendingPathComponent(relayName).path
    }

    /// The name of the file beside the installed relay that holds the path of
    /// the app bundle that installed it. The installed copy is not inside a
    /// bundle, so this is how it knows which app to start
    /// (`AgentEndpoint.launchKey`): the one launched last.
    public static let appRecordName = "byteripper-mcp.app-path"

    /// Where that record is: beside the relay.
    public static func appRecordPath(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        folder(environment: environment).appendingPathComponent(appRecordName).path
    }

    /// The folder the two live in — taken from the socket's own path, so a
    /// test's or a second build's socket carries its relay with it.
    public static func folder(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let path = environment[environmentKey], !path.isEmpty {
            return URL(fileURLWithPath: path).deletingLastPathComponent()
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("ByteRipper")
    }

    /// The variable that lets the relay start the app. Without it the relay
    /// never does: a client restarts its server as soon as the app quits, and
    /// a person who quit ByteRipper saw it come straight back. It is set in
    /// the client's configuration — Settings ▸ Agent writes it there when its
    /// launch switch is on — because the relay runs without the app and reads
    /// none of its settings.
    public static let launchKey = "BYTERIPPER_LAUNCH"

    /// Whether the relay starts the app when the socket does not answer: only
    /// with `launchKey` set to something other than empty, "0" or "false".
    public static func launchesApp(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        guard let value = environment[launchKey]?.trimmingCharacters(in: .whitespaces).lowercased() else {
            return false
        }
        return !(value.isEmpty || value == "0" || value == "false")
    }

    /// What a client is told when there is nothing to talk to: the app is not
    /// running, or its agent service is switched off. Worded for the person
    /// reading the client's error, since a model can do nothing about it.
    public static let unavailableMessage =
        "ByteRipper's agent service is not running. Open ByteRipper and switch it on in Settings ▸ Agent."

    /// The same, from a relay that does not start the app (`launchKey`):
    /// the app may simply not be open.
    public static let notStartedMessage =
        "ByteRipper is not running, or its agent service is switched off. Open ByteRipper and switch the service "
        + "on in Settings ▸ Agent. To have this server start ByteRipper, turn on \"Start ByteRipper when an agent "
        + "connects\" there and copy the configuration into this client again."
}
