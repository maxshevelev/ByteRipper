import XCTest
import Foundation
@testable import MEFirmware

/// `ManufacturingDecoder` — the End of Manufacturing verdict a bench reads off
/// a dump: the live `/home/mca/eom` record first (it says what the board has
/// done), then the setting (it says what the image will do on its first boot),
/// with the descriptor's state deciding whether the pair is one MFIT would ever
/// have built. The records' addresses and values are the ones in
/// `Skills/me-eom-structures/reference/structures.md`; the cases here are the
/// four dumps whose answers are known.
final class ManufacturingTests: XCTestCase {

    private func decide(image: Int? = nil, live: Int? = nil,
                        descriptorOpen: Bool? = nil, hasSwitch: Bool = true,
                        liveFilesResolved: Bool = true)
    -> (state: ManufacturingState, basis: ManufacturingBasis) {
        ManufacturingDecoder.decide(ManufacturingDecoder.Inputs(
            imageEOMConfig: image, liveEOMConfig: live,
            descriptorOpen: descriptorOpen, hasSwitch: hasSwitch,
            liveFilesResolved: liveFilesResolved))
    }

    /// Clean ME / no-EOM: the setting is clear, so the platform boots on with
    /// Manufacturing open. The dump that prompted the row.
    func testAClearSettingWillNotClose() {
        let (state, basis) = decide(image: 0x00, descriptorOpen: false)
        XCTAssertEqual(state, .willNotClose)
        XCTAssertEqual(basis.flag, false)
        XCTAssertEqual(basis.flexible, 0)
        XCTAssertEqual(basis.page, .imageConfiguration)
    }

    /// The same image built with MFIT's "EOM on first boot = Yes": byte 0 of
    /// the record is 1, which is the flag and nothing else.
    func testASetSettingWillClose() {
        let (state, basis) = decide(image: 0x01, descriptorOpen: false)
        XCTAssertEqual(state, .willClose)
        XCTAssertEqual(basis.flag, true)
    }

    /// What the board the dump came from has already done is not asked and not
    /// reported: `/home/mca/eom` in the live file system says Manufacturing was
    /// closed there, and that says nothing about the machine this image is
    /// about to be written to. The setting decides.
    func testTheBoardsOwnHistoryIsNotAVerdict() {
        let (state, basis) = decide(image: 0x01, live: 0x00, descriptorOpen: false)
        XCTAssertEqual(state, .willClose)
        XCTAssertEqual(basis.flag, true)
        XCTAssertEqual(basis.page, .imageConfiguration)
    }

    /// FlexibleEomSettings is the record's bits 1–2 (0 = lock the descriptor
    /// and the OEM configuration, 3 = lock neither).
    func testTheFlexibleSettingIsReadFromTheUpperBits() {
        XCTAssertEqual(decide(image: 0x03).basis.flexible, 1)
        XCTAssertEqual(decide(image: 0x05).basis.flexible, 2)
        XCTAssertEqual(decide(image: 0x07).basis.flexible, 3)
        XCTAssertEqual(decide(image: 0x07).basis.flag, true)
    }

    /// The flag set while the descriptor's BIOS master is open is the
    /// combination MFIT refuses to build, and gets its own verdict rather than
    /// being read as an ordinary "will close".
    func testTheFlagWithAnOpenDescriptorIsItsOwnVerdict() {
        let (state, basis) = decide(image: 0x01, descriptorOpen: true)
        XCTAssertEqual(state, .unexpectedCombination)
        XCTAssertEqual(basis.descriptorOpen, true)
    }

    /// Without a descriptor — an extracted ME region, which is how the engine
    /// is most often handed one — the check is left out and the setting decides.
    func testNoDescriptorLeavesTheCombinationCheckOut() {
        let (state, basis) = decide(image: 0x01, descriptorOpen: nil)
        XCTAssertEqual(state, .willClose)
        XCTAssertNil(basis.descriptorOpen)
    }

    /// A firmware of a generation without the switch: pre-CSME 15, or a layout
    /// whose records are not ID-keyed. Nothing is claimed from it.
    func testAFirmwareWithoutTheSwitch() {
        let (state, _) = decide(hasSwitch: false, liveFilesResolved: false)
        XCTAssertEqual(state, .noSwitch)
    }

    /// The switch exists but neither page could be read — an image whose file
    /// table is not in hand and whose OEM Configuration carries no such record.
    /// The honest answer is that nothing can be said, not that the vendor left
    /// it off.
    func testNoReadablePageIsUnknownNotAFlag() {
        let (state, basis) = decide(hasSwitch: true, liveFilesResolved: false)
        XCTAssertEqual(state, .unknown)
        XCTAssertNil(basis.flag)
        XCTAssertNil(basis.page)
    }

    /// An extracted region may carry the live records with no OEM Configuration
    /// partition beside them: the live page decides then, and says so.
    func testTheLivePageDecidesWhenTheImageCarriesNoRecord() {
        let (state, basis) = decide(live: 0x01)
        XCTAssertEqual(state, .willClose)
        XCTAssertEqual(basis.page, .liveMFS)
    }

    /// The image's own page wins over the live one for the setting: it is the
    /// record the platform applies when it enters End of Manufacturing, while
    /// the file system's copy is a leftover of a previous run.
    func testTheImagePageOutranksTheLiveOne() {
        let (state, basis) = decide(image: 0x01, live: 0x00)
        XCTAssertEqual(state, .willClose)
        XCTAssertEqual(basis.page, .imageConfiguration)
    }

    /// The File IDs are `FileTable.dat`'s own keys, the ones the panel's tree
    /// prints beside `/home/mca/eom` — a record with another ID is some other
    /// setting and must not be read as this one.
    func testTheFileIDsAreTheFTBLKeys() {
        XCTAssertEqual(ManufacturingDecoder.FileID.eom, 0x1002_0000)
        XCTAssertEqual(ManufacturingDecoder.FileID.eomConfig, 0x1001_EE00)
        XCTAssertEqual(ManufacturingDecoder.FileID.manufLock, 0x1002_0100)
    }
}

/// `BootGuardReader` — the Boot Guard profile out of the CDMD configuration's
/// JSON, and the OEM public key hash out of the UEP area.
final class BootGuardReaderTests: XCTestCase {

    // MARK: - The profile

    /// The record the Z Flow dump and the Legion dump carry: MFIT's index 3,
    /// which is profile 5.
    func testTheProfileIsMFITsIndexNotTheLevel() {
        let record = Data(#"{"BtGuardProfileConfig": 3}"#.utf8)
        XCTAssertEqual(BootGuardReader.profile(in: record), .fvme)
        XCTAssertEqual(BootGuardReader.profile(in: Data(#"{"BtGuardProfileConfig": 0}"#.utf8)), .noFVME)
        XCTAssertEqual(BootGuardReader.profile(in: Data(#"{"BtGuardProfileConfig": 1}"#.utf8)), .vm)
        XCTAssertEqual(BootGuardReader.profile(in: Data(#"{"BtGuardProfileConfig": 2}"#.utf8)), .fve)
    }

    /// Profile 4 was the case that settled where the profile lives: an image
    /// built as 4 differs from the same image built as 0 in this digit.
    func testProfileFour() {
        XCTAssertEqual(BootGuardReader.profile(in: Data(#"{"BtGuardProfileConfig": 2}"#.utf8)), .fve)
        XCTAssertEqual(BootGuardProfile.fve.rawValue, "4")
        XCTAssertEqual(BootGuardProfile.fve.index, 2)
    }

    /// The record sits among the configuration's other records, and a scan that
    /// looked at the first `{` it found would read the wrong one.
    func testTheRecordIsFoundAmongOthers() {
        let area = Data(#"{"length": 0}{"StrapsProject": "adp_p_straps.xml"}{"BtGuardProfileConfig": 2, "FpfSvnEnabled": 1}{"ResizeNftpForFtpr": "Enabled"}"#.utf8)
        XCTAssertEqual(BootGuardReader.profile(in: area), .fve)
    }

    /// An index outside MFIT's list is not a profile this engine can name.
    func testAnIndexOutsideTheListIsNoAnswer() {
        XCTAssertNil(BootGuardReader.profile(in: Data(#"{"BtGuardProfileConfig": 4}"#.utf8)))
        XCTAssertNil(BootGuardReader.profile(in: Data(#"{"BtGuardProfileConfig": 9}"#.utf8)))
    }

    /// An image whose configuration has no such record — the Lenovo dumps, and
    /// every CSME 15 one seen so far — answers nothing rather than 0.
    func testNoRecordIsNoAnswer() {
        XCTAssertNil(BootGuardReader.profile(in: Data(#"{"length": 0}"#.utf8)))
        XCTAssertNil(BootGuardReader.profile(in: Data()))
        XCTAssertNil(BootGuardReader.profile(in: Data(#"{"BtGuardProfileConfig"}"#.utf8)))
        XCTAssertNil(BootGuardReader.profile(in: Data(#"{"BtGuardProfileConfig": }"#.utf8)))
    }

    // MARK: - The OEM public key hash

    /// The Z Flow dump's own hash: a SHA-384 the UEP area holds six copies of,
    /// in two groups of three.
    private static let oemHash = "05C697663A75E912B7C4B553E885E1E4EF9AA04276C26A6630320A755AC90B1E0981C11D051A8C90D202D2E6FD3E8452"

    private func uep(holding hashHex: String, copies: Int,
                     filler: UInt8 = 0xFF) -> Data {
        var hash: [UInt8] = []
        var digits = Substring(hashHex)
        while digits.count >= 2 {
            let pair = digits.prefix(2)
            digits = digits.dropFirst(2)
            hash.append(UInt8(pair, radix: 16) ?? 0)
        }
        // One copy every 0x100 bytes, the spacing the real area's entries have,
        // inside a page big enough to hold them all.
        var area = Data(repeating: filler, count: 0x2000)
        for copy in 0..<copies {
            let at = 0x40 + copy * 0x100
            area.replaceSubrange(at..<(at + hash.count), with: Data(hash))
        }
        return area
    }

    func testTheHashIsFoundAndPrintedAsMFITPrintsIt() {
        let area = uep(holding: Self.oemHash, copies: 6)
        XCTAssertEqual(BootGuardReader.oemPublicKeyHash(in: area), Self.oemHash)
    }

    /// One copy is not the hash the area repeats: a value that appears once is
    /// as likely to be a pointer or a record's own bytes.
    func testASingleCopyIsNotAKey() {
        XCTAssertNil(BootGuardReader.oemPublicKeyHash(in: uep(holding: Self.oemHash, copies: 1)))
    }

    /// An erased area holds nothing, and must not be read as a key of zeroes.
    func testAnErasedAreaHasNoKey() {
        XCTAssertNil(BootGuardReader.oemPublicKeyHash(in: Data(repeating: 0xFF, count: 0x2000)))
    }

    /// A 48-byte run of zeroes — MFIT's "OEM signing is disabled" setting — is
    /// not claimed as a key: an unwritten area is full of them, and a 48-byte
    /// window of zeros repeats wherever the area is padding. The row says the
    /// image carries no key instead, and the help says what the two cases mean.
    func testAnAllZeroHashIsNotClaimed() {
        XCTAssertNil(BootGuardReader.oemPublicKeyHash(
            in: uep(holding: String(repeating: "0", count: 96), copies: 3, filler: 0x00)))
    }
}
