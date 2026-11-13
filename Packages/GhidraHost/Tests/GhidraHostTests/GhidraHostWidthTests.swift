import CodeAnalysis
import Foundation
import XCTest
@testable import GhidraHost

/// Ia32 and X64 told apart where the phase used to stand for them: the EDK2
/// archive of a project whose archive moved, and the library registry, whose
/// body keys an Ia32 and an X64 function can share (`CpuPause`, `AsmReadCr0`
/// have the same bytes). No Ghidra.
final class GhidraHostWidthTests: XCTestCase {
    private var directory: URL!
    private var host: GhidraHost!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GhidraHostWidth-\(UUID().uuidString)", isDirectory: true)
        let store = try ContentStore(root: directory.appendingPathComponent("store"))
        host = GhidraHost(configuration: .init(projectsRoot: directory.appendingPathComponent("projects"),
                                               idle: 300, holder: "GhidraHostWidthTests"),
                          writer: store)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func state(kind: String = "PE32", phase: String?, bits: Int? = nil, archive: String?) throws -> ProjectState {
        var module: [String: Any] = ["sha256": String(repeating: "0", count: 64), "size": 1, "name": "M", "kind": kind]
        if let phase { module["phase"] = phase }
        if let bits { module["bits"] = bits }
        var object: [String: Any] = [
            "schema": 1, "project": "p", "module": module, "program": "M.efi",
            "made_with": ["ghidra": "12.2", "types": "edk2-stable202608-r3", "passes": ["ApplyUefi.java"]],
            "created_at": "2026-11-13T00:00:00Z", "reviewed": false]
        if let archive { object["archive"] = archive }
        return try JSONDecoder().decode(ProjectState.self, from: try JSONSerialization.data(withJSONObject: object))
    }

    func testTheWidthComesFromTheArchiveOrTheMachineBeforeThePhase() throws {
        // An X64 PEIM: the archive's name says so, even moved away.
        XCTAssertFalse(GhidraHost.typedIa32(try state(phase: "pei", archive: "/gone/uefi_X64-edk2-stable202608-r3.gdt")))
        XCTAssertTrue(GhidraHost.typedIa32(try state(phase: "dxe", archive: "uefi_Ia32-edk2-stable202608-r3.gdt")))
        // No archive: the machine recorded at create.
        XCTAssertFalse(GhidraHost.typedIa32(try state(phase: "pei", bits: 64, archive: nil)))
        XCTAssertTrue(GhidraHost.typedIa32(try state(phase: "dxe", bits: 32, archive: nil)))
        // Neither: the phase, as before.
        XCTAssertTrue(GhidraHost.typedIa32(try state(kind: "TE", phase: nil, archive: nil)))
        XCTAssertFalse(GhidraHost.typedIa32(try state(phase: "dxe", archive: nil)))
    }

    private func project(_ name: String, bits: Int) async throws -> SHA256Digest {
        let module = SHA256Digest(data: Data(name.utf8))
        let project = await host.project(module)
        try FileManager.default.createDirectory(at: project.folder, withIntermediateDirectories: true)
        var made = try state(phase: bits == 32 ? "pei" : "dxe",
                             archive: bits == 32 ? "uefi_Ia32-edk2-stable202608-r3.gdt" : "uefi_X64-edk2-stable202608-r3.gdt")
        made.module.sha256 = module.hex
        try project.write(made)
        return module
    }

    private func entry(_ name: String, _ body: LibraryBody, from module: SHA256Digest) -> LibraryIndexEntry {
        LibraryIndexEntry(version: 1, entry: SHA256Digest(data: Data(name.utf8)), name: name, kind: "edk2",
                          source: LibrarySource(module: module, address: "0x10", rev: 1, by: "agent"),
                          variants: [LibraryVariant(body: body, module: module)])
    }

    func testAnEntryOfTheOtherWidthIsNoMatchAndTakesNoOffer() async throws {
        let pei = try await project("CpuPei", bits: 32), dxe = try await project("DxeCore", bits: 64)
        let pause = LibraryBody(size: 8, full: "1111111111111111", specific: "2222222222222222")
        let copy = LibraryBody(size: 24, full: "3333333333333333", specific: "4444444444444444")
        var index = LibraryIndex()
        index.entries["ia32"] = entry("CpuPause", pause, from: pei)
        index.entries["x64"] = entry("InternalMemCopyMem_X64", copy, from: dxe)
        index.bodies = [pause.key: "ia32", copy.key: "x64"]

        let foreign = await host.foreignEntries(index, for: dxe)
        XCTAssertEqual(foreign, ["ia32"])
        let own = await host.foreignEntries(index, for: pei)
        XCTAssertEqual(own, ["x64"])
        // A module this host has no project of filters nothing.
        let unknown = await host.foreignEntries(index, for: SHA256Digest(data: Data("elsewhere".utf8)))
        XCTAssertEqual(unknown, [])

        // Matching: the Ia32 entry is neither exact nor near for DxeCore; a
        // function already bound to it keeps showing its mark.
        func match(_ address: String, exact: String?, near: [String]?, mark: String? = nil) -> GhidraHost.LibraryMatch {
            GhidraHost.LibraryMatch(address: address, name: "F", named: false, key: "k", exact: exact, near: near,
                                    mark: mark.map { .init(id: $0, version: 1, edited: false, codes: nil) },
                                    declined: nil)
        }
        let matched = GhidraHost.withoutForeign([
            match("0x100", exact: "ia32", near: nil),
            match("0x200", exact: nil, near: ["ia32", "x64"]),
            match("0x300", exact: "ia32", near: nil, mark: "ia32"),
            match("0x400", exact: "x64", near: nil)
        ], foreign: foreign)
        XCTAssertNil(matched[0].exact)
        XCTAssertNil(matched[0].near)
        XCTAssertEqual(matched[1].near, ["x64"])
        XCTAssertEqual(matched[2].exact, "ia32")
        XCTAssertEqual(matched[3].exact, "x64")
        let plan = GhidraHost.libraryPlan(matched, index: index, hashed: 4, comparisons: [:])
        XCTAssertFalse(plan.toApply.contains { $0.id == "ia32" }, "\(plan.toApply)")
        XCTAssertTrue(plan.toApply.contains { $0.id == "x64" }, "\(plan.toApply)")

        // Publishing: DxeCore's CpuPause, the same bytes, stays its own.
        let review = Data(#"{"name":"CpuPause"}"#.utf8)
        let offers = [
            LibraryProposal(body: pause, name: "CpuPause", kind: "edk2", address: "0x100", entry: review),
            LibraryProposal(body: copy, name: "InternalMemCopyMem_X64", kind: "edk2", address: "0x400", entry: review),
            LibraryProposal(body: LibraryBody(size: 30, full: "5555555555555555", specific: "6666666666666666"),
                            name: "SetMemVariant", kind: "edk2", address: "0x500", entry: review, variantOf: "ia32")
        ]
        let offered = GhidraHost.ownWidth(offers, index: index, foreign: foreign)
        XCTAssertEqual(offered.map(\.address), ["0x400"])
    }
}
