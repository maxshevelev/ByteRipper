import CodeAnalysis
import Foundation
import XCTest
@testable import GhidraHost

/// The modules an applied proposal tells include those whose program holds a
/// replaced type their C never prints: AmdSocFp6CznPei held `APOB_INFO` and
/// printed only `APOB_HOB_INFO`, so no use named it, and its next publish
/// would have been refused unwarned (issue 8ba08281). No Ghidra.
final class ReviewTypeHoldersTests: XCTestCase {
    private var directory: URL!
    private var store: ContentStore!
    private var host: GhidraHost!
    private let recipe = AnalysisRecipe(id: "code-v10-test", exporter: 10, ghidra: "12.2", script: "ExportCode.java")

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReviewTypeHolders-\(UUID().uuidString)", isDirectory: true)
        store = try ContentStore(root: directory.appendingPathComponent("store"))
        host = GhidraHost(configuration: .init(projectsRoot: directory.appendingPathComponent("projects"),
                                               idle: 300, holder: "ReviewTypeHoldersTests"),
                          writer: store)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func publish(_ name: String, rev: Int, reviewTypes: [String], printed: [String]) throws {
        let module = ModuleIdentity(sha256: SHA256Digest(data: Data(name.utf8)), size: name.utf8.count, name: name)
        let review = try JSONSerialization.data(withJSONObject: [
            "schema": 1, "functions": [:], "comments": [], "data": [:],
            "types": reviewTypes.map { ["name": $0, "c": "typedef struct _\($0) { int Unknown00; } \($0);"] }])
        let digest = try store.putObject(review)
        let artifact = try JSONSerialization.data(withJSONObject: [
            "functions": [["entry": "0x10", "name": "Reads", "c": printed.map { "\($0) *Info;" }.joined(separator: "\n")]],
            "types": printed.map { ["name": $0, "c": "typedef struct _\($0) { int Unknown00; } \($0);"] }])
        _ = try store.putAnalysis(module: module, recipe: recipe, artifact: artifact,
                                  reading: AnalysisReading(rev: rev, review: digest))
    }

    func testAProgramHoldingATypeItsCNeverPrintsIsAHolder() async throws {
        try publish("AmdSocFp6CznPei", rev: 93, reviewTypes: ["APOB_HOB_INFO", "APOB_INFO"], printed: ["APOB_HOB_INFO"])
        try publish("AmdSocFp6RnPei", rev: 12, reviewTypes: ["APOB_HOB_INFO"], printed: ["APOB_HOB_INFO"])

        // What the uses alone find: nobody prints APOB_INFO.
        let used = try await host.typeUses(name: "APOB_INFO", limit: 1)
        let uses = try JSONSerialization.jsonObject(with: used)
        XCTAssertEqual(((uses as? [String: Any])?["modules"] as? [Any])?.count, 0, "\(uses)")

        let holders = await host.reviewTypeHolders(["APOB_INFO"])
        XCTAssertEqual(holders.map(\.name), ["AmdSocFp6CznPei"])
        XCTAssertEqual(holders.first?.revision, 93)
        // A tag names the same type.
        let tagged = await host.reviewTypeHolders(["_APOB_INFO"])
        XCTAssertEqual(tagged.map(\.name), ["AmdSocFp6CznPei"])
        let printed = await host.reviewTypeHolders(["APOB_HOB_INFO"])
        XCTAssertEqual(printed.map(\.name), ["AmdSocFp6CznPei", "AmdSocFp6RnPei"])
    }
}

/// Who blocks an author correcting its own shared type without a vote: other
/// modules of the same size that published it, and kept projects whose
/// unpublished writes nobody can see without opening them. No Ghidra.
final class OtherTypeHoldersTests: XCTestCase {
    private var directory: URL!
    private var store: ContentStore!
    private var host: GhidraHost!
    private let recipe = AnalysisRecipe(id: "code-v10-test", exporter: 10, ghidra: "12.2", script: "ExportCode.java")

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OtherTypeHolders-\(UUID().uuidString)", isDirectory: true)
        store = try ContentStore(root: directory.appendingPathComponent("store"))
        host = GhidraHost(configuration: .init(projectsRoot: directory.appendingPathComponent("projects"),
                                               idle: 300, holder: "OtherTypeHoldersTests"),
                          writer: store)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    @discardableResult
    private func publish(_ name: String, language: String, types: [String], links: [String] = []) throws -> SHA256Digest {
        let module = ModuleIdentity(sha256: SHA256Digest(data: Data(name.utf8)), size: name.utf8.count, name: name,
                                    language: language)
        let review = try JSONSerialization.data(withJSONObject: [
            "schema": 1, "functions": [:], "comments": [], "data": [:],
            "types": types.map { ["name": $0, "c": "typedef struct _\($0) { int Unknown00; } \($0);"] }])
        let functions = links.enumerated().map { ["entry": String(format: "0x%X", 0x1000 + $0.offset * 0x10),
                                                  "size": 0x40, "registry": $0.element,
                                                  "body": Self.body($0.element).key] as [String: Any] }
        let artifact = try JSONSerialization.data(withJSONObject: ["functions": functions, "types": []])
        _ = try store.putAnalysis(module: module, recipe: recipe, artifact: artifact,
                                  reading: AnalysisReading(rev: 1, review: try store.putObject(review)))
        return module.sha256
    }

    private func project(_ name: String, x64: Bool, published: Int, writes: Int) async throws {
        let module = SHA256Digest(data: Data(name.utf8))
        let project = await host.project(module)
        try FileManager.default.createDirectory(at: project.folder, withIntermediateDirectories: true)
        let state: [String: Any] = [
            "schema": 1, "project": "p", "program": "\(name).efi",
            "module": ["sha256": module.hex, "size": 1, "name": name, "kind": "PE32"],
            "made_with": ["ghidra": "12.2", "types": "edk2-stable202608-r3", "passes": []],
            "archive": x64 ? "uefi_X64-edk2-stable202608-r3.gdt" : "uefi_Ia32-edk2-stable202608-r3.gdt",
            "created_at": "2026-11-13T00:00:00Z", "reviewed": true,
            "published": ["artifact": String(repeating: "0", count: 64), "recipe": "r", "at": "t", "writes": published]]
        try JSONSerialization.data(withJSONObject: state).write(to: project.stateURL)
        try Data(module.hex.utf8).write(to: project.folder.appendingPathComponent("module.gpr"))
        try "\(writes)\n".write(to: project.folder.appendingPathComponent("writes"), atomically: true, encoding: .utf8)
    }

    func testOtherHoldersOfTheSameSizeBlockAndTheAuthorDoesNot() async throws {
        let author = try publish("DxeCore", language: "x86:LE:64:default", types: ["PE_IMAGE_CONTEXT"])
        // Alone, nobody else holds it.
        var blocking = await host.otherTypeHolders(["PE_IMAGE_CONTEXT"], module: author, bits: "X64")
        XCTAssertEqual(blocking, [:])
        // An Ia32 module holding the same name is another archive's.
        try publish("PeiCore", language: "x86:LE:32:default", types: ["PE_IMAGE_CONTEXT"])
        blocking = await host.otherTypeHolders(["PE_IMAGE_CONTEXT"], module: author, bits: "X64")
        XCTAssertEqual(blocking, [:])
        // An X64 module's published review holding it blocks.
        try publish("BdsDxe", language: "x86:LE:64:default", types: ["_PE_IMAGE_CONTEXT"])
        blocking = await host.otherTypeHolders(["PE_IMAGE_CONTEXT"], module: author, bits: "X64")
        XCTAssertEqual(blocking["PE_IMAGE_CONTEXT"], ["BdsDxe"])
        // So does an X64 project with writes the store has not got; one with none does not.
        try await project("CpuDxe", x64: true, published: 4, writes: 6)
        try await project("PciDxe", x64: true, published: 4, writes: 4)
        try await project("CpuPei", x64: false, published: 4, writes: 9)
        blocking = await host.otherTypeHolders(["PE_IMAGE_CONTEXT"], module: author, bits: "X64")
        XCTAssertEqual(blocking["PE_IMAGE_CONTEXT"], ["BdsDxe", "CpuDxe (unpublished writes)"])

        XCTAssertTrue(GhidraHost.ownTypes(["A"], origins: ["A": author.hex], module: author))
        // A tag is its typedef's type.
        XCTAssertTrue(GhidraHost.ownTypes(["A", "_A"], origins: ["A": author.hex], module: author))
        XCTAssertFalse(GhidraHost.ownTypes(["A", "B"], origins: ["A": author.hex, "B": String(repeating: "1", count: 64)],
                                           module: author))
        XCTAssertTrue(GhidraHost.holdersNote(blocking).contains("BdsDxe"))
    }

    /// An X64 proposal applied tells no Ia32 module that holds a type of the
    /// same name: that one is the Ia32 archive's, and the apply left it alone.
    func testAnX64ApplyTellsNoIa32HolderOfTheSameName() async throws {
        let author = try publish("DxeCore", language: "x86:LE:64:default", types: ["PE_COFF_LOADER_IMAGE_CONTEXT"])
        let ia32 = try publish("PeiCore", language: "x86:LE:32:default", types: ["PE_COFF_LOADER_IMAGE_CONTEXT"])
        let x64 = try publish("BdsDxe", language: "x86:LE:64:default", types: ["PE_COFF_LOADER_IMAGE_CONTEXT"])
        let proposer = try publish("CpuDxe", language: "x86:LE:64:default", types: [])
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let proposal = try decoder.decode(TypeProposalBook.Proposal.self, from: try JSONSerialization.data(withJSONObject: [
            "id": "p1", "at": "2026-11-13T00:00:00Z", "module": proposer.hex, "bits": "X64",
            "names": ["PE_COFF_LOADER_IMAGE_CONTEXT", "_PE_COFF_LOADER_IMAGE_CONTEXT"],
            "module_c": [:], "shared_c": [:], "origins": ["PE_COFF_LOADER_IMAGE_CONTEXT": author.hex],
            "author": "a", "holder": "h", "reason": "r", "votes": [], "state": "applied"]))
        let told = await host.appliedRecipients(proposal, module: proposer).map(\.module)
        XCTAssertEqual(Set(told), [author, x64])
        XCTAssertFalse(told.contains(ia32))
        XCTAssertFalse(told.contains(proposer))
    }

    private static func body(_ id: String) -> LibraryBody {
        LibraryBody(size: 0x40, full: String(repeating: id, count: 16), specific: String(repeating: id, count: 16))
    }

    /// The registry holding `ids`, each with one body, written by `author`.
    private func registry(_ ids: [String], author: SHA256Digest) throws {
        var index = LibraryIndex()
        for id in ids {
            index.entries[id] = LibraryIndexEntry(
                version: 1, entry: try store.putObject(Data("{}".utf8)), name: "Entry\(id)", kind: "library.edk2",
                source: LibrarySource(module: author, address: "0x1000", rev: 1, by: "agent"),
                variants: [LibraryVariant(body: Self.body(id), module: author)])
            index.bodies[Self.body(id).key] = id
        }
        try FileManager.default.createDirectory(at: store.libraryURL, withIntermediateDirectories: true)
        try JSONEncoder().encode(index).write(to: store.libraryURL.appendingPathComponent("index.json"))
    }

    /// An entry's other holders: a published review of the same size linking it.
    func testAnEntrysOtherHoldersAreTheModulesOfItsSizeLinkingIt() async throws {
        try registry(["7", "8"], author: SHA256Digest(data: Data("AmdSocFp6CznPei".utf8)))
        let author = try publish("AmdSocFp6CznPei", language: "x86:LE:32:default", types: [], links: ["7"])
        var blocking = await host.otherEntryHolders(["7"], module: author, bits: "Ia32")
        XCTAssertEqual(blocking, [:])
        try publish("CpuDxe", language: "x86:LE:64:default", types: [], links: ["7"])
        blocking = await host.otherEntryHolders(["7"], module: author, bits: "Ia32")
        XCTAssertEqual(blocking, [:], "an X64 module's link is not to this entry's size")
        try publish("AmdSocFp6RnPei", language: "x86:LE:32:default", types: [], links: ["8", "7"])
        try await project("CpuPei", x64: false, published: 4, writes: 9)
        blocking = await host.otherEntryHolders(["7"], module: author, bits: "Ia32")
        XCTAssertEqual(blocking["Entry7"], ["AmdSocFp6RnPei", "CpuPei (unpublished writes)"])
    }
}
