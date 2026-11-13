import CodeAnalysis
import Foundation
import XCTest
@testable import GhidraHost

extension GhidraHost {
    /// The module's definitions proposed, and the proposal agreed by an
    /// administrator as the console's Proposals page decides it: the only way
    /// a shared type or a registry entry is replaced, at the module's next
    /// publish. Answers the proposal's id.
    func agreedByAdministrator(_ module: SHA256Digest, holder: String, reason: String) async throws -> String {
        let data = try await typeProposalCall(.init(action: .propose, agent: "Reviewer", module: module.hex,
                                                    reason: reason), holder: holder)
        let answer = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let id = try XCTUnwrap(answer["id"] as? String, "\(answer)")
        _ = try await XCTUnwrap(typeProposals).force(id, agree: true, note: nil, by: "admin")
        return id
    }
}
