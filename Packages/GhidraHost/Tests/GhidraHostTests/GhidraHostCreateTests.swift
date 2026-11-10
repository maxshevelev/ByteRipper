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

    /// A link a publish cannot make is on its answer, not lost: another function
    /// of the module holds the name the entry moved to.
    /// A function proposed for the registry, and the publish that takes it.
    private func moved(_ address: String, of module: SHA256Digest, host: GhidraHost,
                       kind: String = "edk2") async throws -> LibraryWriteResult {
        _ = try await host.library(module, .init(action: .candidate, candidates: [.init(address: address, kind: kind)]))
        let published = try await host.publish(module, by: "agent")
        return try XCTUnwrap(published.library)
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
        _ = try await host.createCached(module: images[0], name: "Reviewed")
        try await host.take(SHA256Digest(data: images[0]))
        _ = try await host.createCached(module: images[1], name: "Other")
        try await host.take(SHA256Digest(data: images[1]))
        defer { Task { await host.stop(reviewed); await host.stop(other) } }

        let copyGuid = try await function(of: 25, in: reviewed, host: host)
        _ = try await host.write(reviewed, "/v1/set/signature", body: body([
            "address": copyGuid, "signature": "EFI_GUID * CopyGuid(EFI_GUID * DestinationGuid, EFI_GUID * SourceGuid)",
            "storage": ["ECX:4", "EDX:4"], "by": "agent", "reason": "EDK2 BaseLib CopyGuid"]))
        _ = try await host.write(reviewed, "/v1/set/comment", body: body([
            "address": copyGuid, "kind": "plate", "text": "EDK2 BaseLib CopyGuid: the plate of the entry."]))
        _ = try await host.write(reviewed, "/v1/set/comment", body: body([
            "address": copyGuid, "kind": "eol", "text": "first dword of the GUID"]))
        let added = try await moved(copyGuid, of: reviewed, host: host).added.first { $0.name == "CopyGuid" }
        let id = try XCTUnwrap(added?.id)

        let theirs = try await function(of: 25, in: other, host: host)
        let at = try XCTUnwrap(CodeAddress(hex: theirs))
        _ = try await host.library(other, .init(action: .apply))
        _ = try await host.publish(other, by: "agent")
        let on = try json(await host.readCall(other, "function/\(theirs)", query: [:]))
        XCTAssertEqual(on["text"] as? String, "registry", "\(on.keys.sorted())")
        XCTAssertEqual(on["plate"] as? String, "EDK2 BaseLib CopyGuid: the plate of the entry.")
        let asRead = try await store.functionAsRead(module: other, entry: at)
        XCTAssertEqual(on["c"] as? String, asRead?.c, "the owner's answer is what the store reads")
        XCTAssertEqual(on["signature"] as? String, asRead?.signature)
        XCTAssertEqual((on["comments"] as? [[String: Any]])?.first?["text"] as? String, "first dword of the GUID")
        let rows = try json(await host.readCall(other, "functions", query: [:]))["functions"] as? [[String: Any]]
        XCTAssertEqual(rows?.first { $0["entry"] as? String == theirs }?["text"] as? String, "registry")

        // What the holder stores is its own facts and the link: no copy to differ.
        let manifest = try XCTUnwrap(try store.analysis(module: other))
        let raw = try JSONDecoder().decode(CodeArtifact.self, from: try store.object(manifest.artifact.sha256))
        let stored = try XCTUnwrap(raw.functions.first { $0.entry == at })
        XCTAssertEqual(stored.registryNumber, id)
        XCTAssertNil(stored.c)
        XCTAssertNil(stored.signature)
        XCTAssertEqual(asRead?.libraryEntry?.id, id)
        XCTAssertEqual((on["library_entry"] as? [String: Any])?["state"] as? String, "linked")

        // An edit is the review's own draft.
        _ = try await host.write(other, "/v1/set/comment", body: body([
            "address": theirs, "kind": "plate", "text": "An edit of this review."]))
        // Its text is a draft, not a copy: both readers say the same.
        let edited = try json(await host.readCall(other, "function/\(theirs)", query: [:]))
        XCTAssertNil(edited["text"])
        XCTAssertEqual(edited["plate"] as? String, "An edit of this review.")
        XCTAssertEqual((edited["library_entry"] as? [String: Any])?["state"] as? String, "edited")
        _ = try await host.write(other, "/v1/set/comment", body: body(["address": theirs, "kind": "plate",
            "text": ""]))

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

    /// Two modules holding one body: any write in a marked
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
        _ = try await host.createCached(module: images[0], name: "Reviewed")
        try await host.take(SHA256Digest(data: images[0]))
        _ = try await host.createCached(module: images[1], name: "Other")
        try await host.take(SHA256Digest(data: images[1]))
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
        let first = try await moved(at, of: source, host: host)
        let id = try XCTUnwrap(first.added.first { $0.name == "GetHobList" }?.id)
        _ = try await host.library(other, .init(action: .apply))
        _ = try await host.publish(other, by: "agent")

        for (module, address, name) in [(other, there, "OtherBase"), (source, at, "HobBase")] {
            // A holder holds no text of its own: it takes the entry's to write on.
            if module == other { _ = try await host.library(other, .init(action: .apply, address: there, takeText: true)) }
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
            XCTAssertEqual(state(answer), "linked")
            XCTAssertEqual((answer["c"] as? String)?.contains(name), false)
            XCTAssertNil(answer["project_names"], "a name on a temporary is not kept")
            // The project keeps what it wrote: a publish is no cleaning of it.
            let raw = try json(await host.read(module, "/v1/function/\(address)"))
            XCTAssertEqual(raw["plate"] as? String, "EDK2 HobLib GetHobList: the plate.")
            XCTAssertEqual((raw["c"] as? String)?.contains(name), true, "the temporary's name stays in the project")
            XCTAssertNotNil(raw["signature"], "what its callers read stays")
        }

        // An addition to the review, from a holder that is not the source.
        let places = (try json(await host.read(other, "/v1/disassembly/\(there)?limit=4"))["instructions"] as? [[String: Any]] ?? [])
            .compactMap { $0["address"] as? String }
        _ = try await host.write(other, "/v1/set/comment", body: body([
            "address": try XCTUnwrap(places.last), "kind": "pre", "text": "A holder's remark."]))
        let editedOther = try await read(other, there)
        XCTAssertEqual(state(editedOther), "edited")
        let moved = try await host.publish(other, by: "agent", options: .init(
            takeLibrary: LibraryTake.none.with(entryReasons: [id: "the holder's remark says more"])))
        XCTAssertEqual(moved.library?.updated.map(\.version), [2])
        XCTAssertEqual(moved.library?.conflicts.count, 0)
        XCTAssertEqual(try store.libraryIndex().entries[id]?.version, 2)
        let theSource = try await read(source, at)
        XCTAssertEqual(theSource["text"] as? String, "registry")
        XCTAssertTrue((theSource["comments"] as? [[String: Any]] ?? []).contains { $0["text"] as? String == "A holder's remark." },
                      "the source reads the holder's addition")
    }

    /// A registry entry the code proves wrong is replaced by agents' votes:
    /// the module's holder proposes its review of the function, two other
    /// agents agree, and the module's next publish makes it the entry's next
    /// version, the proposal's reason in the history — not while the review
    /// differs from what was voted on. The module that wrote the entry is told
    /// on its ticket.
    func testAnAgreedProposalReplacesARegistryEntryAtTheNextPublish() async throws {
        guard let paths = ProcessInfo.processInfo.environment["GHIDRA_LIBRARY_MODULES"]?.split(separator: ":"),
              paths.count == 2 else {
            throw XCTSkip("GHIDRA_LIBRARY_MODULES is not set")
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GhidraHostLibraryTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ContentStore(root: directory.appendingPathComponent("store"))
        let holder = "GhidraHostLibraryTests"
        let host = GhidraHost(configuration: .init(projectsRoot: directory.appendingPathComponent("projects"),
                                                   idle: 300, holder: holder,
                                                   ticketsFile: directory.appendingPathComponent("private/tickets.json")),
                              writer: store)
        let images = try paths.map { try Data(contentsOf: URL(fileURLWithPath: String($0))) }
        let source = SHA256Digest(data: images[0]), other = SHA256Digest(data: images[1])
        _ = try await host.createCached(module: images[0], name: "Reviewed")
        try await host.take(source)
        _ = try await host.createCached(module: images[1], name: "Other")
        try await host.take(other)
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
        let first = try await moved(at, of: source, host: host)
        let id = try XCTUnwrap(first.added.first { $0.name == "GetHobList" }).id
        _ = try await host.library(other, .init(action: .apply))
        _ = try await host.publish(other, by: "agent")
        _ = try await host.library(other, .init(action: .apply, address: there, takeText: true))

        // The other module's review says something else of it.
        let proposed = "GetHobList: the HOB list pointer the PEI services hold, read through the IDT."
        _ = try await host.write(other, "/v1/set/comment", body: body([
            "address": there, "kind": "plate", "text": proposed]))
        func call(_ request: TypeProposalBook.Request) async throws -> [String: Any] {
            try json(await host.typeProposalCall(request, holder: holder))
        }
        let proposal = try await call(.init(action: .propose, agent: "Reviewer", module: other.hex,
                                            reason: "the plate the entry holds names the wrong source"))
        let proposalID = try XCTUnwrap(proposal["id"] as? String, "\(proposal)")
        let entry = try XCTUnwrap((proposal["entries"] as? [String: Any])?[id] as? [String: Any], "\(proposal)")
        XCTAssertEqual(entry["held_by"] as? String, source.hex)
        let fields = entry["fields"] as? [[String: Any]] ?? []
        XCTAssertTrue(fields.contains { ($0["offered"] as? String ?? "").contains(proposed)
            && ($0["held"] as? String ?? "").contains("the plate.") }, "\(fields)")
        XCTAssertEqual(proposal["names"] as? [String], [], "no type")
        _ = try await call(.init(action: .vote, agent: "Verifier", id: proposalID, choice: .agree))
        let agreed = try await call(.init(action: .vote, agent: "Analyzis", id: proposalID, choice: .agree))
        XCTAssertEqual(agreed["state"] as? String, "agreed")

        // The dry run decides as the publish does: the agreed proposal, not a refusal.
        let preview = try json(await host.preview(other))
        XCTAssertEqual(preview["library_agreed"] as? [String], [proposalID], "\(preview)")
        XCTAssertNil(preview["library_refused"], "\(preview)")

        // Not what was voted on: refused as before.
        let version = try store.libraryIndex().entries[id]?.version
        _ = try await host.write(other, "/v1/set/comment", body: body([
            "address": there, "kind": "plate", "text": proposed + " Changed after the vote."]))
        do {
            _ = try await host.publish(other, by: "agent")
            XCTFail("a review other than the agreed one replaced the entry")
        } catch let error as GhidraHostError {
            XCTAssertEqual(error.status, 409, "\(error)")
        }
        XCTAssertEqual(try store.libraryIndex().entries[id]?.version, version)

        _ = try await host.write(other, "/v1/set/comment", body: body([
            "address": there, "kind": "plate", "text": proposed]))
        let published = try await host.publish(other, by: "agent")
        XCTAssertEqual(published.library?.updated.map(\.id), [id], "\(String(describing: published.library))")
        let last = try XCTUnwrap(try store.libraryHistory(id: id)?.versions.last)
        XCTAssertEqual(last.source.module, other)
        XCTAssertTrue((last.reason ?? "").contains(proposalID) && (last.reason ?? "").contains("names the wrong source"),
                      last.reason ?? "no reason")
        let held = try store.libraryIndex().entries[id]
        let text = String(decoding: try store.object(try XCTUnwrap(held?.entry)), as: UTF8.self)
        XCTAssertTrue(text.contains("PEI services hold"), text)
        let applied = try await call(.init(action: .read, id: proposalID))
        XCTAssertEqual(applied["state"] as? String, "applied")

        var remark: TicketBook.Remark?
        for _ in 0..<60 {
            remark = await host.tickets?.ticket(source.hex)?.remarks.first
            if remark != nil { break }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        let told = try XCTUnwrap(remark, "the entry's writer has no remark")
        XCTAssertTrue(told.text.contains(id) && told.text.contains(proposalID), told.text)
    }

    /// What the registry says is replaced by nobody here. Replacing it refuses the
    /// whole publish, from the entry's source and from a holder, in the dry run
    /// and in a done: nothing is stored and the function stays dirty. Over the
    /// entry's text, taken explicitly, an addition passes as the next version,
    /// takes `dirty` off, and leaves what the project wrote where it is.
    func testAReplacementIsRefusedWholeAndAnAdditionOverTheEntrysTextPasses() async throws {
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
        _ = try await host.createCached(module: images[0], name: "Reviewed")
        try await host.take(SHA256Digest(data: images[0]))
        _ = try await host.createCached(module: images[1], name: "Other")
        try await host.take(SHA256Digest(data: images[1]))
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
        let first = try await moved(at, of: source, host: host)
        let added = try XCTUnwrap(first.added.first { $0.name == "GetHobList" })
        XCTAssertEqual(added.module, source)
        let id = added.id
        _ = try await host.library(other, .init(action: .apply))
        _ = try await host.publish(other, by: "agent")

        func state(_ module: SHA256Digest, _ address: String) async throws -> String? {
            let answer = try json(await host.readCall(module, "function/\(address)", query: [:]))
            return (answer["library_entry"] as? [String: Any])?["state"] as? String
        }
        // The holder holds no text: a write on nothing is short of the bar, and
        // the refusal says what to do.
        _ = try await host.write(other, "/v1/set/comment", body: body([
            "address": there, "kind": "eol", "text": "written on nothing."]))
        let bare = try json(await host.preview(other))
        XCTAssertTrue((bare["library_refused"] as? String)?.contains("take_text") == true, "\(bare)")
        _ = try await host.library(other, .init(action: .apply, address: there, takeText: true))
        let bound = try await state(other, there)
        XCTAssertEqual(bound, "linked")
        let taken = try json(await host.read(other, "/v1/function/\(there)"))
        XCTAssertEqual(taken["plate"] as? String, "EDK2 HobLib GetHobList: the plate.", "the entry's text is in the project")

        var version = 1
        for (module, address) in [(source, at), (other, there)] {
            // A change of what the entry says.
            _ = try await host.write(module, "/v1/set/comment", body: body([
                "address": address, "kind": "plate", "text": "Another plate."]))
            let before = try store.analysis(module: module)?.artifact
            let revisions = try store.reviewHistory(module: module)?.revisions.count
            let dry = try json(await host.preview(module))
            let rows = try XCTUnwrap((dry["library"] as? [String: Any])?["conflicts"] as? [[String: Any]])
            XCTAssertEqual(rows.map { $0["id"] as? String }, [id])
            XCTAssertEqual((rows.first?["held_by"] as? [String: Any])?["module"] as? String, source.hex)
            let refusal = try XCTUnwrap(dry["library_refused"] as? String)
            XCTAssertTrue(refusal.contains(id) && refusal.contains(source.hex) && refusal.contains("take_text"), refusal)
            for attempt in ["publish", "done"] {
                do {
                    if attempt == "publish" { _ = try await host.publish(module, by: "agent") }
                    else { _ = try await host.release(module, by: "agent") }
                    XCTFail("\(attempt) took a replacement")
                } catch {
                    XCTAssertTrue("\(error)".contains(refusal), "\(attempt): \(error)")
                }
                XCTAssertEqual(try store.analysis(module: module)?.artifact, before, attempt)
                XCTAssertEqual(try store.reviewHistory(module: module)?.revisions.count, revisions, attempt)
                XCTAssertEqual(try store.libraryIndex().entries[id]?.version, version, attempt)
                let still = try await state(module, address)
                XCTAssertEqual(still, "edited", "it stays dirty")
            }

            // The entry's text taken back, and an addition over it.
            _ = try await host.library(module, .init(action: .apply, address: address, takeText: true))
            let clean = try await state(module, address)
            XCTAssertEqual(clean, "linked")
            let listing = try json(await host.read(module, "/v1/disassembly/\(address)?limit=4"))
            let places = (listing["instructions"] as? [[String: Any]] ?? []).compactMap { $0["address"] as? String }
            // Each module adds at its own place: the same place would replace the other's words.
            let place = places[places.count - (module == source ? 1 : 2)]
            let remark = "an addition from \(module == source ? "the source" : "a holder")."
            _ = try await host.write(module, "/v1/set/comment", body: body([
                "address": place, "kind": "pre", "text": remark]))
            let dirty = try await state(module, address)
            XCTAssertEqual(dirty, "edited")
            let published = try await host.publish(module, by: "agent")
            version += 1
            XCTAssertEqual(published.library?.updated.map(\.id), [id])
            XCTAssertEqual(published.library?.updated.first?.module, module)
            XCTAssertEqual(published.library?.updated.first?.version, version)
            XCTAssertEqual(published.library?.updated.first?.reason?.hasPrefix("added by this module"), true)
            XCTAssertEqual(try store.libraryHistory(id: id)?.versions.last?.source.module, module)
            let closed = try await state(module, address)
            XCTAssertEqual(closed, "linked", "a success takes dirty off")
            // The project still holds what was written on it.
            let raw = try json(await host.read(module, "/v1/function/\(address)"))
            XCTAssertEqual(raw["plate"] as? String, "EDK2 HobLib GetHobList: the plate.")
            XCTAssertTrue((raw["comments"] as? [[String: Any]] ?? []).contains { $0["text"] as? String == remark })
            // Nothing left to say: the done goes through.
            _ = try await host.release(module, by: "agent")
            XCTAssertEqual(try store.libraryIndex().entries[id]?.version, version)
            // The next addition stands on what the other module added.
            if module == source {
                _ = try await host.library(other, .init(action: .apply, address: there, takeText: true))
            }
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
        _ = try await host.createCached(module: images[0], name: "Reviewed")
        try await host.take(SHA256Digest(data: images[0]))
        _ = try await host.createCached(module: images[1], name: "Other")
        try await host.take(SHA256Digest(data: images[1]))
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
        let published = try await moved(copyGuid, of: reviewed, host: host)
        let added = try XCTUnwrap(published.added.first { $0.name == "CopyGuid" })
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
        // Why the signature is what it is has a place of its own; the name's
        // reason, read through the registry, says it is the entry's.
        XCTAssertEqual(stored.nameReason?.hasPrefix("library registry entry"), true, "\(stored.nameReason ?? "nil")")
        let live = try json(await host.read(reviewed, "/v1/function/\(copyGuid)"))
        XCTAssertNotNil(live["signature_reason"], "the project keeps what the review wrote")
        XCTAssertEqual(stored.registryNumber, added.id, "the artifact holds the link, not the text")
        XCTAssertEqual(stored.libraryEntry?.version, added.version)

        // The other module named the same body its own way.
        let theirs = try await function(of: 25, in: other, host: host)
        _ = try await host.write(other, "/v1/rename/function", body: body([
            "address": theirs, "name": "GuidCopy", "by": "agent"]))
        let status = try json(await host.library(other, .init(action: .status)))
        let steps = status["to_apply"] as? [[String: Any]] ?? []
        XCTAssertEqual(steps.first { $0["address"] as? String == theirs }?["mode"] as? String, "link",
                       "a name is all it holds: nothing a link would lose")

        let applied = try json(await host.library(other, .init(action: .apply)))
        let result = try XCTUnwrap((applied["results"] as? [[String: Any]])?.first { $0["address"] as? String == theirs })
        XCTAssertEqual(result["ok"] as? Bool, true, "\(result)")
        XCTAssertEqual((result["renamed"] as? [String: Any])?["from"] as? String, "GuidCopy")
        XCTAssertEqual(result["marked"] as? Bool, true, "\(result)")
        let read = try json(await host.read(other, "/v1/function/\(theirs)?summary=1"))
        XCTAssertEqual(read["signature"] as? String,
                       "EFI_GUID * CopyGuid(EFI_GUID * DestinationGuid, EFI_GUID * SourceGuid)")
        XCTAssertEqual((read["parameters"] as? [[String: Any]])?.map { $0["storage"] as? String }, ["ECX:4", "EDX:4"])

        // Linked, then published: nothing to say to the registry, and no version moved.
        let again = try await host.publish(other, by: "agent")
        XCTAssertNil(again.libraryError)
        XCTAssertEqual(again.library?.conflicts ?? [], [])
        XCTAssertEqual(try store.libraryIndex().entries[added.id]?.version, added.version)
        let after = try json(await host.library(other, .init(action: .status)))
        XCTAssertEqual((after["applied"] as? [[String: Any]])?.compactMap { $0["address"] as? String }, [theirs])

        // Written on since: dirty, and not applied over.
        _ = try await host.library(other, .init(action: .apply, address: theirs, takeText: true))
        let lines = (try json(await host.read(other, "/v1/disassembly/\(theirs)?limit=4"))["instructions"] as? [[String: Any]] ?? [])
            .compactMap { $0["address"] as? String }
        _ = try await host.write(other, "/v1/set/comment", body: body([
            "address": lines[2], "kind": "pre", "text": "A step the holder adds."]))
        let edited = try json(await host.library(other, .init(action: .status)))
        XCTAssertEqual((edited["edited"] as? [[String: Any]])?.compactMap { $0["address"] as? String }, [theirs])
        XCTAssertEqual((edited["to_apply"] as? [Any])?.count, 0)

        // It only adds: published, it is the next version, from a module that did
        // not write the first.
        let improved = try await host.publish(other, by: "agent", options: .init(
            takeLibrary: LibraryTake.none.with(entryReasons: [added.id: "the holder's step says more"])))
        XCTAssertEqual(improved.library?.updated.map(\.version), [added.version + 1], "\(String(describing: improved.library))")
        XCTAssertEqual(improved.library?.conflicts, [])
        let improvedCode = try store.artifact(for: improved.manifest)
        let improvedEntry = improvedCode.functions.first { $0.entry == CodeAddress(hex: theirs) }?.libraryEntry
        XCTAssertEqual(improvedEntry?.version, added.version + 1)

        // The first module's project does not hold that step, and nothing puts it
        // there. A write on what it holds would drop the step: it is refused, naming
        // the holder, and nothing goes in.
        _ = try await host.write(reviewed, "/v1/set/comment", body: body([
            "address": copyGuid, "kind": "pre", "text": "Written on the version before."]))
        let behind = try json(await host.publishPreview(reviewed))
        let conflicts = (behind["library"] as? [String: Any])?["conflicts"] as? [[String: Any]] ?? []
        XCTAssertEqual(conflicts.first?["base"] as? Int, added.version, "\(behind)")
        XCTAssertEqual(conflicts.first?["version"] as? Int, added.version + 1, "\(behind)")
        XCTAssertTrue((behind["library_refused"] as? String)?.contains(other.hex) == true, "\(behind)")
        do {
            _ = try await host.publish(reviewed, by: "agent")
            XCTFail("a publish that replaces what the entry says is refused")
        } catch {
            XCTAssertTrue("\(error)".contains("Nothing was stored"), "\(error)")
        }
        XCTAssertEqual(try store.libraryIndex().entries[added.id]?.version, added.version + 1)

        // Over the entry's text the same addition goes in, and both modules' words stand.
        _ = try await host.library(reviewed, .init(action: .apply, address: copyGuid, takeText: true))
        _ = try await host.write(reviewed, "/v1/set/comment", body: body([
            "address": copyGuid, "kind": "pre", "text": "Written on the current version."]))
        let onTop = try await host.publish(reviewed, by: "agent")
        XCTAssertEqual(onTop.library?.updated.map(\.version), [added.version + 2], "\(String(describing: onTop.library))")
        let current = try XCTUnwrap(store.libraryIndex().entries[added.id])
        let text = try JSONSerialization.jsonObject(with: try store.object(current.entry)) as? [String: Any]
        let said = (text?["comments"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }
        XCTAssertTrue(said.contains("A step the holder adds.") && said.contains("Written on the current version."), "\(said)")
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
        _ = try await host.createCached(module: image, name: "Module")
        try await host.take(SHA256Digest(data: image))
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
        _ = try await host.createCached(module: image, name: "Module")
        try await host.take(SHA256Digest(data: image))
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
        _ = try await host.createCached(module: image, name: "Module")
        try await host.take(SHA256Digest(data: image))
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
        _ = try await host.createCached(module: image, name: "Module")
        try await host.take(SHA256Digest(data: image))
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
        _ = try await host.createCached(module: image, name: "Module")
        try await host.take(SHA256Digest(data: image))
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
        // A layout that differs is still a conflict, and refuses the publish.
        try await define(["c": "typedef struct _TC_C { int Leaf; int More; } TC_C;"])
        do {
            _ = try await host.publish(module, by: nil)
            XCTFail("a type the archive holds differently refuses the publish")
        } catch let error as GhidraHostError {
            XCTAssertEqual(error.status, 409)
            XCTAssertTrue("\(error)".contains("_TC_C"), "\(error)")
        }
    }

    /// The shared types come in versions the store keeps: a new type is the
    /// first, a field named where the archive said `Unknown…` is an amendment
    /// and the next, a layout that differs refuses the publish and leaves the
    /// store as it was, an administrator's take and a withdrawal are versions
    /// too, and the copy beside the projects is always the current one.
    /// A publish of a module whose types the archive already holds as they
    /// are makes no version — the first round of a test archive, and the
    /// shared archive as 468 left it (`GHIDRA_TYPE_ARCHIVE`, a folder with
    /// `review-types-Ia32.gdt` and its sidecars). There `IDS_HOOK_FUNCTION`
    /// is a function, and AmdSocFp6RnPei's typedef of the same name — what the
    /// C parser makes of `typedef UINT32 NAME(…)` — went in as
    /// `IDS_HOOK_FUNCTION.conflict`, so every publish of the unchanged module
    /// amended `IDS_HOOK_ENTRY` again: a new version each time.
    func testAnUnchangedModulePublishedAgainMakesNoTypeVersion() async throws {
        guard let path = ProcessInfo.processInfo.environment["GHIDRA_TYPE_MODULE"] else {
            throw XCTSkip("GHIDRA_TYPE_MODULE is not set")
        }
        let seeds: [URL?] = [nil] + (ProcessInfo.processInfo.environment["GHIDRA_TYPE_ARCHIVE"]
                                       .map { [URL(fileURLWithPath: $0)] } ?? [])
        for seed in seeds {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("GhidraHostTypeRepublishTests-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let projects = directory.appendingPathComponent("projects")
            if let seed {
                try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
                for name in try FileManager.default.contentsOfDirectory(atPath: seed.path) where name.hasPrefix("review-types-") {
                    try FileManager.default.copyItem(at: seed.appendingPathComponent(name),
                                                     to: projects.appendingPathComponent(name))
                }
            }
            let store = try ContentStore(root: directory.appendingPathComponent("store"))
            let host = GhidraHost(configuration: .init(projectsRoot: projects, idle: 300,
                                                       holder: "GhidraHostTypeRepublishTests"),
                                  writer: store)
            let image = try Data(contentsOf: URL(fileURLWithPath: path))
            let module = SHA256Digest(data: image)
            _ = try await host.createCached(module: image, name: "Module")
            try await host.take(SHA256Digest(data: image))
            let language = try json(await host.read(module, "/v1/hello"))["language"] as? String ?? ""
            let bits = GhidraHost.archiveBits(language: language)
            func versions() throws -> [Int] { try store.typeArchive(bits: bits)?.versions.map(\.version) ?? [] }
            let (function, entry) = seed == nil ? ("TV_HOOK", "TV_HOOK_ENTRY") : ("IDS_HOOK_FUNCTION", "IDS_HOOK_ENTRY")
            let label = seed == nil ? "a fresh archive" : "the 468 archive"

            _ = try await host.write(module, "/v1/type", body: try JSONSerialization.data(withJSONObject: [
                "c": "typedef UINT32 \(function)(UINT32 HookId, UINT32 Reserved0, UINT32 Reserved1);"
                    + " typedef struct _\(entry) { UINT32 HookId; \(function) *Hook; } \(entry);"]))
            _ = try await host.publish(module, by: "agent")
            let made = try versions()
            XCTAssertFalse(made.isEmpty, "\(label): the first publish keeps a version")
            for round in 1...2 {
                let again = try await host.publish(module, by: "agent")
                let kept = try store.typeArchive(bits: bits)?.versions.map { "v\($0.version) added \($0.added) amended \($0.amended)" } ?? []
                XCTAssertNil(again.typesVersion, "\(label), round \(round): \(kept)")
                XCTAssertEqual(try versions(), made, "\(label), round \(round): an unchanged module makes no version")
            }

            let shown = try json(await host.read(module, "/v1/type?name=\(entry)"))
            let shared = try XCTUnwrap(shown["shared"] as? [String: Any], "\(shown)")
            let hook = (shared["fields"] as? [[String: Any]])?.first { $0["name"] as? String == "Hook" }
            XCTAssertEqual(hook?["type"] as? String, "\(function) *", "\(label): the shared member is named, not a .conflict copy")
            XCTAssertEqual(shown["same"] as? Bool, true, "\(label): \(shown)")
            await host.stop(module)
        }
    }

    /// A placeholder over bytes nobody typed, cut into fields the code proves,
    /// is the same type read further: an amendment, as a placeholder named is.
    /// A structure that only points at it follows. A named field moved is
    /// still a replacement (CHIPSET_SERVICES_PPI in PlatformStage2Pei).
    func testAPlaceholderCutIntoFieldsAmendsTheSharedType() async throws {
        guard let path = ProcessInfo.processInfo.environment["GHIDRA_TYPE_MODULE"] else {
            throw XCTSkip("GHIDRA_TYPE_MODULE is not set")
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GhidraHostPlaceholderCutTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ContentStore(root: directory.appendingPathComponent("store"))
        let host = GhidraHost(configuration: .init(projectsRoot: directory.appendingPathComponent("projects"), idle: 300,
                                                   holder: "GhidraHostPlaceholderCutTests"),
                              writer: store)
        let image = try Data(contentsOf: URL(fileURLWithPath: path))
        let module = SHA256Digest(data: image)
        _ = try await host.createCached(module: image, name: "Module")
        try await host.take(module)
        defer { Task { await host.stop(module) } }
        let bits = GhidraHost.archiveBits(language: try json(await host.read(module, "/v1/hello"))["language"] as? String ?? "")
        func define(_ c: String) async throws {
            _ = try await host.write(module, "/v1/type", body: try JSONSerialization.data(withJSONObject: ["c": c]))
        }
        func versions() throws -> [TypeArchiveVersion] { try store.typeArchive(bits: bits)?.versions ?? [] }

        try await define("typedef struct _CUT_PPI { unsigned int Size; unsigned char Unknown04[24]; void *Function1C; unsigned char Unknown20[4]; } CUT_PPI;")
        try await define("typedef union _CUT_SLOT { CUT_PPI *Services; unsigned int Raw; } CUT_SLOT;")
        _ = try await host.publish(module, by: "agent")
        XCTAssertEqual(try versions().count, 1)

        try await define("typedef struct _CUT_PPI { unsigned int Size; unsigned char Unknown04[8]; void *Function0C; "
            + "unsigned char Unknown10[4]; void *Function14; void *Function18; void *Function1C; void *Function20; } CUT_PPI;")
        let cut = try await host.publish(module, by: "agent")
        XCTAssertEqual(cut.typeConflicts, [], "cut into fields, nothing named moved")
        let after = try versions()
        XCTAssertEqual(after.count, 2)
        XCTAssertTrue(!Set(after[1].amended).isDisjoint(with: ["CUT_PPI", "_CUT_PPI"]), "\(after[1])")

        // Function1C moved: a field the shared copy names is a replacement.
        try await define("typedef struct _CUT_PPI { unsigned int Size; unsigned char Unknown04[8]; void *Function0C; "
            + "unsigned char Unknown10[4]; void *Function14; void *Function18; void *Function20; void *Function1C; } CUT_PPI;")
        do {
            _ = try await host.publish(module, by: "agent")
            XCTFail("a named field moved is refused")
        } catch let error as GhidraHostError {
            XCTAssertEqual(error.status, 409)
            XCTAssertTrue("\(error)".contains("CUT_PPI"), "\(error)")
        }
        XCTAssertEqual(try versions().count, 2, "nothing written")

        // A cut from a module that never wrote the shared copy's comments
        // keeps them: an amendment only adds. The refused move first goes back.
        try await define("typedef struct _CUT_PPI { unsigned int Size; unsigned char Unknown04[8]; void *Function0C; "
            + "unsigned char Unknown10[4]; void *Function14; void *Function18; void *Function1C; void *Function20; } CUT_PPI;")
        try await define("typedef struct _SAID_PPI { unsigned int Size; unsigned char Unknown04[8]; void *Function0C; } SAID_PPI;")
        _ = try await host.write(module, "/v1/type", body: try JSONSerialization.data(withJSONObject: [
            "name": "SAID_PPI", "comments": ["Size": "bytes the installer filled", "Function0C": "called at boot"]]))
        _ = try await host.publish(module, by: "agent")
        for name in ["SAID_PPI", "_SAID_PPI"] {
            _ = try await host.write(module, "/v1/type", body: try JSONSerialization.data(withJSONObject: ["name": name, "delete": true]))
        }
        try await define("typedef struct _SAID_PPI { unsigned int Size; void *Function04; unsigned char Unknown08[4]; void *Function0C; } SAID_PPI;")
        let said = try await host.publish(module, by: "agent")
        XCTAssertEqual(said.typeConflicts, [])
        let shared = try json(await host.read(module, "/v1/type?name=SAID_PPI"))["shared"] as? [String: Any]
        let c = shared?["c"] as? String ?? ""
        XCTAssertTrue(c.contains("Function04"), c)
        XCTAssertTrue(c.contains("bytes the installer filled"), c)
        XCTAssertTrue(c.contains("called at boot"), c)
    }

    func testSharedTypesComeInVersionsAndAReplacementRefusesThePublish() async throws {
        guard let path = ProcessInfo.processInfo.environment["GHIDRA_TYPE_MODULE"] else {
            throw XCTSkip("GHIDRA_TYPE_MODULE is not set")
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GhidraHostTypeVersionTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ContentStore(root: directory.appendingPathComponent("store"))
        let projects = directory.appendingPathComponent("projects")
        let host = GhidraHost(configuration: .init(projectsRoot: projects, idle: 300,
                                                   holder: "GhidraHostTypeVersionTests"),
                              writer: store)
        let image = try Data(contentsOf: URL(fileURLWithPath: path))
        let module = SHA256Digest(data: image)
        _ = try await host.createCached(module: image, name: "Module")
        try await host.take(SHA256Digest(data: image))
        defer { Task { await host.stop(module) } }
        let language = try json(await host.read(module, "/v1/hello"))["language"] as? String ?? ""
        let bits = GhidraHost.archiveBits(language: language)
        func define(_ c: String) async throws {
            _ = try await host.write(module, "/v1/type", body: try JSONSerialization.data(withJSONObject: ["c": c]))
        }
        func versions() throws -> [TypeArchiveVersion] { try store.typeArchive(bits: bits)?.versions ?? [] }
        func copyIsCurrent() throws {
            let current = try XCTUnwrap(try versions().last)
            let kept = try Data(contentsOf: store.typeArchiveFolder(bits: bits, version: current.version)
                                    .appendingPathComponent("archive.gdt"))
            let beside = try Data(contentsOf: projects.appendingPathComponent("review-types-\(bits).gdt"))
            XCTAssertEqual(SHA256Digest(data: kept), SHA256Digest(data: beside), "the copy beside the projects")
        }

        try await define("typedef struct _TV_ITEM { int Unknown00; int Count; } TV_ITEM;")
        _ = try await host.publish(module, by: "agent")
        let first = try versions()
        XCTAssertEqual(first.map(\.version), [1])
        XCTAssertTrue(!Set(first[0].added).isDisjoint(with: ["TV_ITEM", "_TV_ITEM"]), "\(first[0])")
        XCTAssertEqual(first[0].module, module)
        XCTAssertNotNil(first[0].rev, "a version names the revision that made it")
        try copyIsCurrent()

        try await define("typedef struct _TV_ITEM { int Size; int Count; } TV_ITEM;")
        let amended = try await host.publish(module, by: "agent")
        XCTAssertEqual(amended.typeConflicts, [])
        let second = try versions()
        XCTAssertEqual(second.map(\.version), [1, 2])
        XCTAssertTrue(!Set(second[1].amended).isDisjoint(with: ["TV_ITEM", "_TV_ITEM"]), "\(second[1])")
        try copyIsCurrent()

        // A layout that differs: refused, and nothing of the store changes.
        let revision = try await store.latestRevision(module: module)
        let index = try store.libraryIndex()
        try await define("typedef struct _TV_ITEM { int Size; int Count; int More; } TV_ITEM;")
        do {
            _ = try await host.publish(module, by: "agent")
            XCTFail("a replacement is refused")
        } catch let error as GhidraHostError {
            XCTAssertEqual(error.status, 409)
            XCTAssertTrue("\(error)".contains("_TV_ITEM"), "\(error)")
            XCTAssertTrue("\(error)".contains("Nothing was written"), "\(error)")
        }
        XCTAssertEqual(try versions().map(\.version), [1, 2])
        let after = try await store.latestRevision(module: module)
        XCTAssertEqual(after, revision)
        XCTAssertEqual(try store.libraryIndex(), index)
        XCTAssertEqual(try store.journals().count, 0)
        try copyIsCurrent()

        // The person's choice: an administrator's take is the next version.
        let taken = try await host.publish(module, by: "person", options: .init(takeTypeConflicts: true))
        XCTAssertFalse(taken.typeConflictsTaken.isEmpty)
        let third = try versions()
        XCTAssertEqual(third.map(\.version), [1, 2, 3])
        XCTAssertFalse(third[2].taken.isEmpty, "\(third[2])")
        try copyIsCurrent()

        // A withdrawal is one too.
        try await define("typedef struct _TV_GONE { int A; } TV_GONE;")
        _ = try await host.publish(module, by: "agent")
        XCTAssertEqual(try versions().count, 4)
        _ = try await host.write(module, "/v1/type", body: try JSONSerialization.data(withJSONObject: [
            "delete": true, "shared": true, "name": "TV_GONE", "reason": "a test name"] as [String: Any]))
        let fifth = try versions()
        XCTAssertEqual(fifth.count, 5)
        XCTAssertTrue(fifth.last?.withdrawn.contains("TV_GONE") == true, "\(String(describing: fifth.last))")
        XCTAssertEqual(fifth.last?.reason, "a test name")
        try copyIsCurrent()
        XCTAssertEqual(store.verify(), [])
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
        _ = try await host.createCached(module: image, name: "Module")
        try await host.take(SHA256Digest(data: image))
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
        _ = try await host.createCached(module: image, name: "Module")
        try await host.take(SHA256Digest(data: image))
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
        _ = try await host.createCached(module: image, name: "Module")
        try await host.take(SHA256Digest(data: image))
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
        _ = try await host.createCached(module: image, name: "Module")
        try await host.take(SHA256Digest(data: image))
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
        _ = try await host.createCached(module: image, name: "Module")
        try await host.take(SHA256Digest(data: image))
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
        _ = try await host.createCached(module: image, name: "Module")
        try await host.take(SHA256Digest(data: image))
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
        _ = try await host.createCached(module: image, name: "Module")
        try await host.take(SHA256Digest(data: image))
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
        _ = try await host.createCached(module: image, name: "Module")
        try await host.take(SHA256Digest(data: image))
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
        _ = try await host.createCached(module: image, name: "Module")
        try await host.take(SHA256Digest(data: image))
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

    /// A write answered as taken leaves no "Unable to use type" behind: a type
    /// the decompiler declines is refused, whichever path the write took, and
    /// so is one the program records but the decompiler does not use
    /// (issue 7ed6937e). Types of the local's own size, named as a review does.
    func testATypeAnsweredAsTakenIsUsedByTheDecompiler() async throws {
        guard let path = ProcessInfo.processInfo.environment["GHIDRA_TYPE_MODULE"] else {
            throw XCTSkip("GHIDRA_TYPE_MODULE is not set")
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GhidraHostUsedTypeTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ContentStore(root: directory.appendingPathComponent("store"))
        let host = GhidraHost(configuration: .init(projectsRoot: directory.appendingPathComponent("projects"),
                                                   idle: 300, holder: "GhidraHostUsedTypeTests"),
                              writer: store)
        let image = try Data(contentsOf: URL(fileURLWithPath: path))
        let module = SHA256Digest(data: image)
        _ = try await host.createCached(module: image, name: "Module")
        try await host.take(SHA256Digest(data: image))
        let bySize = ["1": "UINT8", "2": "UINT16", "4": "UINT32", "8": "UINT64"]
        let functions = try json(await host.read(module, "/v1/functions"))["functions"] as? [[String: Any]] ?? []
        var answered = 0, refused = 0
        var silent: [String] = []
        for function in functions {
            let entry = try XCTUnwrap(function["entry"] as? String)
            let before = try json(await host.read(module, "/v1/function/\(entry)"))
            for (index, local) in (before["locals"] as? [[String: Any]] ?? []).enumerated() {
                guard let storage = local["storage"] as? String,
                      let size = storage.split(separator: ":").last, let type = bySize[String(size)] else { continue }
                let name = "Probe\(index)"
                var request: [String: Any] = ["function": entry, "storage": storage, "type": type, "name": name]
                if let first = local["first_use"] as? String { request["first_use"] = first }
                do {
                    _ = try await host.write(module, "/v1/rename/variable",
                                             body: try JSONSerialization.data(withJSONObject: request))
                    answered += 1
                    let c = try json(await host.read(module, "/v1/function/\(entry)"))["c"] as? String ?? ""
                    if c.contains("Unable to use type for symbol \(name)") { silent.append("\(entry) \(storage) \(type)") }
                } catch {
                    refused += 1
                }
            }
        }
        await host.stop(module)
        print("USED answered=\(answered) refused=\(refused) silent=\(silent.count) \(silent.prefix(5))")
        XCTAssertGreaterThan(answered, 0)
        XCTAssertEqual(silent, [], "a type answered as taken that the decompiler does not use")
    }
}
