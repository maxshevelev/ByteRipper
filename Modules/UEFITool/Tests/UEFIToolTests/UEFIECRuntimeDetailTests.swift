@testable import CodeAnalysis
import Localization
@testable import UEFITool
import UEFIImage
import XCTest

/// The run-time data tables say only what the review says.
final class UEFIECRuntimeDetailTests: XCTestCase {
    func testALogShowsWrittenSlotsWithTheReviewsWords() {
        let used = ECFlashDataDecoder.Element(index: 0, offset: 0x2B800, raw: [0, 0xFC, 0x2D, 0], free: false, fields: [
            .init(name: "SlotOffset", type: "UINT8", value: 0, bits: nil, comment: nil, member: nil,
                  memberComment: nil, isEnum: false),
            .init(name: "EventCode", type: "EC_EVENT_CODE", value: 0xFC, bits: nil, comment: "what happened",
                  member: "EvtPowerOn", memberComment: "logged at power-on", isEnum: true)])
        var unknown = used
        unknown.index = 1
        unknown.fields[1].value = 0x77
        unknown.fields[1].member = nil
        unknown.fields[1].memberComment = nil
        var free = used
        free.index = 2
        free.free = true
        let area = ECFlashDataDecoder.Area(address: 0x2B800, size: 12, label: nil, format: "R[3]", meaning: nil,
                                           note: nil, confidence: "established", writers: ["0x144B0"], readers: [],
                                           elements: [used, unknown, free], problem: nil, erased: false)
        let table = UEFIECRuntimeDetail.tables(.decoded([area]), in: .english)[0]
        XCTAssertEqual(table.columns, ["Slot", "SlotOffset", "EventCode", "Bytes"])
        XCTAssertEqual(table.rows.count, 2, "the free slot is counted, not listed")
        XCTAssertEqual(table.rows[0][2].text, "0xFC EvtPowerOn")
        XCTAssertEqual(table.rows[1][2].text, "0x77 — not in the review")
        let note = table.note ?? ""
        XCTAssertTrue(note.contains("EvtPowerOn (0xFC): logged at power-on"), note)
        XCTAssertTrue(note.contains("EventCode: what happened"), note)
        XCTAssertTrue(note.contains("Free slots: 1."), note)
        let code = UEFIECRuntimeDetail.tables(.decoded([area]), image: NodeID([0, 1]), in: .english)[1]
        XCTAssertEqual(code.rows.first?.map(\.text), ["Writes", "0x144B0"])
        XCTAssertEqual(code.rowTargets.first, .code(image: NodeID([0, 1]), address: 0x144B0))
    }

    func testNoReviewIsSaid() {
        let table = UEFIECRuntimeDetail.tables(.noReview, in: .english)[0]
        XCTAssertTrue(table.rows.isEmpty)
        XCTAssertNotNil(table.note)
    }
}
