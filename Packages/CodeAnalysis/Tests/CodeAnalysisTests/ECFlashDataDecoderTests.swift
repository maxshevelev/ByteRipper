@testable import CodeAnalysis
import Foundation
import XCTest

/// The flash data area read through a review's rows and types.
final class ECFlashDataDecoderTests: XCTestCase {
    private func type(_ name: String, _ kind: String, _ size: Int, _ c: String) -> (String, String) { (name, c) }

    func testALogIsReadSlotBySlotWithTheReviewsWords() throws {
        let codes = type("EC_EVENT_CODE", "typedef", 1, """
            typedef enum _EC_EVENT_CODE {
                EcEventThermal = 0x20, // logged by ThermalTrip 0x1234 on an overheat
                EcEventPowerOn = 0xFC, // logged at power-on
                EcEventSignExtended = 0xFFFFFFAA // a byte's 0xAA as Ghidra keeps it
            } EC_EVENT_CODE;
            """)
        let record = type("EFLASH_EVENT_LOG_RECORD", "typedef", 4, """
            typedef struct _EFLASH_EVENT_LOG_RECORD {
                /* 0x00 */ UINT8 SlotOffset; // its own offset
                /* 0x01 */ EC_EVENT_CODE EventCode; // what happened
                /* 0x02 */ UINT8 TempCpu; // CPU temperature, degrees C
                /* 0x03 */ UINT8 TempGpu;
            } /* size 0x4 */ EFLASH_EVENT_LOG_RECORD;
            """)
        let setting = type("EFLASH_STARTUP_SETTING", "typedef", 1, """
            typedef struct _EFLASH_STARTUP_SETTING {
                /* 0x00 */ uchar Unused0 : 7;
                /* 0x00 */ uchar Setting : 1; // 1: start on AC
            } /* size 0x1 */ EFLASH_STARTUP_SETTING;
            """)
        let records = ModuleRecords(["eflash_area": .init(status: .complete, rows: [
                ["address": .string("0x10"), "size": .int(12), "format": .string("EFLASH_EVENT_LOG_RECORD[3]"),
                 "label": .string("Event log"), "writers": .array([.string("0x144B0")])],
                ["address": .string("0x20"), "size": .int(1), "format": .string("EFLASH_STARTUP_SETTING")]])])
        var bytes = [UInt8](repeating: 0xFF, count: 0x30)
        bytes[0x10..<0x18] = [0x00, 0xFC, 0x2D, 0x30, 0x04, 0x77, 0x41, 0x42]
        bytes[0x18..<0x1A] = [0x08, 0xAA]
        bytes[0x20] = 0x80
        let areas = ECFlashDataDecoder.decode(records: records, types: Dictionary(uniqueKeysWithValues: [codes, record, setting]), bytes: Data(bytes))
        XCTAssertEqual(areas.count, 2)
        let log = areas[0]
        XCTAssertEqual(log.elements.count, 3)
        XCTAssertEqual(log.elements[0].fields[1].member, "EcEventPowerOn")
        XCTAssertEqual(log.elements[0].fields[1].memberComment, "logged at power-on")
        XCTAssertEqual(log.elements[0].fields[2].comment, "CPU temperature, degrees C")
        XCTAssertEqual(log.elements[0].fields[2].value, 0x2D)
        XCTAssertNil(log.elements[1].fields[1].member, "0x77 is not in the review")
        XCTAssertTrue(log.elements[1].fields[1].isEnum)
        XCTAssertEqual(log.elements[2].fields[1].member, "EcEventSignExtended")
        XCTAssertEqual(log.writers, ["0x144B0"])
        XCTAssertEqual(areas[1].elements[0].fields.map { $0.value }, [0, 1], "bit 7 is the setting")
        XCTAssertEqual(areas[1].elements[0].fields[1].comment, "1: start on AC")
    }

    /// The published review of NM-D562 over a real chip read, when the
    /// environment names them (`EC_STORE_ROOT`, `EC_CHIP`).
    func testARealChipRead() throws {
        let env = ProcessInfo.processInfo.environment
        guard let root = env["EC_STORE_ROOT"], let chip = env["EC_CHIP"] else { throw XCTSkip("no store or chip read") }
        let store = try ContentStore(root: URL(fileURLWithPath: root), create: false)
        let module = try XCTUnwrap(SHA256Digest(hex: "889159a794a3015e5547312b224db1f43c76daeddb90069ee856e32b6eac2b39"))
        let manifest = try XCTUnwrap(try store.analysis(module: module))
        let records = try store.moduleRecords(for: manifest)
        let areas = ECFlashDataDecoder.decode(records: records, types: try store.reviewTypes(for: manifest) ?? [:],
                                              bytes: try Data(contentsOf: URL(fileURLWithPath: chip)))
        for area in areas {
            print("AREA", String(area.address, radix: 16), area.format, area.problem ?? "", area.erased)
            for element in area.elements.prefix(40) where !element.free {
                print("  ", element.index ?? -1, element.raw.map { String(format: "%02X", $0) }.joined(separator: " "),
                      element.fields.map { "\($0.name)=\(String($0.value, radix: 16)) \($0.member ?? ($0.isEnum ? "NOT-IN-REVIEW" : "-"))" }.joined(separator: " | "))
            }
        }
        XCTAssertFalse(areas.isEmpty)
    }
}
