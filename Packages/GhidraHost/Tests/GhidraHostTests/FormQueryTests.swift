import Foundation
import XCTest
@testable import GhidraHost

/// A query value reaches the owner and the server as it was written: both
/// decode `+` as a space, so a `+` in a value is sent as `%2B`.
final class FormQueryTests: XCTestCase {
    func testAPlusInAValueIsSentEncoded() {
        let query = FormQuery.encode(["section": "SMM + DXE handoff", "name": "a&b=c"])
        XCTAssertEqual(query, "name=a%26b%3Dc&section=SMM%20%2B%20DXE%20handoff")
        // As the owner's URLDecoder and the server's parser read it: `+` a space first, then percent-decoded.
        let section = query.split(separator: "&")[1].split(separator: "=", maxSplits: 1)[1]
        XCTAssertEqual(String(section).replacingOccurrences(of: "+", with: " ").removingPercentEncoding,
                       "SMM + DXE handoff")
        XCTAssertEqual(FormQuery.encode([:]), "")
    }
}
