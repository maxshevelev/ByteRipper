import XCTest
import Foundation
@testable import MEFirmware

/// `ManufacturingDecoder` — whether an image closes Manufacturing on the first
/// boot of a board. Two mechanisms decide it, and the descriptor's is the one
/// at work in a serial image: the flag `CsePlugin:EomNvar` is an explicit order
/// only MFIT sets, so a flag of 0 says nothing by itself. The cases here are the
/// dumps whose answers are known (`Skills/me-eom-structures/reference/
/// structures.md`), including the live records that confirm them: every dump
/// whose own file system reads `/home/mca/eom` = 1 — the board was closed —
/// is one this decoder answers `willClose`.
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

    /// A serial image: the flag is clear, the descriptor carries the factory
    /// rights, and the platform closes Manufacturing on its first boot. This is
    /// the case the row exists for — a clear flag is not "nothing will happen".
    func testAFactoryRightsImageClosesWithoutTheFlag() {
        let (state, basis) = decide(image: 0x00, descriptorOpen: false)
        XCTAssertEqual(state, .willClose)
        XCTAssertEqual(basis.flag, false)
        XCTAssertEqual(basis.flexible, 0)
        XCTAssertEqual(basis.page, .imageConfiguration)
    }

    /// The same image before its flag exists — a generation where only the
    /// descriptor decided, which is how End of Manufacturing was done before
    /// MFIT grew the setting.
    func testAGenerationWithoutTheFlagIsDecidedByTheDescriptor() {
        XCTAssertEqual(decide(descriptorOpen: false).state, .willClose)
    }

    /// A service image: the flag is clear *and* the descriptor is open, which is
    /// the one state in which nothing closes Manufacturing — the image a bench
    /// prepares for itself, and the one its own build of the clean ME is.
    func testAnOpenDescriptorWithAClearFlagClosesNothing() {
        let (state, basis) = decide(image: 0x00, descriptorOpen: true)
        XCTAssertEqual(state, .willNotClose)
        XCTAssertEqual(basis.flag, false)
    }

    /// The flag set is MFIT's explicit order: it closes Manufacturing whatever
    /// the descriptor says.
    func testASetFlagClosesEvenWithAFactoryDescriptor() {
        let (state, basis) = decide(image: 0x01, descriptorOpen: false)
        XCTAssertEqual(state, .willClose)
        XCTAssertEqual(basis.flag, true)
    }

    /// An image built by MFIT with the flag set and never booted: the file
    /// system carries no record, so the image's own page is the answer.
    func testTheImagePageIsTheFlagSourceWhenTheFileSystemIsEmpty() {
        let (state, basis) = decide(image: 0x01)
        XCTAssertEqual(state, .willClose)
        XCTAssertEqual(basis.page, .imageConfiguration)
    }

    /// An extracted region may be handed over without its OEM Configuration
    /// partition: the live record is then the only copy of the flag there is.
    func testTheLivePageIsTheFallbackForTheFlag() {
        let (state, basis) = decide(live: 0x01, descriptorOpen: false)
        XCTAssertEqual(state, .willClose)
        XCTAssertEqual(basis.page, .liveMFS)
    }

    /// The image's own page wins over the live one: it is the record the
    /// platform applies when it enters End of Manufacturing, while the file
    /// system's copy is a leftover of a previous run.
    func testTheImagePageOutranksTheLiveOne() {
        let (state, basis) = decide(image: 0x01, live: 0x00, descriptorOpen: false)
        XCTAssertEqual(state, .willClose)
        XCTAssertTrue(basis.flag == true)
        XCTAssertEqual(basis.page, .imageConfiguration)
    }

    /// The flag set with the descriptor open is the combination MFIT refuses
    /// to build ("not allowed"), and gets its own verdict rather than being
    /// read as an ordinary "will close".
    func testTheFlagWithAnOpenDescriptorIsItsOwnVerdict() {
        let (state, basis) = decide(image: 0x01, descriptorOpen: true)
        XCTAssertEqual(state, .unexpectedCombination)
        XCTAssertEqual(basis.descriptorOpen, true)
    }

    /// FlexibleEomSettings is the record's bits 1–2 (0 = lock the descriptor
    /// and the OEM configuration, 3 = lock neither).
    func testTheFlexibleSettingIsReadFromTheUpperBits() {
        XCTAssertEqual(decide(image: 0x03).basis.flexible, 1)
        XCTAssertEqual(decide(image: 0x05).basis.flexible, 2)
        XCTAssertEqual(decide(image: 0x07).basis.flexible, 3)
        XCTAssertEqual(decide(image: 0x07).basis.flag, true)
    }

    /// A firmware of a generation that does not decide this: nothing is
    /// claimed, whatever the descriptor says.
    func testAFirmwareWithoutTheMachinery() {
        let (state, _) = decide(descriptorOpen: false, hasSwitch: false,
                                liveFilesResolved: false)
        XCTAssertEqual(state, .noSwitch)
    }

    /// A region handed to the engine with no descriptor — a bare ME dump — and
    /// no flag: the question cannot be answered, and it is not guessed.
    func testNoDescriptorAndNoFlagIsUnknown() {
        let (state, basis) = decide(image: 0x00, descriptorOpen: nil)
        XCTAssertEqual(state, .unknown)
        XCTAssertEqual(basis.flag, false)
        XCTAssertNil(basis.descriptorOpen)
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

    /// An image whose configuration has no such record — the old CSME 16
    /// layouts, and every CSME 15 one — answers nothing rather than 0.
    func testNoRecordIsNoAnswer() {
        XCTAssertNil(BootGuardReader.profile(in: Data(#"{"length": 0}"#.utf8)))
        XCTAssertNil(BootGuardReader.profile(in: Data()))
        XCTAssertNil(BootGuardReader.profile(in: Data(#"{"BtGuardProfileConfig"}"#.utf8)))
        XCTAssertNil(BootGuardReader.profile(in: Data(#"{"BtGuardProfileConfig": }"#.utf8)))
    }

    // MARK: - The profile out of the UEP area

    /// A UEP container as the images carry it: the signature, a checksum that
    /// is not zero, and the four Boot Guard bits of the first bit array — the
    /// byte at +0x6E, bits 0, 3, 4 and 5 (FBG ACM, protect, measured,
    /// verified) — with the key-manifest id of the images at hand beside them.
    private func uepArea(flags: UInt8) -> Data {
        var area = [UInt8](repeating: 0x00, count: 0x200)
        let at = 0x20
        area.replaceSubrange(at..<(at + 4), with: Array("$UEP".utf8))
        area[at + 4] = 0x1D                       // the 16-bit CRC's low byte
        area[at + 5] = 0x8B                       // …and its high byte
        area[at + 0x6C - 4] = 0x72                // the array's own header word
        area[at + 0x6E] = flags
        return Data(area)
    }

    /// The three builds of one image — whose FIT `.xml` readings differ in this
    /// setting and nothing else — and the byte each of them carries. Profile 0
    /// is the two boards: 0x40 and 0x42 are both all four flags zero, and the
    /// bit that tells them apart is the debug switch, not a profile.
    func testTheProfileIsTheCombinationOfFourBits() {
        XCTAssertEqual(BootGuardReader.profile(inUEPArea: uepArea(flags: 0x40)), .noFVME)
        XCTAssertEqual(BootGuardReader.profile(inUEPArea: uepArea(flags: 0x42)), .noFVME)
        XCTAssertEqual(BootGuardReader.profile(inUEPArea: uepArea(flags: 0x7A)), .vm)
        XCTAssertEqual(BootGuardReader.profile(inUEPArea: uepArea(flags: 0x6B)), .fve)
        XCTAssertEqual(BootGuardReader.profile(inUEPArea: uepArea(flags: 0x7B)), .fvme)
    }

    /// An area never written — a cleanME image, a CSME 12 image whose UEP
    /// partition is blank — is not profile 0 or 5: as bits, all zeros answer
    /// No_FVME and all ones answer FVME, and nothing was chosen there. What
    /// says an area is written is its body, not its signature: the blank
    /// CSME 12 partition carries the signature too.
    func testAnErasedAreaAnswersNothing() {
        var erased = uepArea(flags: 0xFF)
        erased.replaceSubrange(erased.startIndex..<erased.endIndex,
                               with: Data(repeating: 0xFF, count: 0x200))
        XCTAssertNil(BootGuardReader.profile(inUEPArea: erased))
        var blank = uepArea(flags: 0x00)
        blank.replaceSubrange((blank.startIndex + 0x20 + 4)..<(blank.startIndex + 0x20 + 0x80),
                              with: Data(repeating: 0x00, count: 0x7C))
        XCTAssertNil(BootGuardReader.profile(inUEPArea: blank))
        XCTAssertNil(BootGuardReader.profile(inUEPArea: Data(repeating: 0x00, count: 0x200)))
    }

    /// A container of another structure behind the same signature is not a
    /// blank one: a CSME 12 image's UEP partition has its own bytes where its
    /// own layout puts them, and nothing at all where the Boot Guard flags are.
    /// Its four bits read zero, and zeroes are not a profile here either.
    func testAnotherStructureBehindTheSameSignature() {
        var area = [UInt8](repeating: 0x00, count: 0x200)
        let at = 0x20
        area.replaceSubrange(at..<(at + 4), with: Array("$UEP".utf8))
        area[at + 4] = 0x16
        area[at + 5] = 0xE2                       // the CRC the CSME 12 image carries
        area.replaceSubrange((at + 0x28)..<(at + 0x34),
                             with: [0xFF, 0xFF, 0xCF, 0xCC, 0x00, 0xF0,
                                    0xFC, 0xCC, 0xC0, 0x00, 0x00, 0x00])
        area[at + 0x48] = 0x80
        XCTAssertNil(BootGuardReader.profile(inUEPArea: Data(area)))
    }

    /// A combination no profile names, and an area with no container at all:
    /// neither is turned into the nearest profile.
    func testWhatTheTableDoesNotNameIsNoAnswer() {
        XCTAssertNil(BootGuardReader.profile(inUEPArea: uepArea(flags: 0x01)))
        XCTAssertNil(BootGuardReader.profile(inUEPArea: uepArea(flags: 0x0B)))
        XCTAssertNil(BootGuardReader.profile(inUEPArea: Data()))
        XCTAssertNil(BootGuardReader.profile(inUEPArea: Data("nothing here".utf8)))
        XCTAssertNil(BootGuardReader.profile(inUEPArea: Data("$UEP".utf8)))
    }

    // MARK: - The profile out of the CSME 12 to 14 UEP area

    private func little(_ value: UInt32) -> [UInt8] {
        [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF),
         UInt8((value >> 16) & 0xFF), UInt8((value >> 24) & 0xFF)]
    }

    /// A CSME 12 to 14 container as the images carry it: the signature, the
    /// record's source pointer, the mask at +0x34 — 0xCC where the ACM is off
    /// and 0xFF where it is on, which is what the flags' own bit 0 says unless
    /// a test overrides it — and the flags byte in each of the record's three
    /// copies. The image's own bits around the four settings are 0x46.
    private func earlierUEPArea(flags: UInt8, mask: UInt32? = nil,
                                source: UInt32 = 0x5A_C080,
                                copies: [UInt8]? = nil) -> Data {
        var area = [UInt8](repeating: 0x00, count: 0x200)
        let at = 0x20
        area.replaceSubrange(at..<(at + 4), with: Array("$UEP".utf8))
        area[at + 4] = 0x55                       // the checksum's low byte
        area[at + 5] = 0x09                       // …and its high byte
        area.replaceSubrange((at + 0x28)..<(at + 0x34),
                             with: [0xFF, 0xFF, 0xCF, 0x0C, 0xCC, 0xCC,
                                    0xCC, 0x00, 0xC0, 0x00, 0x00, 0x00])
        let maskValue = mask ?? (flags & 0x01 != 0 ? 0xFF : 0xCC)
        area.replaceSubrange((at + 0x34)..<(at + 0x38), with: little(maskValue))
        area.replaceSubrange((at + 0x48)..<(at + 0x4C), with: little(source))
        for (index, offset) in [0x4C, 0xE8, 0x178].enumerated() {
            area[at + offset] = copies?[index] ?? flags
        }
        return Data(area)
    }

    /// The four FIT 14.0 builds of one CSME 14 image — whose `.xml` readings
    /// differ in `BtGuardProfileConfig` and nothing else, and whose bytes in
    /// five of sixteen million: the flags byte of each of the record's three
    /// copies, the mask whose word says the ACM is on, and the container's
    /// checksum. The image's own bits are 0x46, and the three profiles set
    /// 0x38, 0x29 and 0x39 of them.
    func testTheEarlierContainerNamesTheSameFourProfiles() {
        XCTAssertEqual(BootGuardReader.profile(inRecordUEPArea: earlierUEPArea(flags: 0x46),
                                               major: 14), .noFVME)
        XCTAssertEqual(BootGuardReader.profile(inRecordUEPArea: earlierUEPArea(flags: 0x7E),
                                               major: 14), .vm)
        XCTAssertEqual(BootGuardReader.profile(inRecordUEPArea: earlierUEPArea(flags: 0x6F),
                                               major: 14), .fve)
        XCTAssertEqual(BootGuardReader.profile(inRecordUEPArea: earlierUEPArea(flags: 0x7F),
                                               major: 14), .fvme)
        // The vendor images' own bits: the ACM bit and the debug switches sit
        // in the same byte, and 0xF9 is the four settings with both of those.
        XCTAssertEqual(BootGuardReader.profile(inRecordUEPArea: earlierUEPArea(flags: 0xF9),
                                               major: 14), .fvme)
        // CSME 12 is the same shape, read with the same layout.
        XCTAssertEqual(BootGuardReader.profile(inRecordUEPArea: earlierUEPArea(flags: 0x46),
                                               major: 12), .noFVME)
    }

    /// What the earlier reader refuses. None of it is a profile, and none of it
    /// becomes the nearest one.
    func testTheEarlierContainerIsNotGuessedAt() {
        // An area never written. Its flags are all ones — which as a
        // combination is profile 5 — and what says it is not one is the mask
        // and the source pointer, both erased with the rest.
        var erased = [UInt8](repeating: 0xFF, count: 0x200)
        erased.replaceSubrange(0x20..<0x24, with: Array("$UEP".utf8))
        XCTAssertNil(BootGuardReader.profile(inRecordUEPArea: Data(erased), major: 14))
        // The later generations' container: the same signature, all zero where
        // the mask and the record are (a CSME 15 image read as if it were 12–14).
        XCTAssertNil(BootGuardReader.profile(inRecordUEPArea: uepArea(flags: 0x7B), major: 14))
        // Ice Lake's container read as CSME 12–14's: its mask is elsewhere.
        XCTAssertNil(BootGuardReader.profile(inRecordUEPArea: iceLakeUEPArea(flags: 0x79),
                                             major: 14))
        // A mask that does not say what the flags' ACM bit says.
        XCTAssertNil(BootGuardReader.profile(inRecordUEPArea:
            earlierUEPArea(flags: 0x7F, mask: 0xCC), major: 14))
        XCTAssertNil(BootGuardReader.profile(inRecordUEPArea:
            earlierUEPArea(flags: 0x46, mask: 0xFF), major: 14))
        // A mask of another shape, and one erased on its own.
        XCTAssertNil(BootGuardReader.profile(inRecordUEPArea:
            earlierUEPArea(flags: 0x7F, mask: 0x0F), major: 14))
        XCTAssertNil(BootGuardReader.profile(inRecordUEPArea:
            earlierUEPArea(flags: 0x7F, mask: 0xFFFF_FFFF), major: 14))
        // A record that points nowhere: both fills, and a body written with
        // zeroes, whose flags would read as No_FVME.
        XCTAssertNil(BootGuardReader.profile(inRecordUEPArea:
            earlierUEPArea(flags: 0x7F, source: 0), major: 14))
        XCTAssertNil(BootGuardReader.profile(inRecordUEPArea:
            earlierUEPArea(flags: 0x7F, source: 0xFFFF_FFFF), major: 14))
        XCTAssertNil(BootGuardReader.profile(inRecordUEPArea:
            Data(repeating: 0x00, count: 0x200), major: 14))
        // The record's copies disagreeing means these offsets are not this
        // image's layout.
        XCTAssertNil(BootGuardReader.profile(inRecordUEPArea:
            earlierUEPArea(flags: 0x7F, copies: [0x7F, 0x7F, 0x7E]), major: 14))
        // A combination no profile names, and no container at all.
        XCTAssertNil(BootGuardReader.profile(inRecordUEPArea: earlierUEPArea(flags: 0x31),
                                             major: 14))
        XCTAssertNil(BootGuardReader.profile(inRecordUEPArea: Data(), major: 14))
        XCTAssertNil(BootGuardReader.profile(inRecordUEPArea: Data("nothing here".utf8),
                                             major: 14))
    }

    // MARK: - The profile out of the CSME 13 UEP area

    /// An Ice Lake container as the NM-C711 builds carry it: the container's
    /// policy words at +0x30, the mask at +0x40 (0xC0CC with the ACM off and
    /// 0xC0FF with it on, which is what the flags' own bit 0 says unless a test
    /// overrides it, and 0xC0 above it), the record's source pointer at +0x60
    /// and the flags byte at +0x64, +0x150 and +0x22C. The image's own bits
    /// around the four settings are 0x40, not 0x46 as on CSME 12–14.
    private func iceLakeUEPArea(flags: UInt8, mask: UInt32? = nil,
                                source: UInt32 = 0x5A_E080,
                                copies: [UInt8]? = nil) -> Data {
        var area = [UInt8](repeating: 0x00, count: 0x300)
        let at = 0x20
        area.replaceSubrange(at..<(at + 4), with: Array("$UEP".utf8))
        area[at + 4] = 0xF7                       // the checksum's low byte
        area[at + 5] = 0x2D                       // …and its high byte
        area.replaceSubrange((at + 0x34)..<(at + 0x40),
                             with: [0xFF, 0xFF, 0xCF, 0x0C, 0xFF, 0xC0,
                                    0x0C, 0x00, 0xC0, 0x00, 0x00, 0x00])
        let maskValue = mask ?? (flags & 0x01 != 0 ? 0xC0FF : 0xC0CC)
        area.replaceSubrange((at + 0x40)..<(at + 0x44), with: little(maskValue))
        area.replaceSubrange((at + 0x60)..<(at + 0x64), with: little(source))
        for (index, offset) in [0x64, 0x150, 0x22C].enumerated() {
            area[at + offset] = copies?[index] ?? flags
        }
        return Data(area)
    }

    /// The four FIT 13.0 builds of the NM-C711 dump — the `.xml` readings differ
    /// in `BtGuardProfileConfig` and nothing else, and the bytes in six of
    /// sixteen million: the container's checksum, the mask, and the flags byte of
    /// each of the record's three copies. The image's own bits are 0x40 and the
    /// three profiles turn on the same 0x38, 0x29 and 0x39 as every other
    /// generation.
    func testTheIceLakeContainerNamesTheSameFourProfiles() {
        XCTAssertEqual(BootGuardReader.profile(inRecordUEPArea: iceLakeUEPArea(flags: 0x40),
                                               major: 13), .noFVME)
        XCTAssertEqual(BootGuardReader.profile(inRecordUEPArea: iceLakeUEPArea(flags: 0x78),
                                               major: 13), .vm)
        XCTAssertEqual(BootGuardReader.profile(inRecordUEPArea: iceLakeUEPArea(flags: 0x69),
                                               major: 13), .fve)
        XCTAssertEqual(BootGuardReader.profile(inRecordUEPArea: iceLakeUEPArea(flags: 0x79),
                                               major: 13), .fvme)
    }

    /// What the Ice Lake reader refuses: the same guards, and the other
    /// generation's containers answered with nothing rather than a profile.
    func testTheIceLakeContainerIsNotGuessedAt() {
        var erased = [UInt8](repeating: 0xFF, count: 0x300)
        erased.replaceSubrange(0x20..<0x24, with: Array("$UEP".utf8))
        XCTAssertNil(BootGuardReader.profile(inRecordUEPArea: Data(erased), major: 13))
        // CSME 12–14's container and the 15/16 one behind the same signature.
        XCTAssertNil(BootGuardReader.profile(inRecordUEPArea: earlierUEPArea(flags: 0x7F),
                                             major: 13))
        XCTAssertNil(BootGuardReader.profile(inRecordUEPArea: uepArea(flags: 0x7B), major: 13))
        // A mask that does not say what the flags' ACM bit says, and a mask of
        // another word.
        XCTAssertNil(BootGuardReader.profile(inRecordUEPArea:
            iceLakeUEPArea(flags: 0x79, mask: 0xC0CC), major: 13))
        XCTAssertNil(BootGuardReader.profile(inRecordUEPArea:
            iceLakeUEPArea(flags: 0x40, mask: 0xC0FF), major: 13))
        XCTAssertNil(BootGuardReader.profile(inRecordUEPArea:
            iceLakeUEPArea(flags: 0x79, mask: 0xCC), major: 13))
        XCTAssertNil(BootGuardReader.profile(inRecordUEPArea:
            iceLakeUEPArea(flags: 0x79, source: 0), major: 13))
        XCTAssertNil(BootGuardReader.profile(inRecordUEPArea:
            iceLakeUEPArea(flags: 0x79, source: 0xFFFF_FFFF), major: 13))
        XCTAssertNil(BootGuardReader.profile(inRecordUEPArea:
            Data(repeating: 0x00, count: 0x300), major: 13))
        XCTAssertNil(BootGuardReader.profile(inRecordUEPArea:
            iceLakeUEPArea(flags: 0x79, copies: [0x79, 0x79, 0x78]), major: 13))
        XCTAssertNil(BootGuardReader.profile(inRecordUEPArea: iceLakeUEPArea(flags: 0x31),
                                             major: 13))
    }

    // MARK: - The OEM public key hash

    /// The Z Flow dump's own hash: a SHA-384 that sits 0xA0 bytes into the UEP
    /// area's entry, and again 0x10A0 in where the area has its second half.
    private static let oemHash = "05C697663A75E912B7C4B553E885E1E4EF9AA04276C26A6630320A755AC90B1E0981C11D051A8C90D202D2E6FD3E8452"

    /// An area with one entry: a container at 0x20, the key field of each half
    /// at its established offset, everything else erased — which is what a UEP
    /// area looks like (`/home/mca` aside, nothing else of it).
    private func uep(first: Data?, second: Data?,
                     container: String = "$UEPC") -> Data {
        var area = Data(repeating: 0xFF, count: 0x2000)
        let signature = Data(container.utf8)
        area.replaceSubrange(0x20..<(0x20 + signature.count), with: signature)
        for (half, field) in [(0, first), (0x1000, second)] {
            guard let field else { continue }
            let at = 0x20 + 0xA0 + half
            area.replaceSubrange(at..<(at + field.count), with: field)
        }
        return area
    }

    private func hashBytes(_ hex: String) -> Data {
        var bytes: [UInt8] = []
        var digits = Substring(hex)
        while digits.count >= 2 {
            bytes.append(UInt8(digits.prefix(2), radix: 16) ?? 0)
            digits = digits.dropFirst(2)
        }
        return Data(bytes)
    }

    func testTheKeyIsReadOutOfTheEntrysField() {
        let key = hashBytes(Self.oemHash)
        XCTAssertEqual(BootGuardReader.oemPublicKeyHash(in: uep(first: key, second: key), major: 15),
                       .hash(Self.oemHash))
        // The older generations write one half only — the second is erased, and
        // the key is still there.
        XCTAssertEqual(BootGuardReader.oemPublicKeyHash(in: uep(first: key, second: nil), major: 15),
                       .hash(Self.oemHash))
        XCTAssertEqual(BootGuardReader.oemPublicKeyHash(
            in: uep(first: key, second: Data(repeating: 0xFF, count: 48)), major: 15),
                       .hash(Self.oemHash))
        // An area whose first half was never written but whose second was.
        XCTAssertEqual(BootGuardReader.oemPublicKeyHash(
            in: uep(first: Data(repeating: 0xFF, count: 48), second: key), major: 15),
                       .hash(Self.oemHash))
    }

    /// A field of zeros is MFIT's own "OEM signing is disabled" — a finding, not
    /// a missing reading. CSME 12 and a cleaned CSME 16.1 image answer this.
    func testAZeroedFieldSaysSigningIsDisabled() {
        XCTAssertEqual(BootGuardReader.oemPublicKeyHash(
            in: uep(first: Data(repeating: 0x00, count: 48), second: nil), major: 15), .allZeros)
    }

    /// An erased field is an area never written.
    func testAnErasedFieldIsItsOwnFinding() {
        XCTAssertEqual(BootGuardReader.oemPublicKeyHash(in: uep(first: nil, second: nil), major: 15),
                       .erased)
    }

    /// A field holding something that is not a key — a pointer, a length, a
    /// record header — is a layout this reader does not walk, and says so
    /// rather than printing those bytes as a key.
    func testAFieldThatIsNotAKeyIsNotReadAsOne() {
        var pointer = Data(repeating: 0x00, count: 48)
        pointer[0] = 0x02; pointer[1] = 0x40; pointer[2] = 0x3E; pointer[3] = 0x86
        XCTAssertEqual(BootGuardReader.oemPublicKeyHash(in: uep(first: pointer, second: nil), major: 15),
                       .unrecognized)
    }

    /// Two halves carrying different keys mean the offsets are not this image's
    /// layout: a key is per vendor, and an image has one.
    func testDisagreeingHalvesAreNotAKey() {
        let other = hashBytes(String(Self.oemHash.dropFirst(2)) + "05")
        XCTAssertEqual(BootGuardReader.oemPublicKeyHash(
            in: uep(first: hashBytes(Self.oemHash), second: other), major: 15), .unrecognized)
    }

    // MARK: - The key of the older generations (CSME 12 to 14)

    /// A CSME 12 to 14 area as the dumps carry one: the container, the policy
    /// bytes the family keeps ahead of everything else, a 32-byte hash 0x90 in
    /// and the 16 bytes of assignment bits behind it.
    private func olderUEP(_ hash: Data?, assigned: UInt8 = 0x00) -> Data {
        var area = Data(repeating: 0xFF, count: 0x2000)
        let signature = Data("$UEP".utf8)
        area.replaceSubrange(0x20..<(0x20 + signature.count), with: signature)
        area.replaceSubrange(0x28..<0x30,
                             with: Data([0xFF, 0xFF, 0xCF, 0x0C, 0xFF, 0xCC, 0xCC, 0x00]))
        if let hash {
            area.replaceSubrange((0x20 + 0x90)..<(0x20 + 0x90 + hash.count), with: hash)
        }
        if assigned != 0x00 {
            area.replaceSubrange((0x20 + 0xB0)..<(0x20 + 0xC0),
                                 with: Data(repeating: assigned, count: 16))
        }
        return area
    }

    /// The reading the five CSME 14 boards settled: a 32-byte SHA-256 at +0x90.
    /// The known 48-byte hash's first 32 bytes stand in for one.
    private static let olderHash = String(oemHash.prefix(64))

    func testTheOlderGenerationsKeyIsThirtyTwoBytesAtNinety() {
        let hash = hashBytes(Self.olderHash)
        for major in [12, 13, 14] {
            XCTAssertEqual(BootGuardReader.oemPublicKeyHash(in: olderUEP(hash), major: major),
                           .hash(Self.olderHash))
        }
    }

    /// The 16 bytes behind the hash are the assignment bits, not part of it: the
    /// same key with them set reads as the same key.
    func testTheAssignmentBitsBehindTheHashAreNotPartOfIt() {
        let hash = hashBytes(Self.olderHash)
        XCTAssertEqual(BootGuardReader.oemPublicKeyHash(in: olderUEP(hash, assigned: 0xFF), major: 14),
                       .hash(Self.olderHash))
    }

    /// And a zeroed or erased field is the same finding it is on the newer
    /// layouts: signing disabled, or an area never written.
    func testTheOlderLayoutSaysWhatABlankFieldHolds() {
        XCTAssertEqual(BootGuardReader.oemPublicKeyHash(
            in: olderUEP(Data(repeating: 0x00, count: 32)), major: 14), .allZeros)
        XCTAssertEqual(BootGuardReader.oemPublicKeyHash(in: olderUEP(nil), major: 14), .erased)
    }

    /// The generation decides which record is read, and reading the wrong one
    /// gives nothing rather than half a key: a CSME 14 area read as a 15 starts
    /// on the second half of the hash and runs into its trailing bytes, and a
    /// CSME 15 area read as a 14 starts on the zeroes ahead of the key.
    func testEachGenerationIsReadWithItsOwnRecord() {
        let older = olderUEP(hashBytes(Self.olderHash))
        XCTAssertEqual(BootGuardReader.oemPublicKeyHash(in: older, major: 15), .unrecognized)
        let newer = uep(first: hashBytes(Self.oemHash), second: nil)
        XCTAssertEqual(BootGuardReader.oemPublicKeyHash(in: newer, major: 14), .unrecognized)
    }

    /// No container, no entry to read — CSME 11 has no such area at all.
    func testNoContainerIsNoLayout() {
        XCTAssertEqual(BootGuardReader.oemPublicKeyHash(
            in: Data(repeating: 0xFF, count: 0x2000), major: 15), .unrecognized)
        XCTAssertEqual(BootGuardReader.oemPublicKeyHash(in: Data(), major: 15), .unrecognized)
    }

    /// The board's own byte: 1 locked, 0 open, anything else a layout the
    /// reading does not know.
    func testTheBoardsLockByteIsReadAsAState() {
        XCTAssertEqual(ManufacturingDecoder.lock(0), .open)
        XCTAssertEqual(ManufacturingDecoder.lock(1), .locked)
        XCTAssertEqual(ManufacturingDecoder.lock(2), .other(2))
        XCTAssertEqual(ManufacturingDecoder.lock(0xFF), .other(0xFF))
    }
}
