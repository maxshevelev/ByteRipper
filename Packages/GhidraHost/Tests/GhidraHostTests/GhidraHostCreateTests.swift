import CodeAnalysis
import Foundation
import XCTest
@testable import GhidraHost

/// A project made from a module's bytes here, published through an owner,
/// against an artifact stored for the same bytes earlier. Run with
/// `GHIDRA_PARITY_MODULE` naming the module and `GHIDRA_PARITY_ARTIFACT` the
/// artifact; skipped otherwise.
final class GhidraHostCreateTests: XCTestCase {
    func testAProjectMadeHerePublishesTheStoredArtifact() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let modulePath = environment["GHIDRA_PARITY_MODULE"],
              let artifactPath = environment["GHIDRA_PARITY_ARTIFACT"] else {
            throw XCTSkip("GHIDRA_PARITY_MODULE and GHIDRA_PARITY_ARTIFACT are not set")
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GhidraHostCreateTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ContentStore(root: directory.appendingPathComponent("store"))
        let host = GhidraHost(configuration: .init(projectsRoot: directory.appendingPathComponent("projects"),
                                                   idle: 120, holder: "GhidraHostCreateTests"),
                              writer: store)
        let module = URL(fileURLWithPath: modulePath)
        let blob = try Data(contentsOf: module)
        let state = try await host.create(module: blob, name: module.deletingPathExtension().lastPathComponent)
        XCTAssertEqual(state.module.sha256, SHA256Digest(data: blob).hex)
        let publication = try await host.publish(SHA256Digest(data: blob), by: nil)
        await host.stop(SHA256Digest(data: blob))
        XCTAssertNil(publication.manifest.reading, "a project nobody reviewed publishes the mechanical reading")
        let ours = try store.object(publication.manifest.artifact.sha256)
        XCTAssertEqual(ours, try Data(contentsOf: URL(fileURLWithPath: artifactPath)))
    }
}

/// The library registry end to end on two modules that link the same
/// routine: one reviews it and publishes it into the registry, the other
/// named it differently and converges on the entry when it is applied, and
/// publishing that is no change to the entry. Run with
/// `GHIDRA_LIBRARY_MODULES` naming two module images, the reviewed one
/// first (`AmdSocFp6CznPei.efi:AmdSocFp6RnPei.efi`); skipped otherwise.
final class GhidraHostLibraryTests: XCTestCase {
    private func json(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func body(_ object: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: object) }

    /// The first function of `size` bytes: CopyGuid in both Fp6 modules.
    private func function(of size: Int, in module: SHA256Digest, host: GhidraHost) async throws -> String {
        let list = try json(await host.read(module, "/v1/functions"))["functions"] as? [[String: Any]] ?? []
        return try XCTUnwrap(list.first { $0["size"] as? Int == size }?["entry"] as? String)
    }

    func testAnEntryReviewedInOneModuleIsAppliedInAnother() async throws {
        guard let paths = ProcessInfo.processInfo.environment["GHIDRA_LIBRARY_MODULES"]?.split(separator: ":"),
              paths.count == 2 else {
            throw XCTSkip("GHIDRA_LIBRARY_MODULES is not set")
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GhidraHostLibraryTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ContentStore(root: directory.appendingPathComponent("store"))
        let host = GhidraHost(configuration: .init(projectsRoot: directory.appendingPathComponent("projects"),
                                                   idle: 300, holder: "GhidraHostLibraryTests"),
                              writer: store)
        let images = try paths.map { try Data(contentsOf: URL(fileURLWithPath: String($0))) }
        let reviewed = SHA256Digest(data: images[0]), other = SHA256Digest(data: images[1])
        _ = try await host.create(module: images[0], name: "Reviewed")
        _ = try await host.create(module: images[1], name: "Other")
        defer { Task { await host.stop(reviewed); await host.stop(other) } }

        // The review of CopyGuid, to the registry's bar.
        let copyGuid = try await function(of: 25, in: reviewed, host: host)
        _ = try await host.write(reviewed, "/v1/set/signature", body: body([
            "address": copyGuid, "signature": "EFI_GUID * CopyGuid(EFI_GUID * DestinationGuid, EFI_GUID * SourceGuid)",
            "storage": ["ECX:4", "EDX:4"], "by": "agent", "reason": "EDK2 BaseLib CopyGuid"]))
        _ = try await host.write(reviewed, "/v1/set/comment", body: body([
            "address": copyGuid, "kind": "plate",
            "text": "EDK2 BaseLib CopyGuid: four dword moves and the destination returned."]))
        _ = try await host.write(reviewed, "/v1/set/comment", body: body([
            "address": copyGuid, "kind": "eol", "text": "first dword of the GUID"]))
        _ = try await host.write(reviewed, "/v1/tag/function", body: body(["address": copyGuid, "tag": "library.edk2"]))
        let published = try await host.publish(reviewed, by: "agent")
        XCTAssertNil(published.libraryError)
        let added = try XCTUnwrap(published.library?.added.first { $0.name == "CopyGuid" })
        let entry = try XCTUnwrap(try store.object(store.libraryIndex().entries[added.id]!.entry))
        XCTAssertNotNil(try json(entry)["constants"], "an entry records its body's constants")

        // The publish marked the function with the version the registry took:
        // the module it came from holds the entry as any other would.
        let own = try json(await host.library(reviewed, .init(action: .status)))
        XCTAssertEqual((own["applied"] as? [[String: Any]])?.compactMap { $0["address"] as? String }, [copyGuid],
                       "\(own)")
        let republished = try await host.publish(reviewed, by: "agent")
        let code = try store.artifact(for: republished.manifest)
        XCTAssertEqual(code.functions.first { $0.entry == CodeAddress(hex: copyGuid) }?.nameReason, "EDK2 BaseLib CopyGuid")

        // The other module named the same body its own way.
        let theirs = try await function(of: 25, in: other, host: host)
        _ = try await host.write(other, "/v1/rename/function", body: body([
            "address": theirs, "name": "GuidCopy", "by": "agent"]))
        let status = try json(await host.library(other, .init(action: .status)))
        let steps = status["to_apply"] as? [[String: Any]] ?? []
        XCTAssertEqual(steps.first { $0["address"] as? String == theirs }?["mode"] as? String, "fill")

        let applied = try json(await host.library(other, .init(action: .apply)))
        let result = try XCTUnwrap((applied["results"] as? [[String: Any]])?.first { $0["address"] as? String == theirs })
        XCTAssertEqual(result["ok"] as? Bool, true, "\(result)")
        XCTAssertEqual((result["renamed"] as? [String: Any])?["from"] as? String, "GuidCopy")
        XCTAssertEqual(result["marked"] as? Bool, true, "\(result)")
        let read = try json(await host.read(other, "/v1/function/\(theirs)?summary=1"))
        XCTAssertEqual(read["signature"] as? String,
                       "EFI_GUID * CopyGuid(EFI_GUID * DestinationGuid, EFI_GUID * SourceGuid)")
        XCTAssertEqual((read["parameters"] as? [[String: Any]])?.map { $0["storage"] as? String }, ["ECX:4", "EDX:4"])

        // Applied, then published: the same entry, no change.
        let again = try await host.publish(other, by: "agent")
        XCTAssertNil(again.libraryError)
        XCTAssertEqual(again.library?.unchanged.map(\.name), ["CopyGuid"], "\(String(describing: again.library))")
        XCTAssertEqual(again.library?.conflicts, [])
        let after = try json(await host.library(other, .init(action: .status)))
        XCTAssertEqual((after["applied"] as? [[String: Any]])?.compactMap { $0["address"] as? String }, [theirs])

        // Edited since: the review's now, not applied over.
        _ = try await host.write(other, "/v1/set/comment", body: body([
            "address": theirs, "kind": "plate", "text": "Copied from the registry, then edited."]))
        let edited = try json(await host.library(other, .init(action: .status)))
        XCTAssertEqual((edited["edited"] as? [[String: Any]])?.compactMap { $0["address"] as? String }, [theirs])
        XCTAssertEqual((edited["to_apply"] as? [Any])?.count, 0)

        // That edit was made on the entry's current version: published, it is
        // the next version, from a module that did not write the first.
        let improved = try await host.publish(other, by: "agent")
        XCTAssertEqual(improved.library?.updated.map(\.version), [added.version + 1], "\(String(describing: improved.library))")
        XCTAssertEqual(improved.library?.conflicts, [])

        // The first module is a version behind now: its review, offered again
        // after its own edit, is a conflict like any other module's.
        _ = try await host.write(reviewed, "/v1/set/comment", body: body([
            "address": copyGuid, "kind": "eol", "text": "the first dword"]))
        let behind = try await host.publish(reviewed, by: "agent")
        XCTAssertEqual(behind.library?.conflicts.map(\.base), [added.version], "\(String(describing: behind.library))")
        XCTAssertEqual(behind.library?.conflicts.first?.version, added.version + 1)
    }
}
