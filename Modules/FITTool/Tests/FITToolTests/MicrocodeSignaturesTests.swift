import XCTest
@testable import FITTool
import UEFIImage

/// Which microcode updates serve several CPUIDs, from their extended signature
/// tables: what the form's Extended CPUIDs column shows and searches, and what
/// the processors popover says a CPUID shares its microcode with.
final class MicrocodeSignaturesTests: XCTestCase {
    private let signatures = MicrocodeSignatures(updates: [
        .init(revision: "3E", date: "2025-10-12",
              signatures: [.init(cpuid: "90672", platforms: "07"), .init(cpuid: "B06F2", platforms: "07"),
                           .init(cpuid: "B06F6", platforms: "07")],
              files: ["Intel/cpuB06F2_plat07_ver0000003E_2025-10-12_PRD_5582AF20.bin",
                      "Intel/cpu90672_plat07_ver0000003E_2025-10-12_PRD_00000000.bin"]),
        .init(revision: "3A", date: "2024-01-01",
              signatures: [.init(cpuid: "90672", platforms: "07"), .init(cpuid: "90675", platforms: "07")],
              files: ["Intel/cpu90672_plat07_ver0000003A_2024-01-01_PRD_11111111.bin"]),
    ])

    private func entry(_ name: String, size: UInt64 = 0x35C00) throws -> MicrocodeCatalogueEntry {
        try XCTUnwrap(MicrocodeCatalogue.entry(at: "Intel/" + name, size: size))
    }

    /// A file's extended CPUIDs are its update's other CPUIDs, without the one
    /// it is named after.
    func testAFilesExtendedCPUIDsAreItsUpdatesOthers() throws {
        let file = try entry("cpuB06F2_plat07_ver0000003E_2025-10-12_PRD_5582AF20.bin")
        XCTAssertEqual(signatures.extendedCPUIDs(of: file), ["90672", "B06F6"])
    }

    /// A copy the shipped table has not seen is matched by what its name says
    /// of the update; an update it does not know has none said.
    func testAnUnseenCopyIsMatchedByItsUpdateAndAnUnknownUpdateHasNone() throws {
        let copy = try entry("cpuB06F6_plat07_ver0000003E_2025-10-12_PRD_5582AF1C.bin")
        XCTAssertEqual(signatures.extendedCPUIDs(of: copy), ["90672", "B06F2"])
        let other = try entry("cpuB06F6_plat07_ver0000003F_2026-01-01_PRD_12345678.bin")
        XCTAssertEqual(signatures.extendedCPUIDs(of: other), [])
    }

    /// A CPUID shares its microcode with the CPUIDs of the newest update that
    /// serves it.
    func testACPUIDSharesTheNewestUpdatesOthers() {
        XCTAssertEqual(signatures.sharing(0x90672), ["B06F2", "B06F6"])
        XCTAssertEqual(signatures.sharing(0x806EA), [])
    }

    /// The form's search finds a file by any CPUID its update serves.
    func testTheSearchFindsAFileByAnExtendedCPUID() throws {
        let file = try entry("cpuB06F2_plat07_ver0000003E_2025-10-12_PRD_5582AF20.bin")
        let found = MicrocodeCatalogue.filter([file], vendor: .intel, search: "b06f6",
                                              processors: [], signatures: signatures)
        XCTAssertEqual(found, [file])
        XCTAssertEqual(MicrocodeCatalogue.filter([file], vendor: .intel, search: "B06F7",
                                                 processors: [], signatures: signatures), [])
    }

    /// The shipped table is read, and says what Intel's files do: the Alder
    /// Lake / Raptor Lake S update 0x3E serves six CPUIDs.
    func testTheShippedTableIsRead() {
        XCTAssertEqual(Set(MicrocodeSignatures.shipped.sharing(0xB06F5)),
                       ["90672", "90675", "B06F2", "B06F6", "B06F7"])
        let group = FITProcessorGroup.groups(for: [0xB06F5], language: .english).first
        XCTAssertEqual(Set(group?.sharesMicrocodeWith ?? []), ["90672", "90675", "B06F2", "B06F6", "B06F7"])
    }
}
