import Foundation
import XCTest
@testable import GhidraHost

/// Owners no `owner.json` names, found by their command line.
final class OwnerOrphansTests: XCTestCase {
    func testAnOwnerIsFoundByItsProjectUnderTheRootWhateverTheSpacesInThePath() {
        let root = URL(fileURLWithPath: "/Users/x/Library/Application Support/ByteRipper/Server/GhidraProjects")
        let module = String(repeating: "ab", count: 32)
        let lines = """
              93162 /Library/Java/bin/java -Xmx4G -cp /a:/b Owner --project-dir \(root.path)/\(module) --project-name module --port 0
              93281 /Users/x/byteripper-analysis/bin/byteripper-server --dump-roots /Users/x
              42865 /Library/Java/bin/java -cp /a Owner --project-dir /elsewhere/GhidraProjects/\(module) --port 0
              50000 /usr/bin/less Owner --project-dir \(root.path)/short
            """
        XCTAssertEqual(OwnerOrphans.parse(lines, projectsRoot: root),
                       [.init(pid: 93162, module: module)], "only this root's, and only a whole module id")
    }

    func testTheListeningPortIsReadFromLsof() {
        XCTAssertEqual(OwnerOrphans.parsePort("p93162\nf184\nn127.0.0.1:59255\n"), 59255)
        XCTAssertNil(OwnerOrphans.parsePort("p93162\n"))
    }
}
