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

    /// With the registry reading through, `ghidra_function` and `ghidra_functions`
    /// answer a function at its entry with the entry's text, the same as the
    /// store does; an edit is the review's own; what is taken out is the module's.
    func testAFunctionAtItsEntryReadsTheRegistryThroughTheOwner() async throws {
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
        func switchTo(_ on: Bool) async throws {
            _ = try await store.changeLibrary(.init(action: .readThrough, reason: "test", on: on), by: "test",
                                        module: reviewed, dryRun: false)
        }

        let copyGuid = try await function(of: 25, in: reviewed, host: host)
        _ = try await host.write(reviewed, "/v1/set/signature", body: body([
            "address": copyGuid, "signature": "EFI_GUID * CopyGuid(EFI_GUID * DestinationGuid, EFI_GUID * SourceGuid)",
            "storage": ["ECX:4", "EDX:4"], "by": "agent", "reason": "EDK2 BaseLib CopyGuid"]))
        _ = try await host.write(reviewed, "/v1/set/comment", body: body([
            "address": copyGuid, "kind": "plate", "text": "EDK2 BaseLib CopyGuid: the plate of the entry."]))
        _ = try await host.write(reviewed, "/v1/set/comment", body: body([
            "address": copyGuid, "kind": "eol", "text": "first dword of the GUID"]))
        _ = try await host.write(reviewed, "/v1/tag/function", body: body(["address": copyGuid, "tag": "library.edk2"]))
        let added = try await host.publish(reviewed, by: "agent").library?.added.first { $0.name == "CopyGuid" }
        let id = try XCTUnwrap(added?.id)

        let theirs = try await function(of: 25, in: other, host: host)
        let at = try XCTUnwrap(CodeAddress(hex: theirs))
        _ = try await host.library(other, .init(action: .apply))
        _ = try await host.publish(other, by: "agent")
        // Off: the project's answer, whatever it holds.
        let off = try json(await host.readCall(other, "function/\(theirs)", query: [:]))
        XCTAssertNil(off["text"])

        try await switchTo(true)
        let on = try json(await host.readCall(other, "function/\(theirs)", query: [:]))
        XCTAssertEqual(on["text"] as? String, "registry", "\(on.keys.sorted())")
        XCTAssertEqual(on["plate"] as? String, "EDK2 BaseLib CopyGuid: the plate of the entry.")
        let asRead = try await store.functionAsRead(module: other, entry: at)
        XCTAssertEqual(on["c"] as? String, asRead?.c, "the owner's answer is what the store reads")
        XCTAssertEqual(on["signature"] as? String, asRead?.signature)
        XCTAssertEqual((on["comments"] as? [[String: Any]])?.first?["text"] as? String, "first dword of the GUID")
        let rows = try json(await host.readCall(other, "functions", query: [:]))["functions"] as? [[String: Any]]
        XCTAssertEqual(rows?.first { $0["entry"] as? String == theirs }?["text"] as? String, "registry")

        // Off again: exactly as before.
        try await switchTo(false)
        let back = try json(await host.readCall(other, "function/\(theirs)", query: [:]))
        XCTAssertEqual(back["c"] as? String, off["c"] as? String)
        XCTAssertEqual(back["plate"] as? String, off["plate"] as? String)
        XCTAssertNil(back["text"])
        try await switchTo(true)

        // An edit is the review's own draft.
        _ = try await host.write(other, "/v1/set/comment", body: body([
            "address": theirs, "kind": "plate", "text": "An edit of this review."]))
        let edited = try json(await host.readCall(other, "function/\(theirs)", query: [:]))
        XCTAssertNil(edited["text"])
        XCTAssertEqual(edited["plate"] as? String, "An edit of this review.")
        XCTAssertEqual((edited["library_entry"] as? [String: Any])?["state"] as? String, "edited")
        _ = try await host.write(other, "/v1/set/comment", body: body(["address": theirs, "kind": "plate",
            "text": off["plate"] as? String ?? ""]))

        // An entry that cannot be read: still marked, no `text`.
        let object = try store.objectURL(XCTUnwrap(store.libraryIndex().entries[id]).entry)
        let saved = try Data(contentsOf: object)
        try FileManager.default.removeItem(at: object)
        let unreadable = try json(await host.readCall(other, "function/\(theirs)", query: [:]))
        XCTAssertNil(unreadable["text"])
        XCTAssertNotNil(unreadable["library_entry"])
        try saved.write(to: object)

        // Taken out: the module's function, no `entry`, released at the next open.
        _ = try await store.changeLibrary(.init(action: .takeOut, id: id, reason: "test"), by: "test", module: reviewed, dryRun: false)
        let gone = try json(await host.readCall(other, "function/\(theirs)", query: [:]))
        XCTAssertNil(gone["text"])
        XCTAssertNil(gone["library_entry"], "\(gone.keys.sorted())")
        let goneRows = try json(await host.readCall(other, "functions", query: [:]))["functions"] as? [[String: Any]]
        XCTAssertNil(goneRows?.first { $0["entry"] as? String == theirs }?["library_entry"])
        let status = try json(await host.library(other, .init(action: .status)))
        XCTAssertEqual((status["released"] as? [[String: Any]])?.first?["address"] as? String, theirs, "\(status)")
    }

    /// `read_through` on, two modules holding one body: any write in a marked
    /// function reads back as the review wrote it, on the entry's source and on
    /// another holder. A publish that does not change the review leaves the
    /// entry, and says what the C does not print; one that does moves the entry
    /// for every holder.
    func testAWriteInAMarkedFunctionIsNeverHidden() async throws {
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
        let source = SHA256Digest(data: images[0]), other = SHA256Digest(data: images[1])
        _ = try await host.create(module: images[0], name: "Reviewed")
        _ = try await host.create(module: images[1], name: "Other")
        defer { Task { await host.stop(source); await host.stop(other) } }
        // GetHobList in both Fp6 modules: 43 bytes, with temporaries.
        let at = try await function(of: 43, in: source, host: host)
        let there = try await function(of: 43, in: other, host: host)
        func read(_ m: SHA256Digest, _ a: String) async throws -> [String: Any] {
            try json(await host.readCall(m, "function/\(a)", query: [:]))
        }
        func row(_ m: SHA256Digest, _ a: String) async throws -> [String: Any]? {
            let rows = try json(await host.readCall(m, "functions", query: [:]))["functions"] as? [[String: Any]]
            return rows?.first { $0["entry"] as? String == a }
        }
        func state(_ answer: [String: Any]?) -> String? { (answer?["library_entry"] as? [String: Any])?["state"] as? String }

        _ = try await host.write(source, "/v1/set/signature", body: body([
            "address": at, "signature": "void * GetHobList(void)", "by": "agent", "reason": "EDK2 HobLib GetHobList"]))
        _ = try await host.write(source, "/v1/set/comment", body: body([
            "address": at, "kind": "plate", "text": "EDK2 HobLib GetHobList: the plate."]))
        _ = try await host.write(source, "/v1/set/comment", body: body([
            "address": at, "kind": "eol", "text": "the first step."]))
        var ordinal = 0
        for local in (try await read(source, at)["locals"] as? [[String: Any]]) ?? []
        where (local["storage"] as? String)?.hasPrefix("HASH") != true {
            ordinal += 1
            var change: [String: Any] = ["function": at, "storage": local["storage"] ?? "", "name": "Named\(ordinal)",
                                         "type": "ushort", "by": "agent"]
            if let use = local["first_use"] { change["first_use"] = use }
            _ = try await host.write(source, "/v1/rename/variable", body: body(change))
        }
        _ = try await host.write(source, "/v1/tag/function", body: body(["address": at, "tag": "library.edk2"]))
        let first = try await host.publish(source, by: "agent")
        let id = try XCTUnwrap(first.library?.added.first { $0.name == "GetHobList" }?.id)
        _ = try await host.library(other, .init(action: .apply))
        _ = try await host.publish(other, by: "agent")
        _ = try await store.changeLibrary(.init(action: .readThrough, reason: "test", on: true), by: "test",
                                          module: source, dryRun: false)

        for (module, address, name) in [(other, there, "OtherBase"), (source, at, "HobBase")] {
            var answer = try await read(module, address)
            XCTAssertEqual(answer["text"] as? String, "registry")
            let locals = answer["locals"] as? [[String: Any]] ?? []
            let temporary = try XCTUnwrap(locals.first { ($0["storage"] as? String)?.hasPrefix("HASH") == true })
            _ = try await host.write(module, "/v1/rename/variable", body: body([
                "function": address, "storage": temporary["storage"] ?? "", "first_use": temporary["first_use"] ?? "",
                "name": name, "by": "agent"]))

            answer = try await read(module, address)
            XCTAssertNil(answer["text"], "a rename reads back")
            XCTAssertEqual(state(answer), "edited")
            XCTAssertEqual((answer["c"] as? String)?.contains(name), true)
            let edited = try await row(module, address)
            XCTAssertNil(edited?["text"])
            XCTAssertEqual(state(edited), "edited")

            // A rename alone is no change to the review: the entry stays.
            let published = try await host.publish(module, by: "agent")
            XCTAssertEqual(published.library?.unchanged.map(\.name).contains("GetHobList"), true)
            XCTAssertEqual(try store.libraryIndex().entries[id]?.version, 1)
            answer = try await read(module, address)
            XCTAssertEqual(answer["text"] as? String, "registry")
            XCTAssertEqual(state(answer), "entry")
            XCTAssertEqual((answer["c"] as? String)?.contains(name), false)
            XCTAssertEqual(answer["project_names"] as? [String], [name], "says what the C does not print")
        }

        // A change to the review, from a holder that is not the source.
        _ = try await host.write(other, "/v1/set/comment", body: body([
            "address": there, "kind": "plate", "text": "A holder's own plate."]))
        let editedOther = try await read(other, there)
        XCTAssertEqual(state(editedOther), "edited")
        let moved = try await host.publish(other, by: "agent", options: .init(
            takeLibrary: LibraryTake.none.with(entryReasons: [id: "the holder's plate says more"])))
        XCTAssertEqual(moved.library?.updated.map(\.version), [2])
        XCTAssertEqual(moved.library?.conflicts.count, 0)
        XCTAssertEqual(try store.libraryIndex().entries[id]?.version, 2)
        let theSource = try await read(source, at)
        XCTAssertEqual(theSource["text"] as? String, "registry")
        XCTAssertEqual(theSource["plate"] as? String, "A holder's own plate.", "the source reads the holder's review")
    }

    /// A publish that would move an entry with no reason stores nothing, from
    /// the source and from another holder; the dry run and `ghidra_done` say the
    /// same, and with a reason the row and the history name module and reason.
    func testAPublishThatMovesAnEntryWithNoReasonIsRefusedWhole() async throws {
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
        let source = SHA256Digest(data: images[0]), other = SHA256Digest(data: images[1])
        _ = try await host.create(module: images[0], name: "Reviewed")
        _ = try await host.create(module: images[1], name: "Other")
        defer { Task { await host.stop(source); await host.stop(other) } }
        let at = try await function(of: 43, in: source, host: host)
        let there = try await function(of: 43, in: other, host: host)
        _ = try await host.write(source, "/v1/set/signature", body: body([
            "address": at, "signature": "void * GetHobList(void)", "by": "agent", "reason": "EDK2 HobLib GetHobList"]))
        _ = try await host.write(source, "/v1/set/comment", body: body([
            "address": at, "kind": "plate", "text": "EDK2 HobLib GetHobList: the plate."]))
        _ = try await host.write(source, "/v1/set/comment", body: body([
            "address": at, "kind": "eol", "text": "the first step."]))
        var ordinal = 0
        let locals = try json(await host.readCall(source, "function/\(at)", query: [:]))["locals"] as? [[String: Any]]
        for local in locals ?? [] where (local["storage"] as? String)?.hasPrefix("HASH") != true {
            ordinal += 1
            var change: [String: Any] = ["function": at, "storage": local["storage"] ?? "", "name": "Named\(ordinal)",
                                         "type": "ushort", "by": "agent"]
            if let use = local["first_use"] { change["first_use"] = use }
            _ = try await host.write(source, "/v1/rename/variable", body: body(change))
        }
        _ = try await host.write(source, "/v1/tag/function", body: body(["address": at, "tag": "library.edk2"]))
        let first = try await host.publish(source, by: "agent")
        let added = try XCTUnwrap(first.library?.added.first { $0.name == "GetHobList" })
        XCTAssertEqual(added.module, source)
        let id = added.id
        _ = try await host.library(other, .init(action: .apply))
        _ = try await host.publish(other, by: "agent")

        var version = 1
        for (module, address, plate) in [(source, at, "The source's plate."), (other, there, "A holder's plate.")] {
            // On the entry's current version: a holder behind it gets a conflict, which is another rule.
            _ = try await host.library(module, .init(action: .apply))
            _ = try await host.write(module, "/v1/set/comment", body: body([
                "address": address, "kind": "plate", "text": plate]))
            let before = try store.analysis(module: module)?.artifact
            let revisions = try store.reviewHistory(module: module)?.revisions.count

            // The dry run names them and says the refusal.
            let dry = try json(await host.preview(module))
            let would = try XCTUnwrap(dry["library"] as? [String: Any])
            let rows = try XCTUnwrap(would["needs_reason"] as? [[String: Any]])
            XCTAssertEqual(rows.map { $0["id"] as? String }, [id])
            XCTAssertEqual(rows.first?["version"] as? Int, version + 1)
            XCTAssertEqual(rows.first?["module"] as? String, module.hex)
            let refusal = try XCTUnwrap(dry["library_refused"] as? String)
            XCTAssertTrue(refusal.contains(id), refusal)

            // The publish and the done are refused with those words, and store nothing.
            for attempt in ["publish", "done"] {
                do {
                    if attempt == "publish" { _ = try await host.publish(module, by: "agent") }
                    else { _ = try await host.release(module, by: "agent") }
                    XCTFail("\(attempt) took a change with no reason")
                } catch {
                    XCTAssertTrue("\(error)".contains(refusal), "\(attempt): \(error)")
                }
                XCTAssertEqual(try store.analysis(module: module)?.artifact, before, attempt)
                XCTAssertEqual(try store.reviewHistory(module: module)?.revisions.count, revisions, attempt)
                XCTAssertEqual(try store.libraryIndex().entries[id]?.version, version, attempt)
            }

            // A reason per entry: the row and the history name module and reason.
            let reason = "why: \(plate)"
            let take = LibraryTake.none.with(entryReasons: [id: reason])
            let allowed = try json(await host.preview(module, takeLibrary: take))
            XCTAssertNil(allowed["library_refused"])
            let published = try await host.publish(module, by: "agent", options: .init(takeLibrary: take))
            version += 1
            XCTAssertEqual(published.library?.updated.map(\.id), [id])
            XCTAssertEqual(published.library?.updated.first?.module, module)
            XCTAssertEqual(published.library?.updated.first?.reason, reason)
            let last = try XCTUnwrap(try store.libraryHistory(id: id)?.versions.last)
            XCTAssertEqual(last.version, version)
            XCTAssertEqual(last.source.module, module)
            XCTAssertEqual(last.reason, reason)
            XCTAssertNotEqual(try store.analysis(module: module)?.artifact, before)
            // Nothing left to say: the done goes through.
            _ = try await host.release(module, by: "agent")
            XCTAssertEqual(try store.libraryIndex().entries[id]?.version, version)
        }
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
        let stored = try XCTUnwrap(code.functions.first { $0.entry == CodeAddress(hex: copyGuid) })
        // The name's reason says where the name came from; why the signature
        // is what it is has a place of its own.
        XCTAssertEqual(stored.nameReason?.hasPrefix("named in its signature (was "), true, "\(stored.nameReason ?? "nil")")
        let live = try json(await host.read(reviewed, "/v1/function/\(copyGuid)"))
        XCTAssertEqual(live["signature_reason"] as? String, "EDK2 BaseLib CopyGuid", "\(live.keys.sorted())")
        XCTAssertEqual(stored.libraryEntry?.state, .entry, "the artifact says the function is the entry")
        XCTAssertEqual(stored.libraryEntry?.version, added.version)

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
        let improved = try await host.publish(other, by: "agent", options: .init(
            takeLibrary: LibraryTake.none.with(entryReasons: [added.id: "the holder's edit is better"])))
        XCTAssertEqual(improved.library?.updated.map(\.version), [added.version + 1], "\(String(describing: improved.library))")
        XCTAssertEqual(improved.library?.conflicts, [])
        let improvedCode = try store.artifact(for: improved.manifest)
        let improvedEntry = improvedCode.functions.first { $0.entry == CodeAddress(hex: theirs) }?.libraryEntry
        XCTAssertEqual(improvedEntry?.state, .entry, "exported again once the registry took the change")
        XCTAssertEqual(improvedEntry?.version, added.version + 1)

        // The first module is a version behind now: its review, offered again
        // after its own edit, is a conflict like any other module's.
        _ = try await host.write(reviewed, "/v1/set/comment", body: body([
            "address": copyGuid, "kind": "eol", "text": "the first dword"]))
        let behind = try await host.publish(reviewed, by: "agent")
        XCTAssertEqual(behind.library?.conflicts.map(\.base), [added.version], "\(String(describing: behind.library))")
        XCTAssertEqual(behind.library?.conflicts.first?.version, added.version + 1)
        let behindEntry = try store.artifact(for: behind.manifest).functions
            .first { $0.entry == CodeAddress(hex: copyGuid) }?.libraryEntry
        XCTAssertEqual(behindEntry?.state, .conflict)
        XCTAssertEqual(behindEntry?.base, added.version)
    }
}

/// A type the decompiler declines is refused and leaves the C as it was. Run
/// with `GHIDRA_TYPE_MODULE` naming a module image; skipped otherwise.
final class GhidraHostDeclinedTypeTests: XCTestCase {
    private func json(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// A real publish into a store keeping parted objects: the artifact comes
    /// back whole, and a second publish shares what did not change.
    func testAPublishIntoAPartedStoreReadsBack() async throws {
        guard let path = ProcessInfo.processInfo.environment["GHIDRA_TYPE_MODULE"] else {
            throw XCTSkip("GHIDRA_TYPE_MODULE is not set")
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GhidraHostPartedTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ContentStore(root: directory.appendingPathComponent("store"))
        let host = GhidraHost(configuration: .init(projectsRoot: directory.appendingPathComponent("projects"),
                                                   idle: 300, holder: "GhidraHostPartedTests"),
                              writer: store)
        let image = try Data(contentsOf: URL(fileURLWithPath: path))
        let module = SHA256Digest(data: image)
        _ = try await host.create(module: image, name: "Module")
        let first = try await host.publish(module, by: "test")
        let functions = try store.artifact(for: first.manifest).functions
        XCTAssertFalse(functions.isEmpty)
        let count = { (try? FileManager.default.contentsOfDirectory(atPath: store.objectsURL.path).count) ?? 0 }
        let files = count()
        XCTAssertGreaterThan(files, functions.count, "cut into its functions")
        let entry = String(format: "0x%llX", functions[0].entry.value)
        _ = try await host.write(module, "/v1/set/comment", body: try JSONSerialization.data(withJSONObject: [
            "address": entry, "kind": "plate", "text": "A change to one function."]))
        let second = try await host.publish(module, by: "test")
        await host.stop(module)
        XCTAssertNotEqual(second.manifest.artifact.sha256, first.manifest.artifact.sha256)
        XCTAssertEqual(try store.artifact(for: second.manifest).functions.count, functions.count)
        XCTAssertEqual(store.verify(), [])
        let added = count() - files
        print("PARTED PUBLISH functions \(functions.count) files \(files) added by the second publish \(added)")
        XCTAssertLessThan(added, functions.count / 2 + 8, "a revision shares what it did not change")
    }

    func testANameSearchAlsoSaysWhatTheArchivesHold() async throws {
        guard let path = ProcessInfo.processInfo.environment["GHIDRA_TYPE_MODULE"] else {
            throw XCTSkip("GHIDRA_TYPE_MODULE is not set")
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GhidraHostDeclinedTypeTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ContentStore(root: directory.appendingPathComponent("store"))
        let host = GhidraHost(configuration: .init(projectsRoot: directory.appendingPathComponent("projects"),
                                                   idle: 300, holder: "GhidraHostDeclinedTypeTests"),
                              writer: store)
        let image = try Data(contentsOf: URL(fileURLWithPath: path))
        let module = SHA256Digest(data: image)
        _ = try await host.create(module: image, name: "Module")
        let answer = try json(await host.read(module, "/v1/types?contains=HOB_HANDOFF"))
        await host.stop(module)
        let names = (answer["in_archives"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
        XCTAssertTrue(names.contains("EFI_HOB_HANDOFF_INFO_TABLE"), "\(answer)")
    }

    func testAPathNamesOneOfATypeHeldTwice() async throws {
        guard let path = ProcessInfo.processInfo.environment["GHIDRA_TYPE_MODULE"] else {
            throw XCTSkip("GHIDRA_TYPE_MODULE is not set")
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GhidraHostTypePathTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ContentStore(root: directory.appendingPathComponent("store"))
        let host = GhidraHost(configuration: .init(projectsRoot: directory.appendingPathComponent("projects"),
                                                   idle: 300, holder: "GhidraHostTypePathTests"),
                              writer: store)
        let image = try Data(contentsOf: URL(fileURLWithPath: path))
        let module = SHA256Digest(data: image)
        _ = try await host.create(module: image, name: "Module")
        defer { Task { await host.stop(module) } }
        let functions = try json(await host.read(module, "/v1/functions"))["functions"] as? [[String: Any]] ?? []
        var typed = false
        outer: for function in functions.prefix(40) {
            let entry = try XCTUnwrap(function["entry"] as? String)
            let shown = try json(await host.read(module, "/v1/function/\(entry)"))
            for local in shown["locals"] as? [[String: Any]] ?? [] {
                guard let storage = local["storage"] as? String, storage.hasSuffix(":4") else { continue }
                var request: [String: Any] = ["function": entry, "storage": storage,
                                              "type": "/UefiSpec.h/EFI_EXIT_BOOT_SERVICES"]
                if let first = local["first_use"] as? String { request["first_use"] = first }
                let body = try JSONSerialization.data(withJSONObject: request)
                guard (try? await host.write(module, "/v1/rename/variable", body: body)) != nil else { continue }
                let after = try json(await host.read(module, "/v1/function/\(entry)"))
                typed = "\(after)".contains("EFI_EXIT_BOOT_SERVICES")
                break outer
            }
        }
        XCTAssertTrue(typed)
    }

    func testATakeLeavesNoConflictCopyInTheSharedArchive() async throws {
        guard let path = ProcessInfo.processInfo.environment["GHIDRA_TYPE_MODULE"] else {
            throw XCTSkip("GHIDRA_TYPE_MODULE is not set")
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GhidraHostTakeTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ContentStore(root: directory.appendingPathComponent("store"))
        let host = GhidraHost(configuration: .init(projectsRoot: directory.appendingPathComponent("projects"),
                                                   idle: 300, holder: "GhidraHostTakeTests"),
                              writer: store)
        let image = try Data(contentsOf: URL(fileURLWithPath: path))
        let module = SHA256Digest(data: image)
        _ = try await host.create(module: image, name: "Module")
        defer { Task { await host.stop(module) } }
        func define(_ c: String) async throws {
            _ = try await host.write(module, "/v1/type", body: try JSONSerialization.data(withJSONObject: ["c": c]))
        }
        try await define("typedef struct _TAKE_ITEM { int A; } TAKE_ITEM;")
        try await define("typedef struct _TAKE_HOLDER { TAKE_ITEM *Item; } TAKE_HOLDER;")
        _ = try await host.publish(module, by: nil)
        try await define("typedef struct _TAKE_ITEM { int A; int B; } TAKE_ITEM;")
        try await define("typedef struct _TAKE_HOLDER { TAKE_ITEM *Item; int Extra; } TAKE_HOLDER;")
        let taken = try await host.publish(module, by: nil, options: .init(takeTypeConflicts: true))
        XCTAssertFalse(taken.typeConflictsTaken.isEmpty)
        let shown = try await host.read(module, "/v1/type?name=TAKE_HOLDER")
        let text = String(decoding: shown, as: UTF8.self)
        XCTAssertFalse(text.contains(".conflict"), text)
        XCTAssertTrue(text.contains("TAKE_ITEM"), text)
    }

    func testACommentDeepInATypeIsNotAConflictOfWhatHoldsIt() async throws {
        guard let path = ProcessInfo.processInfo.environment["GHIDRA_TYPE_MODULE"] else {
            throw XCTSkip("GHIDRA_TYPE_MODULE is not set")
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GhidraHostDeepCommentTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ContentStore(root: directory.appendingPathComponent("store"))
        let host = GhidraHost(configuration: .init(projectsRoot: directory.appendingPathComponent("projects"),
                                                   idle: 300, holder: "GhidraHostDeepCommentTests"),
                              writer: store)
        let image = try Data(contentsOf: URL(fileURLWithPath: path))
        let module = SHA256Digest(data: image)
        _ = try await host.create(module: image, name: "Module")
        defer { Task { await host.stop(module) } }
        func define(_ object: [String: Any]) async throws {
            _ = try await host.write(module, "/v1/type", body: try JSONSerialization.data(withJSONObject: object))
        }
        try await define(["c": "typedef struct _TC_C { int Leaf; } TC_C;"])
        try await define(["c": "typedef struct _TC_B { TC_C *Inner; } TC_B;"])
        try await define(["c": "typedef struct _TC_A { TC_B *Middle; } TC_A;"])
        _ = try await host.publish(module, by: nil)
        try await define(["c": "typedef struct _TC_C { int Leaf; } TC_C;", "comments": ["Leaf": "Now explained."]])
        let published = try await host.publish(module, by: nil)
        XCTAssertEqual(published.typeConflicts, [])
        let shown = String(decoding: try await host.read(module, "/v1/type?name=TC_C"), as: UTF8.self)
        XCTAssertTrue(shown.contains("Now explained."), shown)
        // A layout that differs is still a conflict.
        try await define(["c": "typedef struct _TC_C { int Leaf; int More; } TC_C;"])
        let differing = try await host.publish(module, by: nil)
        XCTAssertTrue(differing.typeConflicts.contains("_TC_C"), "\(differing.typeConflicts)")
    }

    func testAnEquateNamesAValueAcrossFunctionsAndKeepsOtherNames() async throws {
        guard let path = ProcessInfo.processInfo.environment["GHIDRA_TYPE_MODULE"] else {
            throw XCTSkip("GHIDRA_TYPE_MODULE is not set")
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GhidraHostEquateTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ContentStore(root: directory.appendingPathComponent("store"))
        let host = GhidraHost(configuration: .init(projectsRoot: directory.appendingPathComponent("projects"),
                                                   idle: 300, holder: "GhidraHostEquateTests"),
                              writer: store)
        let image = try Data(contentsOf: URL(fileURLWithPath: path))
        let module = SHA256Digest(data: image)
        _ = try await host.create(module: image, name: "Module")
        defer { Task { await host.stop(module) } }
        func post(_ object: [String: Any]) async throws -> [String: Any] {
            try json(await host.write(module, "/v1/set/equate", body: try JSONSerialization.data(withJSONObject: object)))
        }
        let functions = try json(await host.read(module, "/v1/functions"))["functions"] as? [[String: Any]] ?? []
        // A value some function holds as an immediate, found by asking for one.
        var entry = "", value = ""
        search: for function in functions.prefix(60) {
            let at = try XCTUnwrap(function["entry"] as? String)
            let shown = try json(await host.read(module, "/v1/disassembly/\(at)"))
            for instruction in shown["instructions"] as? [[String: Any]] ?? [] {
                let text = instruction["text"] as? String ?? ""
                if text.hasPrefix("PUSH 0x") || (text.hasPrefix("MOV E") && text.contains(",0x")) {
                    let found = String(text[text.range(of: "0x")!.lowerBound...])
                    // A value this high is an address in the image: an equate names constants.
                    guard let number = UInt64(found.dropFirst(2), radix: 16), number < 0x10000 else { continue }
                    value = found
                    entry = at
                    break search
                }
            }
        }
        XCTAssertFalse(entry.isEmpty)
        let preview = try await post(["functions": [entry], "value": value, "name": "BATCH_NAME", "dry_run": true])
        let would = preview["applied"] as? [[String: Any]] ?? []
        XCTAssertNotNil(would.first?["text"] as? String, "\(preview)")
        let notYet = try await post(["functions": [entry], "value": value, "name": "BATCH_OTHER", "dry_run": true])
        XCTAssertEqual((notYet["skipped"] as? [Any])?.count, 0, "a preview names nothing: \(notYet)")
        let first = try await post(["functions": [entry], "value": value, "name": "BATCH_NAME"])
        let applied = first["applied"] as? [[String: Any]] ?? []
        XCTAssertEqual(applied.count, would.count)
        XCTAssertFalse(applied.isEmpty, "\(first)")
        // Named otherwise, one operand is left alone by the next call.
        let second = try await post(["functions": [entry], "value": value, "name": "BATCH_OTHER"])
        XCTAssertEqual((second["skipped"] as? [Any])?.count, applied.count, "\(second)")
        XCTAssertEqual((second["applied"] as? [Any])?.count, 0, "\(second)")
        // An enum's typedef stands for the enum.
        let address = try XCTUnwrap(applied.first?["address"] as? String)
        _ = try await post(["address": address, "value": value, "name": ""])
        _ = try await host.write(module, "/v1/type", body: try JSONSerialization.data(withJSONObject: [
            "c": "typedef enum _BATCH_KIND { BATCH_OTHER_KIND = 999999 } BATCH_KIND;"]))
        let typed = try await post(["address": address, "value": value, "name": "BATCH_TYPED", "enum": "BATCH_KIND"])
        XCTAssertEqual(typed["address"] as? String, address, "\(typed)")
    }

    func testAValueInADisplacementIsNotTakenForAnImmediate() async throws {
        guard let path = ProcessInfo.processInfo.environment["GHIDRA_TYPE_MODULE"] else {
            throw XCTSkip("GHIDRA_TYPE_MODULE is not set")
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GhidraHostDisplacementTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ContentStore(root: directory.appendingPathComponent("store"))
        let host = GhidraHost(configuration: .init(projectsRoot: directory.appendingPathComponent("projects"),
                                                   idle: 300, holder: "GhidraHostDisplacementTests"),
                              writer: store)
        let image = try Data(contentsOf: URL(fileURLWithPath: path))
        let module = SHA256Digest(data: image)
        _ = try await host.create(module: image, name: "Module")
        defer { Task { await host.stop(module) } }
        func post(_ object: [String: Any]) async throws -> [String: Any] {
            try json(await host.write(module, "/v1/set/equate", body: try JSONSerialization.data(withJSONObject: object)))
        }
        let functions = try json(await host.read(module, "/v1/functions"))["functions"] as? [[String: Any]] ?? []
        let displacement = try NSRegularExpression(pattern: "\\+ ?(0x[0-9a-fA-F]+)\\]")
        var found: (entry: String, address: String, value: String, text: String)?
        var both: (entry: String, address: String, value: String, text: String)?
        scan: for function in functions.prefix(200) {
            let entry = try XCTUnwrap(function["entry"] as? String)
            let shown = try json(await host.read(module, "/v1/disassembly/\(entry)"))
            for instruction in shown["instructions"] as? [[String: Any]] ?? [] {
                let text = instruction["text"] as? String ?? ""
                guard let address = instruction["address"] as? String,
                      let match = displacement.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                      let range = Range(match.range(at: 1), in: text) else { continue }
                let value = String(text[range])
                if text.hasSuffix("," + value) {
                    both = both ?? (entry, address, value, text)
                } else if found == nil, !text.contains(",0x") {
                    found = (entry, address, value, text)
                }
                if found != nil, both != nil { break scan }
            }
        }
        let only = try XCTUnwrap(found)
        do {
            _ = try await post(["address": only.address, "value": only.value, "name": "DISP_NAME"])
            XCTFail("named a displacement unasked: \(only.text)")
        } catch {
            XCTAssertTrue("\(error)".contains("memory operand"), "\(error)")
        }
        // Named on purpose by its operand, it is listed as sitting on memory; an immediate is not.
        let memoryOperand = only.text.prefix { $0 != "[" }.filter { $0 == "," }.count
        _ = try await post(["address": only.address, "operand": memoryOperand, "name": "DISP_NAME"])
        func listed() async throws -> [[String: Any]] {
            try json(await host.read(module, "/v1/equates-on-memory"))["equates"] as? [[String: Any]] ?? []
        }
        let memory = try await listed()
        XCTAssertEqual(memory.first?["address"] as? String, only.address, "\(only.text): \(memory)")
        XCTAssertEqual(memory.first?["name"] as? String, "DISP_NAME")
        _ = try await post(["address": only.address, "operand": memory.first?["operand"] as? Int ?? 0, "name": ""])
        let swept = try await post(["functions": [only.entry], "value": only.value, "name": "DISP_NAME", "dry_run": true])
        for item in swept["applied"] as? [[String: Any]] ?? [] {
            XCTAssertNotEqual(item["address"] as? String, only.address, "\(swept)")
        }
        if let both {
            let answer = try await post(["address": both.address, "value": both.value, "name": "IMM_NAME"])
            XCTAssertEqual(answer["operand"] as? Int, both.text.filter { $0 == "," }.count,
                           "the last operand is the immediate: \(both.text): \(answer)")
            let afterImmediate = try await listed()
            XCTAssertFalse(afterImmediate.contains { $0["name"] as? String == "IMM_NAME" }, "\(afterImmediate)")
        } else {
            print("no instruction here holds one value both ways: \(only.text)")
        }
    }

    func testAFirstUseThatIsGoneRenamesNothing() async throws {
        guard let path = ProcessInfo.processInfo.environment["GHIDRA_TYPE_MODULE"] else {
            throw XCTSkip("GHIDRA_TYPE_MODULE is not set")
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GhidraHostFirstUseTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ContentStore(root: directory.appendingPathComponent("store"))
        let host = GhidraHost(configuration: .init(projectsRoot: directory.appendingPathComponent("projects"),
                                                   idle: 300, holder: "GhidraHostFirstUseTests"),
                              writer: store)
        let image = try Data(contentsOf: URL(fileURLWithPath: path))
        let module = SHA256Digest(data: image)
        _ = try await host.create(module: image, name: "Module")
        defer { Task { await host.stop(module) } }
        func rename(_ object: [String: Any]) async throws -> [String: Any] {
            try json(await host.write(module, "/v1/rename/variable", body: try JSONSerialization.data(withJSONObject: object)))
        }
        let functions = try json(await host.read(module, "/v1/functions"))["functions"] as? [[String: Any]] ?? []
        var checkedLocal = false, checkedParameter = false
        for function in functions.prefix(80) where !(checkedLocal && checkedParameter) {
            let entry = try XCTUnwrap(function["entry"] as? String)
            let shown = try json(await host.read(module, "/v1/function/\(entry)"))
            // A local: named once so the table holds it, then asked for by a first use it never had.
            if !checkedLocal, let local = (shown["locals"] as? [[String: Any]] ?? []).first(where: {
                ($0["storage"] as? String)?.contains(":") == true && $0["first_use"] is String
                    && ($0["storage"] as? String)?.hasPrefix("Stack") == false && ($0["storage"] as? String)?.hasPrefix("HASH") == false
            }), let storage = local["storage"] as? String, let first = local["first_use"] as? String {
                guard (try? await rename(["function": entry, "storage": storage, "first_use": first,
                                          "name": "KeptLocal"])) != nil else { continue }
                do {
                    _ = try await rename(["function": entry, "storage": storage, "first_use": "0x1", "name": "WrongLocal"])
                    XCTFail("a first use that is gone renamed something")
                } catch {
                    XCTAssertTrue("\(error)".contains("KeptLocal"), "the refusal lists what is there: \(error)")
                }
                let after = "\(try json(await host.read(module, "/v1/function/\(entry)")))"
                XCTAssertTrue(after.contains("KeptLocal"), after)
                XCTAssertFalse(after.contains("WrongLocal"), after)
                checkedLocal = true
            }
            // A parameter is never reached through a local's first use.
            if !checkedParameter, let parameter = (shown["parameters"] as? [[String: Any]] ?? []).first,
               let storage = parameter["storage"] as? String, let name = parameter["name"] as? String {
                do {
                    _ = try await rename(["function": entry, "storage": storage, "first_use": "0x1", "name": "WrongParameter"])
                    XCTFail("a parameter was renamed through a first use")
                } catch {}
                let after = try json(await host.read(module, "/v1/function/\(entry)"))
                XCTAssertEqual((after["parameters"] as? [[String: Any]])?.first?["name"] as? String, name)
                checkedParameter = true
            }
        }
        XCTAssertTrue(checkedLocal)
        XCTAssertTrue(checkedParameter)
    }

    func testARenameTheDecompilerDropsIsNotAnsweredAsApplied() async throws {
        guard let path = ProcessInfo.processInfo.environment["GHIDRA_TYPE_MODULE"] else {
            throw XCTSkip("GHIDRA_TYPE_MODULE is not set")
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GhidraHostDroppedNameTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ContentStore(root: directory.appendingPathComponent("store"))
        let host = GhidraHost(configuration: .init(projectsRoot: directory.appendingPathComponent("projects"),
                                                   idle: 300, holder: "GhidraHostDroppedNameTests"),
                              writer: store)
        let image = try Data(contentsOf: URL(fileURLWithPath: path))
        let module = SHA256Digest(data: image)
        _ = try await host.create(module: image, name: "Module")
        defer { Task { await host.stop(module) } }
        let functions = try json(await host.read(module, "/v1/functions"))["functions"] as? [[String: Any]] ?? []
        var tried = 0
        for function in functions {
            let entry = try XCTUnwrap(function["entry"] as? String)
            let shown = try json(await host.read(module, "/v1/function/\(entry)"))
            for local in shown["locals"] as? [[String: Any]] ?? [] where (local["name"] as? String)?.hasPrefix("in_") == true {
                guard let storage = local["storage"] as? String else { continue }
                var request: [String: Any] = ["function": entry, "storage": storage, "name": "TriedName\(tried)"]
                if let first = local["first_use"] as? String { request["first_use"] = first }
                tried += 1
                let answer = try? await host.write(module, "/v1/rename/variable",
                                                   body: try JSONSerialization.data(withJSONObject: request))
                let after = "\(try json(await host.read(module, "/v1/function/\(entry)")))"
                print("in_ rename", local["name"] ?? "", storage, answer == nil ? "refused" : "applied",
                      after.contains("TriedName\(tried - 1)") ? "name shows" : "name absent")
                if answer != nil { XCTAssertTrue(after.contains("TriedName\(tried - 1)"), after) }
            }
            if tried >= 6 { break }
        }
        print("in_ locals tried:", tried)
    }

    func testALinkToARenamedFunctionIsReported() async throws {
        guard let path = ProcessInfo.processInfo.environment["GHIDRA_TYPE_MODULE"] else {
            throw XCTSkip("GHIDRA_TYPE_MODULE is not set")
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GhidraHostStaleLinkTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ContentStore(root: directory.appendingPathComponent("store"))
        let host = GhidraHost(configuration: .init(projectsRoot: directory.appendingPathComponent("projects"),
                                                   idle: 300, holder: "GhidraHostStaleLinkTests"),
                              writer: store)
        let image = try Data(contentsOf: URL(fileURLWithPath: path))
        let module = SHA256Digest(data: image)
        _ = try await host.create(module: image, name: "Module")
        defer { Task { await host.stop(module) } }
        func post(_ route: String, _ object: [String: Any]) async throws {
            _ = try await host.write(module, route, body: try JSONSerialization.data(withJSONObject: object))
        }
        func stale() async throws -> [[String: Any]] {
            try json(await host.read(module, "/v1/stale-links"))["stale_links"] as? [[String: Any]] ?? []
        }
        let functions = try json(await host.read(module, "/v1/functions"))["functions"] as? [[String: Any]] ?? []
        let target = try XCTUnwrap(functions.first { ($0["name"] as? String)?.hasPrefix("FUN_") == true })
        let host0 = try XCTUnwrap(functions.first { $0["entry"] as? String != target["entry"] as? String })
        let entry = try XCTUnwrap(target["entry"] as? String)
        let old = try XCTUnwrap(target["name"] as? String)
        try await post("/v1/set/comment", ["address": try XCTUnwrap(host0["entry"] as? String), "kind": "plate",
                                           "text": "Calls [\(old)](\(entry)) and [its helper](\(entry))."])
        let before = try await stale()
        XCTAssertTrue(before.isEmpty, "\(before)")
        try await post("/v1/rename/function", ["address": entry, "name": "RenamedTarget"])
        let after = try await stale()
        XCTAssertEqual(after.count, 1, "\(after)")
        XCTAssertEqual(after.first?["text"] as? String, old)
        XCTAssertEqual(after.first?["name"] as? String, "RenamedTarget")
        let published = try await host.publish(module, by: nil)
        XCTAssertEqual(published.staleLinks.first?.name, "RenamedTarget")
        // A datum: set_data echoes its name, and rename and label say to use set_data.
        let data = try json(await host.read(module, "/v1/data"))["data"] as? [[String: Any]] ?? []
        if let datum = data.first?["address"] as? String {
            let named = try json(await host.write(module, "/v1/set/data", body: try JSONSerialization.data(
                withJSONObject: ["address": datum, "name": "gNamedDatum"])))
            XCTAssertEqual(named["name"] as? String, "gNamedDatum", "\(named)")
            for route in ["/v1/rename/function", "/v1/rename/label"] {
                do {
                    _ = try await host.write(module, route, body: try JSONSerialization.data(
                        withJSONObject: ["address": datum, "name": "gOther"]))
                    XCTFail("\(route) named a datum")
                } catch {
                    XCTAssertTrue("\(error)".contains("ghidra_set_data"), "\(route): \(error)")
                }
            }
        } else {
            XCTFail("no data listed: \(data)")
        }
    }

    func testANameHeldTwiceIsSaidToBe() async throws {
        guard let path = ProcessInfo.processInfo.environment["GHIDRA_TYPE_MODULE"] else {
            throw XCTSkip("GHIDRA_TYPE_MODULE is not set")
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GhidraHostDeclinedTypeTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ContentStore(root: directory.appendingPathComponent("store"))
        let host = GhidraHost(configuration: .init(projectsRoot: directory.appendingPathComponent("projects"),
                                                   idle: 300, holder: "GhidraHostDeclinedTypeTests"),
                              writer: store)
        let image = try Data(contentsOf: URL(fileURLWithPath: path))
        let module = SHA256Digest(data: image)
        _ = try await host.create(module: image, name: "Module")
        defer { Task { await host.stop(module) } }
        func post(_ route: String, _ object: [String: Any]) async throws -> Data {
            try await host.write(module, route, body: try JSONSerialization.data(withJSONObject: object))
        }
        let functions = try json(await host.read(module, "/v1/functions"))["functions"] as? [[String: Any]] ?? []
        var refusal = ""
        // The archive's copy comes in with a first use, then a different one of the review's.
        outer: for function in functions.prefix(40) {
            let entry = try XCTUnwrap(function["entry"] as? String)
            let shown = try json(await host.read(module, "/v1/function/\(entry)"))
            for local in shown["locals"] as? [[String: Any]] ?? [] {
                guard let storage = local["storage"] as? String else { continue }
                var request: [String: Any] = ["function": entry, "storage": storage,
                                              "type": "EFI_HOB_HANDOFF_INFO_TABLE *"]
                if let first = local["first_use"] as? String { request["first_use"] = first }
                guard (try? await post("/v1/rename/variable", request)) != nil else { continue }
                _ = try await post("/v1/type", ["c": "typedef struct _EFI_HOB_HANDOFF_INFO_TABLE { int Other; } EFI_HOB_HANDOFF_INFO_TABLE;"])
                do {
                    _ = try await post("/v1/rename/variable", ["function": entry, "storage": storage,
                                                               "type": "EFI_HOB_HANDOFF_INFO_TABLE *"])
                } catch { refusal = "\(error)" }
                break outer
            }
        }
        XCTAssertTrue(refusal.contains("/PiHob.h/EFI_HOB_HANDOFF_INFO_TABLE"), refusal)
    }

    func testRemovingADescriptionSectionIsSaidInSoManyWords() async throws {
        guard let path = ProcessInfo.processInfo.environment["GHIDRA_TYPE_MODULE"] else {
            throw XCTSkip("GHIDRA_TYPE_MODULE is not set")
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GhidraHostDeclinedTypeTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ContentStore(root: directory.appendingPathComponent("store"))
        let host = GhidraHost(configuration: .init(projectsRoot: directory.appendingPathComponent("projects"),
                                                   idle: 300, holder: "GhidraHostDeclinedTypeTests"),
                              writer: store)
        let image = try Data(contentsOf: URL(fileURLWithPath: path))
        let module = SHA256Digest(data: image)
        _ = try await host.create(module: image, name: "Module")
        defer { Task { await host.stop(module) } }
        func post(_ object: [String: Any]) async throws -> [String: Any] {
            try json(await host.write(module, "/v1/set/description",
                                      body: try JSONSerialization.data(withJSONObject: object)))
        }
        func sections() async throws -> [String] {
            try json(await host.read(module, "/v1/description"))["sections"] as? [String] ?? []
        }
        _ = try await post(["text": "# M\n\n## Purpose\n\nA.\n\n## Flow\n\nB.\n"])
        for empty in [["section": "Flow", "text": ""], ["section": "Flow", "text": "  \n"], ["text": ""]] {
            do { _ = try await post(empty); XCTFail("\(empty)") } catch {}
        }
        do { _ = try await post(["section": "Nothing", "delete": true]); XCTFail("no such section") } catch {}
        do { _ = try await post(["section": "Flow", "delete": true, "text": "x"]); XCTFail("both") } catch {}
        let kept = try await sections()
        XCTAssertEqual(kept, ["Purpose", "Flow"])
        // One string inside a section.
        _ = try await post(["section": "Purpose", "text": "One two. Two."])
        _ = try await post(["section": "Purpose", "old_text": "One", "new_text": "Three"])
        let changed = try json(await host.read(module, "/v1/description?section=Purpose"))["text"] as? String
        XCTAssertEqual(changed?.trimmingCharacters(in: .whitespacesAndNewlines), "Three two. Two.")
        let flowKept = try json(await host.read(module, "/v1/description?section=Flow"))["text"] as? String
        XCTAssertEqual(flowKept?.trimmingCharacters(in: .whitespacesAndNewlines), "B.")
        do { _ = try await post(["section": "Purpose", "old_text": "wo", "new_text": "x"]); XCTFail("twice") } catch {}
        do { _ = try await post(["section": "Purpose", "old_text": "absent", "new_text": "x"]); XCTFail("absent") } catch {}
        do { _ = try await post(["section": "Purpose", "old_text": "One", "new_text": "x"]); XCTFail("already gone") } catch {}
        do { _ = try await post(["section": "Purpose", "old_text": "Three", "new_text": "x", "text": "y"]); XCTFail("with text") } catch {}
        do { _ = try await post(["old_text": "Three", "new_text": "x"]); XCTFail("no section") } catch {}
        _ = try await post(["section": "Purpose", "text": "A."])
        // Placed, moved and read alone.
        _ = try await post(["section": "Errors", "text": "E.", "before": "Flow"])
        let placed = try await sections()
        XCTAssertEqual(placed, ["Purpose", "Errors", "Flow"])
        _ = try await post(["section": "Purpose", "after": "Flow"])
        let moved = try await sections()
        XCTAssertEqual(moved, ["Errors", "Flow", "Purpose"])
        _ = try await post(["section": "Errors", "text": "E2.", "after": "Purpose"])
        let both = try await sections()
        XCTAssertEqual(both, ["Flow", "Purpose", "Errors"])
        let one = try json(await host.read(module, "/v1/description?section=Errors"))
        XCTAssertEqual(one["text"] as? String, "E2.\n")
        let outline = try json(await host.read(module, "/v1/description?outline=1"))
        XCTAssertNil(outline["text"])
        do { _ = try await post(["section": "New", "before": "Nowhere", "text": "x"]); XCTFail("no anchor") } catch {}
        do { _ = try await post(["section": "Absent", "before": "Flow"]); XCTFail("nothing to move") } catch {}
        do { _ = try await post(["section": "Flow", "before": "Flow"]); XCTFail("itself") } catch {}
        _ = try await post(["section": "Errors", "delete": true])
        let answer = try await post(["section": "Flow", "delete": true])
        XCTAssertEqual(answer["removed"] as? String, "Flow")
        let left = try await sections()
        XCTAssertEqual(left, ["Purpose"])
        let whole = try json(await host.read(module, "/v1/description"))["text"] as? String
        XCTAssertEqual(whole, "# M\n\n## Purpose\n\nA.\n")
    }

    /// A type over decoded code is refused until asked for, and asked for it
    /// shortens the body instead of failing or answering ok with no datum.
    func testADatumOverCodeIsRefusedThenShortensTheBody() async throws {
        guard let path = ProcessInfo.processInfo.environment["GHIDRA_TYPE_MODULE"] else {
            throw XCTSkip("GHIDRA_TYPE_MODULE is not set")
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GhidraHostDatumTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ContentStore(root: directory.appendingPathComponent("store"))
        let host = GhidraHost(configuration: .init(projectsRoot: directory.appendingPathComponent("projects"),
                                                   idle: 300, holder: "GhidraHostDatumTests"),
                              writer: store)
        let image = try Data(contentsOf: URL(fileURLWithPath: path))
        let module = SHA256Digest(data: image)
        _ = try await host.create(module: image, name: "Module")
        let functions = try json(await host.read(module, "/v1/functions"))["functions"] as? [[String: Any]] ?? []
        let function = try XCTUnwrap(functions.first { ($0["size"] as? Int ?? 0) >= 32 })
        let entry = try XCTUnwrap(function["entry"] as? String)
        let size = try XCTUnwrap(function["size"] as? Int)
        let value = try XCTUnwrap(UInt64(entry.dropFirst(2), radix: 16))
        let tail = "0x" + String(value + UInt64(size) - 4, radix: 16)

        do {
            _ = try await host.write(module, "/v1/set/data", body: try JSONSerialization.data(withJSONObject: ["address": entry, "type": "UINT32", "clear_code": true] as [String: Any]))
            XCTFail("a function's entry cannot become data")
        } catch {}
        do {
            _ = try await host.write(module, "/v1/set/data", body: try JSONSerialization.data(withJSONObject: ["address": tail, "type": "UINT32"] as [String: Any]))
            XCTFail("code under a type is refused unless asked")
        } catch {
            XCTAssertTrue("\(error)".contains("clear_code"), "\(error)")
        }
        let answer = try json(await host.write(module, "/v1/set/data", body: try JSONSerialization.data(withJSONObject: ["address": tail, "type": "UINT32", "clear_code": true] as [String: Any])))
        XCTAssertEqual(answer["type"] as? String, "UINT32")
        XCTAssertNotNil(answer["code_cleared"])

        // A merge is not refused for the overlap of the function it removes.
        let pair = functions.filter { ($0["size"] as? Int ?? 0) > 0 }.suffix(2).compactMap { $0["entry"] as? String }
        let merged = try json(await host.write(module, "/v1/merge/functions", body: try JSONSerialization.data(
            withJSONObject: ["into": pair[0], "from": pair[1]] as [String: Any])))
        XCTAssertEqual(merged["merged"] as? String, pair[1])

        // A body cannot grow over another function.
        do {
            _ = try await host.write(module, "/v1/function/extend", body: try JSONSerialization.data(
                withJSONObject: ["function": entry, "end": pair[1]] as [String: Any]))
            XCTFail("an extension over other functions is refused")
        } catch {
            XCTAssertTrue("\(error)".contains("holds part"), "\(error)")
        }
    }

    func testATypeNotTakenIsRefusedAndLeavesNothing() async throws {
        guard let path = ProcessInfo.processInfo.environment["GHIDRA_TYPE_MODULE"] else {
            throw XCTSkip("GHIDRA_TYPE_MODULE is not set")
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GhidraHostDeclinedTypeTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ContentStore(root: directory.appendingPathComponent("store"))
        let host = GhidraHost(configuration: .init(projectsRoot: directory.appendingPathComponent("projects"),
                                                   idle: 300, holder: "GhidraHostDeclinedTypeTests"),
                              writer: store)
        let image = try Data(contentsOf: URL(fileURLWithPath: path))
        let module = SHA256Digest(data: image)
        _ = try await host.create(module: image, name: "Module")
        let functions = try json(await host.read(module, "/v1/functions"))["functions"] as? [[String: Any]] ?? []
        var refused = 0, taken = 0
        for function in functions.prefix(40) {
            let entry = try XCTUnwrap(function["entry"] as? String)
            let before = try json(await host.read(module, "/v1/function/\(entry)"))
            for local in (before["locals"] as? [[String: Any]] ?? []).prefix(6) {
                guard let storage = local["storage"] as? String else { continue }
                let shown = try json(await host.read(module, "/v1/function/\(entry)"))
                var request: [String: Any] = ["function": entry, "storage": storage, "type": "EFI_GUID"]
                if let first = local["first_use"] as? String { request["first_use"] = first }
                do {
                    _ = try await host.write(module, "/v1/rename/variable",
                                             body: try JSONSerialization.data(withJSONObject: request))
                    taken += 1
                    break
                } catch {
                    guard "\(error)".contains("did not take the type") else { continue }
                    refused += 1
                    let after = try json(await host.read(module, "/v1/function/\(entry)"))
                    XCTAssertEqual(after["c"] as? String, shown["c"] as? String, "\(entry) \(storage)")
                    XCTAssertFalse((after["c"] as? String ?? "").contains("Unable to use type"))
                }
            }
        }
        await host.stop(module)
        print("DECLINED refused=\(refused) taken=\(taken)")
        XCTAssertGreaterThan(refused + taken, 0)
    }
}
