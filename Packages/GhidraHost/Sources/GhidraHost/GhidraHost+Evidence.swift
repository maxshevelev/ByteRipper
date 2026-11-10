import CodeAnalysis
import Foundation

/// A publish checks the `Evidence:` line of every EDK2 function it offers the
/// registry against the pinned tag's sources, and says what does not hold.
/// It is a warning: the publish is stored either way. Finding the source is
/// the reviewer's; the check only reads the file and line cited.
extension GhidraHost {
    public struct EvidenceWarning: Codable, Equatable, Sendable {
        public var address: String
        public var name: String
        public var findings: [EDK2Evidence.Finding]
    }

    /// The warnings for the offered EDK2 functions, how many were checked, or
    /// why they could not be. A checkout not there yet starts its fetch,
    /// which the next publish reads.
    func evidenceCheck(_ offered: [LibraryProposal]) -> (warnings: [EvidenceWarning], checked: Int, unchecked: String?) {
        let edk2 = offered.filter { $0.kind == "edk2" }
        guard !edk2.isEmpty, let checkout = configuration.edk2Sources else { return ([], 0, nil) }
        guard FileManager.default.fileExists(atPath: checkout.appendingPathComponent(EDK2Evidence.listingName).path)
        else {
            let failed = edk2FetchError
            startEDK2Fetch(into: checkout)
            return ([], 0, "the \(UEFITypes.edk2Tag) library sources are not here yet; they are being fetched, "
                    + "and a later publish checks the Evidence lines"
                    + (failed.map { " (the last fetch failed: \($0))" } ?? ""))
        }
        return (Self.evidenceWarnings(edk2, checkout: checkout), edk2.count, nil)
    }

    static func evidenceWarnings(_ proposals: [LibraryProposal], checkout: URL) -> [EvidenceWarning] {
        proposals.filter { $0.kind == "edk2" }.compactMap { proposal in
            let entry = (try? JSONSerialization.jsonObject(with: proposal.entry)) as? [String: Any]
            let findings = EDK2Evidence.check(plate: entry?["plate"] as? String ?? "", checkout: checkout)
            guard findings.contains(where: { $0.outcome != .ok }) else { return nil }
            return EvidenceWarning(address: proposal.address, name: proposal.name, findings: findings)
        }
        .sorted { ($0.name, $0.address) < ($1.name, $1.address) }
    }

    func startEDK2Fetch(into checkout: URL) {
        guard edk2Fetch == nil else { return }
        edk2Fetch = Task { [weak self] in
            var failure: String?
            do {
                try await UEFITypes.fetchLibrarySources(into: checkout)
            } catch {
                failure = "\(error)"
            }
            await self?.endEDK2Fetch(failure)
        }
    }

    private func endEDK2Fetch(_ failure: String?) {
        edk2FetchError = failure
        edk2Fetch = nil
    }
}
