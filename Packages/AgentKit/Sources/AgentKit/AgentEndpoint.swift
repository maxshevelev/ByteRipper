import Foundation

/// Where the app and the relay meet, named in one place so the two cannot
/// disagree.
public enum AgentEndpoint {
    /// The variable that moves the socket elsewhere — for a test, or for a
    /// second build of the app run beside the installed one.
    public static let environmentKey = "BYTERIPPER_AGENT_SOCKET"

    /// `~/Library/Application Support/ByteRipper/agent.sock`, unless the
    /// environment names another path.
    public static func socketPath(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let path = environment[environmentKey], !path.isEmpty { return path }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("ByteRipper/agent.sock").path
    }

    /// What a client is told when there is nothing to talk to: the app is not
    /// running, or its agent service is switched off. Worded for the person
    /// reading the client's error, since a model can do nothing about it.
    public static let unavailableMessage =
        "ByteRipper's agent service is not running. Open ByteRipper and switch it on in Settings ▸ Agent."
}
