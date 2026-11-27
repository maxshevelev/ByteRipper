import Foundation
import XCTest
@testable import CodeAnalysis

/// The EC register registry (`ECRegisterFile`): one name per address or
/// interrupt per chip model, a version that rises only on a change, every
/// earlier state kept so the map at any version can be rebuilt, and the
/// offer rule — added, same, refined, confirmed, replaced, conflict.
final class ECRegisterRegistryTests: XCTestCase {
    private var directory: URL!
    private var store: ContentStore!
    private let module = SHA256Digest(data: Data("ItEcNmD562".utf8))
    private let chip = "it8227e"

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ECRegisterRegistryTests-\(UUID().uuidString)", isDirectory: true)
        store = try ContentStore(root: directory)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private var fw: ECRegisterEvidence { ECRegisterEvidence(module: module, addresses: ["0x3C5A"]) }

    private func offer(_ name: String, at address: UInt64 = 0xF01C00, width: Int = 1, description: String? = nil,
                       bits: [ECRegisterBit]? = nil, status: ECRegisterStatus = .firmware,
                       evidence: ECRegisterEvidence? = nil) -> ECRegisterOffer {
        ECRegisterOffer(kind: .register, number: address, name: name, width: width, block: "SMB",
                        description: description, bits: bits, status: status,
                        evidence: evidence ?? (status == .firmware ? fw : ECRegisterEvidence(text: "reads it")))
    }

    @discardableResult
    private func put(_ offer: ECRegisterOffer, replace: Bool = false, reason: String? = nil) throws -> ECRegisterOfferResult {
        try store.offerRegister(chip: chip, offer, by: "Agent", replace: replace, reason: reason)
    }

    private func version() throws -> Int { try store.registerFile(chip).version }

    func testAnAddressIsAddedAndTheSameNameIsNoChange() throws {
        XCTAssertEqual(try put(offer("SMB_HOSTA_A")).outcome, .added)
        XCTAssertEqual(try version(), 1)
        let same = try put(offer("SMB_HOSTA_A"))
        XCTAssertEqual(same.outcome, .same)
        XCTAssertEqual(try version(), 1, "no change, no version")
        XCTAssertEqual(try store.registerFile(chip).stamp, "it8227e@1")
    }

    func testDetailsTheEntryLackedRefineIt() throws {
        try put(offer("SMB_HOSTA_A"))
        let refined = try put(offer("SMB_HOSTA_A", description: "host status",
                                    bits: [ECRegisterBit(lsb: 0, name: "HOBY")]))
        XCTAssertEqual(refined.outcome, .refined)
        XCTAssertEqual(refined.entry.current.description, "host status")
        XCTAssertEqual(refined.entry.current.changedIn, 2)
        XCTAssertEqual(refined.entry.history?.first?.replacedIn, 2)
        XCTAssertEqual(try version(), 2)
    }

    func testAFirmwareOfferConfirmsAGuess() throws {
        try put(offer("SMB_HOSTA_A", status: .guess))
        let confirmed = try put(offer("SMB_HOSTA_A"))
        XCTAssertEqual(confirmed.outcome, .confirmed)
        XCTAssertEqual(confirmed.entry.current.status, .firmware)
        XCTAssertEqual(confirmed.entry.current.evidence?.module, module)
    }

    func testAGuessCorrectsAGuessesDetails() throws {
        try put(offer("SMB_HOSTA_A", description: "one thing", status: .guess))
        XCTAssertEqual(try put(offer("SMB_HOSTA_A", description: "another", status: .guess)).outcome, .refined)
    }

    func testAGuessWithEvidenceReplacesAnUnverifiedNameAtOnce() throws {
        try put(offer("SMB_4P7USL", status: .unverified, evidence: ECRegisterEvidence()))
        let replaced = try put(offer("SMB_HOSTA_A", status: .guess))
        XCTAssertEqual(replaced.outcome, .replaced)
        XCTAssertEqual(replaced.entry.current.name, "SMB_HOSTA_A")
        XCTAssertEqual(replaced.entry.history?.map(\.name), ["SMB_4P7USL"])
        XCTAssertEqual(replaced.entry.everNames, ["SMB_HOSTA_A", "SMB_4P7USL"])
    }

    func testFirmwareReplacesAGuessButAGuessDoesNot() throws {
        try put(offer("SMB_GUESS", status: .guess))
        XCTAssertEqual(try put(offer("SMB_OTHER", status: .guess)).outcome, .conflict)
        XCTAssertEqual(try put(offer("SMB_HOSTA_A")).outcome, .replaced)
    }

    func testAFirmwareEntryConflictsUnlessReplacedWithAReason() throws {
        try put(offer("SMB_HOSTA_A", description: "host status"))
        let before = try version()
        let conflict = try put(offer("SMB_STATUS_A"))
        XCTAssertEqual(conflict.outcome, .conflict)
        XCTAssertEqual(conflict.offered, "SMB_STATUS_A")
        XCTAssertEqual(conflict.entry.current.name, "SMB_HOSTA_A", "a conflict shows the entry as it stands")
        XCTAssertEqual(try put(offer("SMB_HOSTA_A", description: "other")).outcome, .conflict)
        XCTAssertEqual(try version(), before, "a conflict writes nothing")

        XCTAssertThrowsError(try put(offer("SMB_STATUS_A"), replace: true)) {
            XCTAssertTrue("\($0)".contains("reason"), "\($0)")
        }
        let replaced = try put(offer("SMB_STATUS_A"), replace: true, reason: "the datasheet says so")
        XCTAssertEqual(replaced.outcome, .replaced)
        XCTAssertEqual(replaced.entry.current.reason, "the datasheet says so")
        XCTAssertEqual(replaced.entry.history?.last?.name, "SMB_HOSTA_A")
    }

    func testRefusals() throws {
        func refused(_ offer: ECRegisterOffer, _ text: String, chip: String = "it8227e") {
            XCTAssertThrowsError(try store.offerRegister(chip: chip, offer, by: nil)) {
                XCTAssertTrue("\($0)".contains(text), "\($0)")
            }
        }
        refused(offer("A", width: 3), "width")
        refused(offer("A", at: 0xF20000), "window")
        refused(offer("A", bits: [ECRegisterBit(lsb: 0, width: 4, name: "X"), ECRegisterBit(lsb: 3, name: "Y")]), "overlaps")
        refused(offer("A", bits: [ECRegisterBit(lsb: 7, width: 2, name: "X")]), "does not fit")
        refused(offer("1BAD"), "identifier")
        refused(offer("A", status: .guess, evidence: ECRegisterEvidence()), "evidence")
        refused(offer("A", evidence: ECRegisterEvidence(text: "seen")), "module and the code")
        refused(offer("A"), "no register registry", chip: "it9999")
        try put(offer("SMB_HOSTA_A"))
        refused(offer("SMB_HOSTA_A", at: 0xF01C01), "already the name")
        XCTAssertThrowsError(try store.offerRegister(
            chip: chip, ECRegisterOffer(kind: .irq, number: 9, name: "SMB_A", width: 1, status: .unverified), by: nil))
    }

    func testAnUnverifiedNameElsewhereDoesNotHoldTheName() throws {
        let unverified = ECRegisterOffer(kind: .irq, number: 152, name: "SMB_E", status: .unverified)
        XCTAssertEqual(try put(unverified).outcome, .added)
        let firmware = ECRegisterOffer(kind: .irq, number: 160, name: "SMB_E", status: .firmware, evidence: fw)
        XCTAssertEqual(try put(firmware).outcome, .added)
    }

    func testTheMapAtAnyVersionIsRebuilt() throws {
        try put(offer("SMB_4P7USL", status: .unverified, evidence: ECRegisterEvidence()))   // 1
        try put(offer("SMB_HOCTL_A", at: 0xF01C01))                                           // 2
        try put(offer("SMB_HOSTA_A", status: .guess))                                         // 3
        try put(offer("SMB_HOSTA_A", description: "host status"))                             // 4
        let file = try store.registerFile(chip)
        XCTAssertEqual(file.version, 4)
        let key = ECRegisterFile.key(.register, 0xF01C00)
        XCTAssertEqual(key, "0x00F01C00")
        XCTAssertNil(file.state(.register, key, at: 0))
        XCTAssertEqual(file.state(.register, key, at: 1)?.name, "SMB_4P7USL")
        XCTAssertEqual(file.state(.register, key, at: 2)?.name, "SMB_4P7USL")
        XCTAssertEqual(file.state(.register, key, at: 3)?.status, .guess)
        XCTAssertEqual(file.state(.register, key, at: 4)?.description, "host status")
        XCTAssertEqual(file.map(.register, at: 1).count, 1)
        XCTAssertEqual(file.map(.register, at: 2).count, 2)
        XCTAssertEqual(file.everName("SMB_4P7USL", kind: .register), [key])
        XCTAssertEqual(file.everName("SMB_NONE", kind: .register), [])
    }

    func testARemovalKeepsTheEarlierMap() throws {
        try put(offer("SMB_HOSTA_A"))
        let key = ECRegisterFile.key(.register, 0xF01C00)
        XCTAssertThrowsError(try store.removeRegister(chip: chip, kind: .register, key: key, reason: "x",
                                                      expectName: "OTHER"))
        let dry = try store.removeRegister(chip: chip, kind: .register, key: "0xF01C00", reason: "wrong", dryRun: true)
        XCTAssertFalse(dry.applied)
        XCTAssertEqual(try version(), 1)
        _ = try store.removeRegister(chip: chip, kind: .register, key: key, reason: "wrong")
        let file = try store.registerFile(chip)
        XCTAssertEqual(file.version, 2)
        XCTAssertTrue(file.standing(.register).isEmpty)
        XCTAssertEqual(file.state(.register, key, at: 1)?.name, "SMB_HOSTA_A")
        XCTAssertNil(file.state(.register, key, at: 2))
        XCTAssertEqual(try put(offer("SMB_HOSTA_B")).outcome, .added, "an offer starts a removed entry again")
    }

    func testTheFileRoundTripsThroughJSON() throws {
        try put(offer("SMB_HOSTA_A", bits: [ECRegisterBit(lsb: 0, width: 2, name: "LV", meaning: "levels")]))
        try put(ECRegisterOffer(kind: .irq, number: 160, name: "SMB_E", status: .firmware, evidence: fw))
        let file = try store.registerFile(chip)
        let data = try JSONEncoder().encode(file)
        XCTAssertEqual(try JSONDecoder().decode(ECRegisterFile.self, from: data), file)
        let text = try String(contentsOf: store.registersURL.appendingPathComponent("it8227e.json"), encoding: .utf8)
        XCTAssertTrue(text.contains("\"changedIn\""), text)
        XCTAssertEqual(store.registerChips(), ["it8227e"])
    }

    func testAMirrorWritesOnlyAChange() throws {
        try put(offer("SMB_HOSTA_A"))
        let mirror = try ContentStore(root: directory.appendingPathComponent("mirror"))
        try mirror.mirrorRegisters(try store.registerFile(chip))
        let url = mirror.registersURL.appendingPathComponent("it8227e.json")
        let written = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        Thread.sleep(forTimeInterval: 0.05)
        try mirror.mirrorRegisters(try store.registerFile(chip))
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date, written,
                       "the same file is not written again")
        XCTAssertEqual(try mirror.registerFile(chip), try store.registerFile(chip))
    }
}
