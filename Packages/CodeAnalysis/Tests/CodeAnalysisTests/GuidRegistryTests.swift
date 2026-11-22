import Foundation
import XCTest
@testable import CodeAnalysis

/// The GUID registry (`GuidRegistry`): one name per GUID in EDK2's variable
/// form, added by a review with its place, a placeholder named properly as an
/// addition, any other new name refused unless an administrator replaces it
/// with a reason; and its first fill from `.dec` files and interface records.
final class GuidRegistryTests: XCTestCase {
    private var directory: URL!
    private var store: ContentStore!
    private let rn = SHA256Digest(data: Data("AmdSocFp6RnPei".utf8))
    private let ccx = SHA256Digest(data: Data("AmdCcxVhRnPei".utf8))
    private let reset = "9C98130A-8921-45EB-86F3-16041C6BB7AD"

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GuidRegistryTests-\(UUID().uuidString)", isDirectory: true)
        store = try ContentStore(root: directory)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func offer(_ name: String, kind: GuidKind = .ppi, guid: String? = nil, module: SHA256Digest? = nil,
                       address: String = "0x9A0F1C0") -> GuidOffer {
        GuidOffer(guid: guid ?? reset, name: name, kind: kind, source: .review(module: module ?? rn, address: address))
    }

    func testANameIsWrittenTheRegistrysWay() {
        XCTAssertEqual(GuidName.registryForm("EFI_PEI_MEMORY_DISCOVERED_PPI"), "gEfiPeiMemoryDiscoveredPpiGuid")
        XCTAssertEqual(GuidName.registryForm("EfiPciIoProtocolGuid"), "gEfiPciIoProtocolGuid")
        XCTAssertEqual(GuidName.registryForm("gAmdFabricTopologyPpiGuid"), "gAmdFabricTopologyPpiGuid")
        XCTAssertEqual(GuidName.registryForm("gEfiPeiReadOnlyVariable2Ppi"), "gEfiPeiReadOnlyVariable2PpiGuid")
        XCTAssertNil(GuidName.registryForm("not a name"))
        XCTAssertEqual(GuidName.canonicalGUID("{9c98130a-8921-45eb-86f3-16041c6bb7ad}"), reset)
        XCTAssertNil(GuidName.canonicalGUID("9C98130A-8921-45EB-86F3"))
        XCTAssertEqual(GuidName.placeholder(kind: .ppi, guid: reset), "gUnknownPpi9C98130AGuid")
        XCTAssertEqual(GuidName.placeholder(kind: .protocol, guid: reset), "gUnknownProtocol9C98130AGuid")
    }

    func testADecFileDeclaresGUIDsByItsSections() {
        let text = """
            [Defines]
              DEC_SPECIFICATION = 0x00010005
            [Guids]
              ## Include/Guid/HobList.h
              gEfiHobListGuid = { 0x7739F24C, 0x93D7, 0x11D4, { 0x9A, 0x3A, 0x00, 0x90, 0x27, 0x3F, 0xC1, 0x4D }}
            [Ppis.common, Ppis.IA32]
              gEfiPeiMemoryDiscoveredPpiGuid = { 0xf894643d, 0xc449, 0x42d1, {0x8e, 0xa8, 0x85, 0xbd, 0xd8, 0xc6, 0x5b, 0xde }}
            [Protocols]
              gEfiPciIoProtocolGuid = { 0x4CF5B200, 0x68B8, 0x4CA5, { 0x9E, 0xEC, 0xB2, 0x3E, 0x3F, 0x50, 0x02, 0x9A }}
            [PcdsFixedAtBuild]
              gEfiMdePkgTokenSpaceGuid.PcdFoo|0|UINT32|0x1
            """
        let found = GuidSeed.declarations(in: text, file: "MdePkg/MdePkg.dec")
        XCTAssertEqual(found.map(\.name), ["gEfiHobListGuid", "gEfiPeiMemoryDiscoveredPpiGuid", "gEfiPciIoProtocolGuid"])
        XCTAssertEqual(found.map(\.kind), [.guid, .ppi, .protocol])
        XCTAssertEqual(found[1].guid, "F894643D-C449-42D1-8EA8-85BDD8C65BDE")
        XCTAssertEqual(found[1].file, "MdePkg/MdePkg.dec:7")
    }

    func testANewGUIDIsAddedAndTheSameNameCitesItsPlace() throws {
        let added = try store.offerGuid(offer("gAmdFactoryResetPpiGuid"), by: "Analyzis")
        XCTAssertEqual(added.outcome, .added)
        let same = try store.offerGuid(offer("gAmdFactoryResetPpiGuid", module: ccx, address: "0x1234"), by: "Other")
        XCTAssertEqual(same.outcome, .same)
        let entry = try XCTUnwrap(try store.guidRegistry().entries[reset])
        XCTAssertEqual(entry.version, 1)
        XCTAssertEqual(entry.citations?.count, 2)
        XCTAssertEqual(entry.by, "Analyzis")
        XCTAssertEqual(try store.guidRegistry().name(of: reset.lowercased()), "gAmdFactoryResetPpiGuid")
    }

    func testAnotherNameIsRefusedAndTheRegistrysStands() throws {
        _ = try store.offerGuid(offer("gAmdFactoryResetPpiGuid"), by: "Analyzis")
        let conflict = try store.offerGuid(offer("gAmdPspFtpmPpiGuid", module: ccx), by: "Other")
        XCTAssertEqual(conflict.outcome, .conflict)
        XCTAssertEqual(conflict.entry.name, "gAmdFactoryResetPpiGuid")
        XCTAssertEqual(conflict.offered, "gAmdPspFtpmPpiGuid")
        XCTAssertEqual(try store.guidRegistry().entries[reset]?.name, "gAmdFactoryResetPpiGuid")
        XCTAssertEqual(try store.guidRegistry().entries[reset]?.citations?.count, 1)
    }

    func testAPlaceholderNamedProperlyIsTheNextVersion() throws {
        _ = try store.offerGuid(offer(GuidName.placeholder(kind: .ppi, guid: reset)), by: "First")
        let named = try store.offerGuid(offer("gAmdFactoryResetPpiGuid", module: ccx), by: "Second")
        XCTAssertEqual(named.outcome, .addition)
        XCTAssertEqual(named.entry.version, 2)
        XCTAssertEqual(named.entry.history?.map(\.name), ["gUnknownPpi9C98130AGuid"])
        XCTAssertEqual(named.entry.source.module, ccx)
    }

    func testAnAdministratorReplacesWithAReasonTheHistoryKeeps() throws {
        _ = try store.offerGuid(offer("gAmdPspFtpmPpiGuid"), by: "First")
        XCTAssertThrowsError(try store.offerGuid(offer("gAmdFactoryResetPpiGuid"), by: "admin", replace: true))
        let replaced = try store.offerGuid(offer("gAmdFactoryResetPpiGuid", module: ccx), by: "admin", replace: true,
                                           reason: "ChipsetSvcPei installs it from its factory-reset path")
        XCTAssertEqual(replaced.outcome, .replaced)
        XCTAssertEqual(replaced.entry.reason, "ChipsetSvcPei installs it from its factory-reset path")
        XCTAssertEqual(replaced.entry.by, "admin")
        XCTAssertEqual(replaced.entry.history?.first?.name, "gAmdPspFtpmPpiGuid")
        XCTAssertEqual(replaced.entry.history?.first?.by, "First")
    }

    func testAPlainGUIDGivenItsKindIsAnAdditionThatKeepsItsSource() throws {
        _ = try store.offerGuids([GuidOffer(guid: reset, name: "gFooHobGuid", kind: .guid,
                                            source: .edk2(tag: "edk2-stable202608", file: "MdePkg/MdePkg.dec:9"))],
                                 by: "seed")
        let told = try store.offerGuid(offer("gFooHobGuid", kind: .hob), by: "Analyzis")
        XCTAssertEqual(told.outcome, .addition)
        XCTAssertEqual(told.entry.kind, .hob)
        XCTAssertEqual(told.entry.source.kind, .edk2)
        XCTAssertEqual(told.entry.citations?.first?.module, rn)
    }

    func testAnOfferOutOfFormIsRefusedWithTheRightForm() throws {
        XCTAssertThrowsError(try store.offerGuid(offer("AMD_FACTORY_RESET_PPI"), by: "x")) { error in
            XCTAssertTrue("\(error)".contains("gAmdFactoryResetPpiGuid"), "\(error)")
        }
        XCTAssertThrowsError(try store.offerGuid(offer("gAmdFactoryResetGuid"), by: "x")) { error in
            XCTAssertTrue("\(error)".contains("Ppi"), "\(error)")
        }
        XCTAssertThrowsError(try store.offerGuid(offer("gAmdFactoryResetPpiGuid", address: " "), by: "x"))
        XCTAssertThrowsError(try store.offerGuid(offer("gAmdFactoryResetPpiGuid", guid: "9C98130A"), by: "x"))
        XCTAssertTrue(try store.guidRegistry().entries.isEmpty)
    }

    func testANameWithTheGUIDsFirstGroupIsAPlaceholderTooAndTheSeedTakesTheRealName() throws {
        XCTAssertTrue(GuidName.isPlaceholder("gAmdSocInfoPpiGuid9C98130AGuid", guid: reset))
        XCTAssertFalse(GuidName.isPlaceholder("gAmdSocInfoPpiGuid", guid: reset))
        XCTAssertTrue(GuidName.isPlaceholder("gUnnamedAgesaDepexPpiGuid"))
        try record(rn, [interface(reset, "AMD_FACTORY_RESET_PPI_9C98130A")])
        try record(ccx, [interface(reset, "AMD_FACTORY_RESET_PPI")])
        let seed = try GuidSeed.run(store: store, declared: [], recorded: try GuidSeed.recorded(in: store),
                                    tag: "edk2-stable202608", catalogue: nil, apply: true)
        XCTAssertEqual(seed.recordConflicts, [])
        XCTAssertEqual(try store.guidRegistry().entries[reset]?.name, "gAmdFactoryResetPpiGuid")
    }

    func testMdePkgNamesAGUIDTwoPackagesDeclare() throws {
        let folder = directory.appendingPathComponent("edk2", isDirectory: true)
        let line = "{ 0x268f33a9, 0xcccd, 0x48be, { 0x88, 0x17, 0x86, 0x05, 0x3a, 0xc3, 0x2e, 0xd6 }}"
        for (file, name) in [("MdeModulePkg/MdeModulePkg.dec", "gPeiSmmAccessPpiGuid"),
                             ("MdePkg/MdePkg.dec", "gEfiPeiMmAccessPpiGuid")] {
            let url = folder.appendingPathComponent(file)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("[Ppis]\n  \(name) = \(line)\n".utf8).write(to: url)
        }
        let declared = try GuidSeed.declarations(checkout: folder)
        XCTAssertEqual(declared.map(\.name), ["gEfiPeiMmAccessPpiGuid", "gPeiSmmAccessPpiGuid"])
        let seed = try GuidSeed.run(store: store, declared: declared, recorded: [], tag: "t", catalogue: nil, apply: true)
        XCTAssertEqual(seed.edk2Duplicates.first?.registry, "gEfiPeiMmAccessPpiGuid")
        XCTAssertEqual(try store.guidRegistry().entries["268F33A9-CCCD-48BE-8817-86053AC32ED6"]?.name,
                       "gEfiPeiMmAccessPpiGuid")
    }

    func testADryRunWritesNothing() throws {
        let would = try store.offerGuid(offer("gAmdFactoryResetPpiGuid"), by: "x", dryRun: true)
        XCTAssertEqual(would.outcome, .added)
        XCTAssertTrue(try store.guidRegistry().entries.isEmpty)
    }

    // MARK: - Records against the registry

    func testARecordReadsUnderTheRegistrysNamesAndAMisnamedEntryIsFound() throws {
        let memory = "F894643D-C449-42D1-8EA8-85BDD8C65BDE"
        let unknown = "11111111-2222-3333-4444-555555555555"
        let record = ModuleInterfaces(installs: [interface(reset, "AMD_FACTORY_RESET_PPI")],
                                      locates: [interface(memory, "gEfiPeiMemoryDiscoveredPpiGuid"),
                                                interface(unknown, "gSomethingPpiGuid")],
                                      notifies: nil)
        XCTAssertTrue(record.misnamed(by: GuidRegistry()).isEmpty, "a store never seeded checks nothing")
        _ = try store.offerGuids([
            GuidOffer(guid: memory, name: "gEfiPeiMemoryDiscoveredPpiGuid", kind: .ppi,
                      source: .edk2(tag: "t", file: "MdePkg/MdePkg.dec:1")),
            offer("gAmdFactoryResetPpiGuid")
        ], by: "seed")
        let registry = try store.guidRegistry()
        let named = record.named(by: registry)
        XCTAssertEqual(named.installs?.first?.name, "gAmdFactoryResetPpiGuid")
        XCTAssertEqual(named.locates?.map(\.name), ["gEfiPeiMemoryDiscoveredPpiGuid", "gSomethingPpiGuid"])
        XCTAssertNil(named.notifies)
        let wrong = record.misnamed(by: registry)
        XCTAssertEqual(wrong.map(\.guid), [reset, unknown])
        XCTAssertTrue(wrong[0].why.contains("gAmdFactoryResetPpiGuid"), wrong[0].why)
        XCTAssertTrue(wrong[1].why.contains("ghidra_guid_add"), wrong[1].why)
    }

    // MARK: - The seed

    private func record(_ module: SHA256Digest, _ entries: [ModuleInterfaces.Interface]) throws {
        let document: [String: Any] = [
            "interfaces": try JSONSerialization.jsonObject(
                with: JSONEncoder().encode(ModuleInterfaces(installs: entries, locates: [], notifies: [])))
        ]
        let digest = try store.putObject(try JSONSerialization.data(withJSONObject: document, options: .sortedKeys))
        try store.recordRevision(module: module, reading: AnalysisReading(project: "p", rev: 1, review: digest))
    }

    private func interface(_ guid: String, _ name: String, at address: String = "0x100") -> ModuleInterfaces.Interface {
        ModuleInterfaces.Interface(guid: guid, name: name, kind: .ppi, address: address, condition: "always",
                                   purpose: "test")
    }

    func testTheSeedTakesEDK2AndAgreedRecordsAndListsTheRest() throws {
        let memory = "F894643D-C449-42D1-8EA8-85BDD8C65BDE"
        let topology = "07C09B9C-0000-4000-8000-000000000001"
        let declared = GuidSeed.declarations(in: """
            [Ppis]
              gEfiPeiMemoryDiscoveredPpiGuid = { 0xf894643d, 0xc449, 0x42d1, {0x8e, 0xa8, 0x85, 0xbd, 0xd8, 0xc6, 0x5b, 0xde }}
            """, file: "MdePkg/MdePkg.dec")
        try record(rn, [interface(memory, "EFI_PEI_MEMORY_DISCOVERED_PPI"),
                        interface(reset, "AMD_FACTORY_RESET_PPI"),
                        interface(topology, "AMD_FABRIC_TOPOLOGY_PPI")])
        try record(ccx, [interface(memory, "PEI_MEMORY_DISCOVERED_PPI"),
                         interface(reset, "gAmdFactoryResetPpiGuid", at: "0x200"),
                         interface(topology, "AMD_FABRIC_TOPOLOGY_SERVICES_PPI")])
        let recorded = try GuidSeed.recorded(in: store)
        XCTAssertEqual(recorded.count, 6)

        let dry = try GuidSeed.run(store: store, declared: declared, recorded: recorded, tag: "edk2-stable202608",
                                   catalogue: [memory: "gEfiPeiMemoryDiscoveredPpiGuid", reset: "gSomethingElsePpiGuid"],
                                   apply: false)
        XCTAssertTrue(try store.guidRegistry().entries.isEmpty, "a seed without --apply writes nothing")
        XCTAssertEqual(dry.recordConflicts.map(\.guid), [topology])
        XCTAssertEqual(dry.recordConflicts.first?.names.map(\.name),
                       ["gAmdFabricTopologyPpiGuid", "gAmdFabricTopologyServicesPpiGuid"])
        XCTAssertEqual(dry.recordsDifferFromEDK2.map(\.guid), [memory])
        XCTAssertEqual(dry.recordsDifferFromEDK2.first?.names.map(\.name), ["gPeiMemoryDiscoveredPpiGuid"])
        XCTAssertEqual(dry.catalogueDiffers?.map(\.guid), [reset])

        let seed = try GuidSeed.run(store: store, declared: declared, recorded: recorded, tag: "edk2-stable202608",
                                    catalogue: nil, apply: true)
        XCTAssertTrue(seed.applied)
        let registry = try store.guidRegistry()
        XCTAssertEqual(registry.entries[memory]?.name, "gEfiPeiMemoryDiscoveredPpiGuid")
        XCTAssertEqual(registry.entries[memory]?.source.file, "MdePkg/MdePkg.dec:2")
        XCTAssertEqual(registry.entries[memory]?.citations?.count, 1, "the record that agrees is cited")
        XCTAssertEqual(registry.entries[reset]?.name, "gAmdFactoryResetPpiGuid")
        XCTAssertEqual(registry.entries[reset]?.citations?.count, 2)
        XCTAssertNil(registry.entries[topology], "a GUID two reviews name two ways waits for a person")
    }
}
