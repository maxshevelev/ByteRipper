import XCTest
@testable import UEFIImage

/// A raw FFS file holding Intel microcode reads as its images, the way the
/// FIT sees them, rather than as one blob.
final class MicrocodeFileTests: XCTestCase {
    private func firstFile(_ files: [[UInt8]]) throws -> UEFINode {
        let image = UEFIParser.parse(TestImage.volume(files: files), readsProtectedRanges: false)
        return try XCTUnwrap(image.allNodes.first { $0.kind == .file })
    }

    func testARawFileThatOpensOnMicrocodeIsReadAsItsImages() throws {
        let images = TestImage.microcode(revision: 0x1F)
            + TestImage.microcode(signature: 0x0009_06EA, revision: 0xF0)
        let body = images + [UInt8](repeating: 0xFF, count: 0x40)
        let file = try firstFile([TestImage.file(body: body)])

        XCTAssertEqual(file.children.map(\.kind), [.microcode, .microcode, .padding])
        XCTAssertEqual(file.children[0].range.lowerBound, file.body.lowerBound)
        XCTAssertEqual(file.children[1].name, "Microcode 906EA, revision F0")
        XCTAssertEqual(file.children[2].range.upperBound, file.body.upperBound)
        XCTAssertTrue(file.children[2].isErased, "the empty slot after the run")
    }

    func testARawFileOfAnythingElseIsKeptWhole() throws {
        let file = try firstFile([TestImage.file(body: [0x02, 0x00, 0x00, 0x00] + [UInt8](repeating: 0xAB, count: 0x40))])
        XCTAssertTrue(file.children.isEmpty)
    }
}

/// What a microcode header says beyond its raw fields: the processor its
/// signature names, the platforms its IDs select, and the extended signature
/// table of an update for more than one processor.
final class MicrocodeFieldsTests: XCTestCase {
    private func value(_ header: MicrocodeHeader, _ label: String) -> String? {
        header.fields.first { $0.label == label }?.value
    }

    func testTheSignatureReadsAsFamilyModelAndStepping() {
        XCTAssertEqual(MicrocodeHeader.processorText(0x0008_06EA), "Family 0x6, model 0x8E, stepping 0xA")
        XCTAssertEqual(MicrocodeHeader.processorText(0x00A2_0F10), "Family 0x19, model 0x21, stepping 0x0",
                       "an extended family is added to 0xF")
        XCTAssertEqual(MicrocodeHeader.platformsText(0xC2), "1, 6, 7")
        XCTAssertEqual(MicrocodeHeader.platformsText(0), "None")
    }

    func testAnUpdateWithNoExtendedTableSaysNothingOfOne() throws {
        let header = try XCTUnwrap(MicrocodeHeader.read(at: 0, in: ImageReader(TestImage.microcode())))
        XCTAssertNil(header.extendedTable)
        XCTAssertNil(value(header, "Extended signatures"))
        XCTAssertEqual(value(header, "Processor"), "Family 0x6, model 0x3A, stepping 0x9")
        XCTAssertEqual(value(header, "Platforms"), "0")
    }

    func testTheExtendedSignatureTableIsReadAndChecked() throws {
        let signatures: [(UInt32, UInt32)] = [(0x0009_06EA, 0x02), (0x000A_0671, 0x08)]
        let tableSize = 20 + 12 * signatures.count
        var bytes = TestImage.microcode(signature: 0x0008_06EA, dataSize: 0x40,
                                        totalSize: UInt32(0x70 + tableSize))
        func put(_ value: UInt32, at offset: Int) {
            for index in 0..<4 { bytes[offset + index] = UInt8(truncatingIfNeeded: value >> (8 * index)) }
        }
        var table = [UInt32(signatures.count), 0, 0, 0, 0]
        for (signature, platforms) in signatures { table += [signature, platforms, 0] }
        for (index, dword) in table.enumerated() { put(dword, at: 0x70 + 4 * index) }
        put(0 &- table.reduce(0, &+), at: 0x74)
        put(0, at: 0x10)
        put(0 &- (Checksums.sum32(of: 0..<UInt64(bytes.count), in: ImageReader(bytes)) ?? 0), at: 0x10)

        let header = try XCTUnwrap(MicrocodeHeader.read(at: 0, in: ImageReader(bytes)))
        let extended = try XCTUnwrap(header.extendedTable)
        XCTAssertEqual(extended.count, 2)
        XCTAssertEqual(extended.signatures.map(\.processorSignature), [0x0009_06EA, 0x000A_0671])
        XCTAssertEqual(extended.signatures.map(\.platformIDs), [0x02, 0x08])
        XCTAssertTrue(extended.checksumIsCorrect)
        XCTAssertTrue(header.checksumIsCorrect)
        XCTAssertEqual(value(header, "Extended signatures"), "906EA, A0671")
        XCTAssertTrue(value(header, "Extended checksum")?.hasSuffix("(Valid)") ?? false)
        XCTAssertNil(value(header, "Extended table"), "the count and the room agree")

        put(3, at: 0x70)
        let broken = try XCTUnwrap(MicrocodeHeader.read(at: 0, in: ImageReader(bytes))?.extendedTable)
        XCTAssertEqual(broken.signatures.count, 2, "only what the image has room for")
        XCTAssertFalse(broken.checksumIsCorrect)
    }
}
