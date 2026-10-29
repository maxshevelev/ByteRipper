import XCTest
@testable import AgentKit

/// Where the app and the relay meet: the socket, and the relay the client is
/// told to run — the installed copy beside the socket, never a path inside the
/// app bundle (`AgentEndpoint.relayPath`).
final class AgentEndpointTests: XCTestCase {
    /// The usual case: both in the user's Application Support folder, whatever
    /// copy of the app is running.
    func testTheRelaySitsBesideTheSocketInApplicationSupport() {
        let socket = AgentEndpoint.socketPath(environment: [:])
        XCTAssertTrue(socket.hasSuffix("/Library/Application Support/ByteRipper/agent.sock"), socket)
        XCTAssertEqual(AgentEndpoint.relayPath(environment: [:]),
                       socket.replacingOccurrences(of: "/agent.sock", with: "/\(AgentEndpoint.relayName)"))
        XCTAssertFalse(AgentEndpoint.relayPath(environment: [:]).contains(".app/"),
                       "a bundle's path changes with the folder the app was built in")
    }

    /// A socket moved for a test, or for a second build beside the installed
    /// one, carries its own relay: the two must not share a file.
    func testASocketElsewhereCarriesItsOwnRelay() {
        let environment = [AgentEndpoint.environmentKey: "/tmp/bytest/agent.sock"]
        XCTAssertEqual(AgentEndpoint.socketPath(environment: environment), "/tmp/bytest/agent.sock")
        XCTAssertEqual(AgentEndpoint.relayPath(environment: environment),
                       "/tmp/bytest/\(AgentEndpoint.relayName)")
    }

    /// The variable names the socket itself, not only its folder: a socket
    /// called something other than `agent.sock` is the one both ends use, and
    /// the one a script reading the same variable connects to.
    func testTheVariableNamesTheSocketFileItself() {
        let environment = [AgentEndpoint.environmentKey: "/tmp/bytest/test.sock"]
        XCTAssertEqual(AgentEndpoint.socketPath(environment: environment), "/tmp/bytest/test.sock")
        XCTAssertEqual(AgentEndpoint.relayPath(environment: environment),
                       "/tmp/bytest/\(AgentEndpoint.relayName)")
        XCTAssertEqual(AgentEndpoint.appRecordPath(environment: environment),
                       "/tmp/bytest/\(AgentEndpoint.appRecordName)")
    }
}
