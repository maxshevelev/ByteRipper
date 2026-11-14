import CodeAnalysis
import Foundation
import XCTest
@testable import GhidraHost

/// Issue 4a9a4484: EDK2's function types came with no convention, which a
/// 32-bit program reads as `__stdcall`, so each indirect call through a PEI
/// service moved the caller's stack locals. The program's, EDK2's and the
/// shared review types are all EFIAPI, `__cdecl`. Runs against
/// `GHIDRA_TYPE_MODULE`, a 32-bit PEI module.
final class GhidraHostEFIAPITests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GhidraHostEFIAPI-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func image() throws -> Data {
        guard let path = ProcessInfo.processInfo.environment["GHIDRA_TYPE_MODULE"] else {
            throw XCTSkip("GHIDRA_TYPE_MODULE is not set")
        }
        return try Data(contentsOf: URL(fileURLWithPath: path))
    }

    private func json(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func host(_ store: ContentStore) -> GhidraHost {
        GhidraHost(configuration: .init(projectsRoot: directory.appendingPathComponent("projects"), idle: 300,
                                        holder: "GhidraHostEFIAPITests"),
                   writer: store)
    }

    func testRevisionsAreReadFromTheTypes() {
        XCTAssertEqual(GhidraHost.typesRevision("edk2-stable202608"), 1)
        XCTAssertEqual(GhidraHost.typesRevision("edk2-stable202608-r2"), 2)
        XCTAssertNil(GhidraHost.typesRevision("edk2-stable202502-r2"))
        XCTAssertGreaterThanOrEqual(UEFITypes.typesRevision, 4)
    }

    func testAPEIServiceTypeIsCdeclInTheProgramAndInEDK2() async throws {
        let image = try image()
        let module = SHA256Digest(data: image)
        let host = host(try ContentStore(root: directory.appendingPathComponent("store")))
        _ = try await host.createCached(module: image, name: "Module")
        defer { Task { await host.stop(module) } }
        let type = try json(await host.read(module, "/v1/type?name=EFI_PEI_LOCATE_PPI"))
        XCTAssertEqual((type["program"] as? [String: Any])?["convention"] as? String, "__cdecl", "\(type)")
        XCTAssertEqual((type["edk2"] as? [String: Any])?["convention"] as? String, "__cdecl", "\(type)")
        let project = await host.project(module)
        XCTAssertEqual(try project.state().madeWith.types, UEFITypes.types)
    }

    /// A project typed with revision 2 opens with the current archive, and its
    /// program's function types are EFIAPI.
    func testAProjectTypedBeforeRevision3GoesOnWithTheCurrentArchive() async throws {
        let image = try image()
        let module = SHA256Digest(data: image)
        let host = host(try ContentStore(root: directory.appendingPathComponent("store")))
        _ = try await host.createCached(module: image, name: "Module")
        await host.stop(module)
        let project = await host.project(module)
        var state = try project.state()
        state.madeWith.types = "\(UEFITypes.edk2Tag)-r2"
        state.archive = UEFITypes.cacheRoot.appendingPathComponent("uefi_Ia32-\(UEFITypes.edk2Tag)-r2.gdt").path
        try project.write(state)
        defer { Task { await host.stop(module) } }
        let type = try json(await host.read(module, "/v1/type?name=EFI_PEI_INSTALL_PPI"))
        XCTAssertEqual((type["program"] as? [String: Any])?["convention"] as? String, "__cdecl", "\(type)")
        let now = try project.state()
        XCTAssertEqual(now.madeWith.types, UEFITypes.types)
        XCTAssertEqual(now.archive.map { URL(fileURLWithPath: $0).lastPathComponent }, "uefi_Ia32-\(UEFITypes.types).gdt")
    }

    /// Shared 32-bit types whose function types have no convention — here an
    /// archive of revision 2 — get one version that gives it to them, once.
    func testSharedTypesWithoutTheConventionGetOneVersionOfTheirOwn() async throws {
        let old = UEFITypes.cacheRoot.appendingPathComponent("uefi_Ia32-\(UEFITypes.edk2Tag)-r2.gdt")
        guard FileManager.default.fileExists(atPath: old.path) else { throw XCTSkip("no revision 2 archive at \(old.path)") }
        let image = try image()
        let module = SHA256Digest(data: image)
        let store = try ContentStore(root: directory.appendingPathComponent("store"))
        var files: [String: SHA256Digest] = [:]
        files["archive.gdt"] = try store.putObject(try Data(contentsOf: old))
        files["origin.json"] = try store.putObject(Data("{}".utf8))
        files["withdrawn.json"] = try store.putObject(Data("{}".utf8))
        _ = try await store.writeTypeArchive(bits: "Ia32", version: TypeArchiveVersion(
            version: 1, files: files, at: "2026-11-10T00:00:00Z", by: "test", module: nil, rev: nil))
        let host = host(store)
        _ = try await host.createCached(module: image, name: "Module")
        defer { Task { await host.stop(module) } }
        _ = try await host.read(module, "/v1/hello")
        // Revision 2's enums are revision 3's too: their aliased members get
        // a version of their own after it (issue 33a286ab).
        let versions = try store.typeArchive(bits: "Ia32")?.versions ?? []
        XCTAssertEqual(versions.map(\.version), [1, 2, 3], "\(versions)")
        XCTAssertTrue(versions[1].reason?.contains("4a9a4484") == true, "\(versions[1])")

        // Another owner of this process, or of the next one, finds nothing to do.
        await host.stop(module)
        let again = self.host(store)
        _ = try await again.read(module, "/v1/hello")
        await again.stop(module)
        XCTAssertEqual(try store.typeArchive(bits: "Ia32")?.versions.map(\.version), [1, 2, 3])
    }

    /// Issue 33a286ab: shared types holding an EDK2 enum of an archive before
    /// revision 4 — `EfiGcdMemoryTypePersistentMemory` numbered 5, not the 4
    /// of the member it aliases — get one version that gives them EDK2's
    /// values, and the EDK2 archive has them right.
    func testSharedEDK2EnumsTakeTheValuesOfRevision4() async throws {
        let old = UEFITypes.cacheRoot.appendingPathComponent("uefi_Ia32-\(UEFITypes.edk2Tag)-r3.gdt")
        guard FileManager.default.fileExists(atPath: old.path) else { throw XCTSkip("no revision 3 archive at \(old.path)") }
        let image = try image()
        let module = SHA256Digest(data: image)
        let store = try ContentStore(root: directory.appendingPathComponent("store"))
        var files: [String: SHA256Digest] = [:]
        files["archive.gdt"] = try store.putObject(try Data(contentsOf: old))
        files["origin.json"] = try store.putObject(Data("{}".utf8))
        files["withdrawn.json"] = try store.putObject(Data("{}".utf8))
        _ = try await store.writeTypeArchive(bits: "Ia32", version: TypeArchiveVersion(
            version: 1, files: files, at: "2026-11-14T00:00:00Z", by: "test", module: nil, rev: nil))
        let host = host(store)
        _ = try await host.createCached(module: image, name: "Module")
        defer { Task { await host.stop(module) } }
        _ = try await host.read(module, "/v1/hello")
        let versions = try store.typeArchive(bits: "Ia32")?.versions ?? []
        XCTAssertEqual(versions.map(\.version), [1, 2], "\(versions)")
        XCTAssertTrue(versions.last?.reason?.contains("33a286ab") == true, "\(String(describing: versions.last))")
        let type = try json(await host.read(module, "/v1/type?name=EFI_GCD_MEMORY_TYPE"))
        for side in ["edk2", "shared"] {
            let values = (type[side] as? [String: Any])?["values"] as? [String: String] ?? [:]
            XCTAssertEqual(values["EfiGcdMemoryTypePersistentMemory"], "0x4", "\(side): \(values)")
            XCTAssertEqual(values["EfiGcdMemoryTypeMoreReliable"], "0x5", "\(side): \(values)")
            XCTAssertEqual(values["EfiGcdMemoryTypeUnaccepted"], "0x6", "\(side): \(values)")
            XCTAssertEqual(values["EfiGcdMemoryTypeMaximum"], "0x7", "\(side): \(values)")
        }

        // The next owner of the next process finds nothing to do.
        await host.stop(module)
        let again = self.host(store)
        _ = try await again.read(module, "/v1/hello")
        await again.stop(module)
        XCTAssertEqual(try store.typeArchive(bits: "Ia32")?.versions.map(\.version), [1, 2])
    }
}
