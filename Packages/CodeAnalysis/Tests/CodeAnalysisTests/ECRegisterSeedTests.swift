import Foundation
import XCTest
@testable import CodeAnalysis

/// The register registry's first fill from the chip's tables
/// (`Skills/ghidra-ec/reference`): one entry per address, the replaced
/// names in the history, a dry run that writes nothing, a second seed that
/// adds nothing.
final class ECRegisterSeedTests: XCTestCase {
    private var directory: URL!
    private var store: ContentStore!
    private let reference = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Skills/ghidra-ec/reference", isDirectory: true)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ECRegisterSeedTests-\(UUID().uuidString)", isDirectory: true)
        store = try ContentStore(root: directory)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    func testADryRunWritesNothing() throws {
        let report = try ECRegisterSeed.run(store: store, chip: "it8227e", reference: reference, apply: false)
        XCTAssertFalse(report.applied)
        XCTAssertEqual(report.registers.added + report.registers.aliases, 664)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.registersURL.appendingPathComponent("it8227e.json").path))
        XCTAssertEqual(try store.registerFile("it8227e").version, 0)
    }

    func testTheTablesSeedTheRegistry() throws {
        let report = try ECRegisterSeed.run(store: store, chip: "it8227e", reference: reference, apply: true)
        XCTAssertTrue(report.applied)
        XCTAssertEqual(report.versionAfter, 1)
        // 664 register rows: 663 addresses, one with an alias.
        XCTAssertEqual(report.registers.added, 663)
        XCTAssertEqual(report.registers.aliases, 1)
        XCTAssertEqual(report.registers.history, 10)
        XCTAssertEqual(report.irqs.added, 174)
        XCTAssertEqual(report.irqs.history, 7)
        XCTAssertEqual(report.duplicateNames, ["SMB_E": ["152", "160"]])

        let file = try store.registerFile("it8227e")
        XCTAssertEqual(file.version, 1)
        XCTAssertEqual(file.registers.count, 663)
        XCTAssertEqual(file.irqs.count, 174)
        let spi = try XCTUnwrap(file.registers["0x00F03A08"])
        XCTAssertEqual(spi.current.names.count, 2)

        let smb = try XCTUnwrap(file.registers["0x00F01C00"])
        XCTAssertEqual(smb.current.name, "SMB_HOSTA_A")
        XCTAssertEqual(smb.current.status, .firmware)
        XCTAssertTrue(smb.current.evidence?.text?.contains("IT8227E fw") == true)
        XCTAssertEqual(smb.history?.map(\.name), ["SMB_4P7USL"])
        XCTAssertEqual(file.state(.register, "0x00F01C00", at: 0)?.name, "SMB_4P7USL", "the published map, before the overlay")
        XCTAssertEqual(file.everName("SMB_4P7USL", kind: .register), ["0x00F01C00"])

        let pecI = try XCTUnwrap(file.irqs["160"])
        XCTAssertEqual(pecI.current.name, "SMB_E")
        XCTAssertEqual(pecI.history?.map(\.name), ["PECI"])
        XCTAssertNil(pecI.current.width)

        let again = try ECRegisterSeed.run(store: store, chip: "it8227e", reference: reference, apply: true)
        XCTAssertEqual(again.registers.added + again.irqs.added, 0)
        XCTAssertEqual(again.registers.same, 663)
        XCTAssertFalse(again.applied)
        XCTAssertEqual(try store.registerFile("it8227e").version, 1, "a seed that adds nothing is no version")
    }

    func testTheCommandLineSeeds() throws {
        let dry = CASCommand.run(["--store", directory.path, "registers-seed", "--chip", "it8227e",
                                  "--reference", reference.path])
        XCTAssertEqual(dry.status, 0, String(decoding: dry.stderr, as: UTF8.self))
        XCTAssertEqual(try store.registerFile("it8227e").version, 0)
        let applied = CASCommand.run(["--store", directory.path, "registers-seed", "--chip", "it8227e",
                                      "--reference", reference.path, "--apply"])
        XCTAssertEqual(applied.status, 0)
        let replaced = CASCommand.run(["--store", directory.path, "register-replace", "--chip", "it8227e",
                                       "--address", "0xF01C00", "--name", "SMB_HSTS_A", "--reason", "test",
                                       "--module", String(repeating: "ab", count: 32), "--code", "0x3C5A, 0x3C48"])
        XCTAssertEqual(replaced.status, 0, String(decoding: replaced.stderr, as: UTF8.self))
        XCTAssertEqual(try store.registerFile("it8227e").registers["0x00F01C00"]?.current.name, "SMB_HSTS_A")
        let removed = CASCommand.run(["--store", directory.path, "register-remove", "--chip", "it8227e",
                                      "--irq", "152", "--reason", "IT8320's", "--apply"])
        XCTAssertEqual(removed.status, 0, String(decoding: removed.stderr, as: UTF8.self))
        XCTAssertNotNil(try store.registerFile("it8227e").irqs["152"]?.removedIn)
    }
}
