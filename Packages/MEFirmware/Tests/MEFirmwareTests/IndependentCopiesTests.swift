import XCTest
import Foundation
@testable import MEFirmware

/// An independent firmware CSE Redundancy stores twice — in Boot 1 and in its
/// backup, Boot 2 — is one table saying where the copy is; copies that differ
/// stay two, and are warned about.
final class IndependentCopiesTests: XCTestCase {
    private typealias Slot = MEFirmwareAnalyzer.IndependentSlot

    /// A region with `parts` laid end to end, each at its own offset.
    private func region(_ parts: [[UInt8]]) -> (Data, [Range<Int>]) {
        var bytes: [UInt8] = []
        var ranges: [Range<Int>] = []
        for part in parts {
            ranges.append(bytes.count..<(bytes.count + part.count))
            bytes += part
        }
        return (Data(bytes), ranges)
    }

    func testAByteIdenticalCopyIsFoldedIntoTheFirst() {
        let pmc = [UInt8](repeating: 0x11, count: 16)
        let pchc = [UInt8](repeating: 0x22, count: 8)
        let (data, at) = region([pmc, pchc, pmc, pchc])
        let slots = [
            Slot(name: "PMCP", range: at[0], place: "Boot 1"),
            Slot(name: "PMCP", range: at[2], place: "Boot 2"),
            Slot(name: "PCHC", range: at[1], place: "Boot 1"),
            Slot(name: "PCHC", range: at[3], place: "Boot 2"),
        ]

        let merged = MEFirmwareAnalyzer.mergingRedundantCopies(slots, in: data)

        XCTAssertEqual(merged.unique.map(\.slot), [slots[0], slots[2]])
        XCTAssertEqual(merged.unique.map(\.copies), [["Boot 2"], ["Boot 2"]])
        XCTAssertTrue(merged.differing.isEmpty)
    }

    func testCopiesThatDifferStayTwoAndAreNamed() {
        var newer = [UInt8](repeating: 0x11, count: 16)
        newer[3] = 0x12
        let (data, at) = region([[UInt8](repeating: 0x11, count: 16), newer])
        let slots = [
            Slot(name: "PMCP", range: at[0], place: "Boot 1"),
            Slot(name: "PMCP", range: at[1], place: "Boot 2"),
        ]

        let merged = MEFirmwareAnalyzer.mergingRedundantCopies(slots, in: data)

        XCTAssertEqual(merged.unique.map(\.slot), slots)
        XCTAssertEqual(merged.unique.map(\.copies), [[], []])
        XCTAssertEqual(merged.differing.map(\.name), ["PMCP"])
        XCTAssertEqual(merged.differing.map(\.places), [["Boot 1", "Boot 2"]])
    }

    /// The same bytes under another partition name are another firmware's
    /// slot, not a copy.
    func testOnlyTheSamePartitionIsACopy() {
        let bytes = [UInt8](repeating: 0x33, count: 8)
        let (data, at) = region([bytes, bytes])
        let slots = [
            Slot(name: "PPHY", range: at[0], place: "Boot 1"),
            Slot(name: "NPHY", range: at[1], place: "Boot 1"),
        ]

        let merged = MEFirmwareAnalyzer.mergingRedundantCopies(slots, in: data)

        XCTAssertEqual(merged.unique.count, 2)
        XCTAssertTrue(merged.differing.isEmpty)
    }
}
