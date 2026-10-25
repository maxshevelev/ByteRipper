import Foundation
import XCTest
@testable import CodeAnalysis

/// The original module's headers, read for the one thing the Code panel needs:
/// an address in Ghidra's program back to an offset in the module bytes.
final class ModuleLayoutTests: XCTestCase {
    private struct TestSection {
        let name: String
        let virtualAddress: UInt32
        let virtualSize: UInt32
        let rawPointer: UInt32
        let rawSize: UInt32
        var characteristics: UInt32 = 0x6000_0020

        init(name: String, virtualAddress: UInt32, virtualSize: UInt32,
             rawPointer: UInt32, rawSize: UInt32,
             characteristics: UInt32 = 0x6000_0020) {
            self.name = name
            self.virtualAddress = virtualAddress
            self.virtualSize = virtualSize
            self.rawPointer = rawPointer
            self.rawSize = rawSize
            self.characteristics = characteristics
        }
    }

    // MARK: - TE

    func testATEImageMapsAnAddressToItsBody() throws {
        var module = teImage(sections: [
            TestSection(name: ".text", virtualAddress: 0x1000, virtualSize: 0x40,
                        rawPointer: 0x240, rawSize: 0x40)
        ])
        writeBytes(&module, at: 0x68, [0x55, 0x8B, 0xEC, 0x83, 0xE4, 0xF8])

        let layout = try ModuleLayout(module: module)
        XCTAssertEqual(layout.format, .te)
        XCTAssertEqual(layout.imageBase, 0)
        XCTAssertEqual(layout.byteCount, module.count)
        XCTAssertFalse(layout.is64Bit)
        XCTAssertEqual(layout.sections.count, 1)
        XCTAssertEqual(layout.sections[0].name, ".text")
        XCTAssertEqual(layout.sections[0].rawOffset, 0x68)

        XCTAssertEqual(layout.fileOffset(for: CodeAddress(0x1000)), 0x68)
        XCTAssertEqual(layout.fileRange(for: CodeAddress(0x1000), count: 6),
                       UInt64(0x68)..<UInt64(0x6E))
        XCTAssertEqual(Array(module[0x68..<0x6E]), [0x55, 0x8B, 0xEC, 0x83, 0xE4, 0xF8])
        XCTAssertEqual(layout.address(forFileOffset: 0x68), CodeAddress(0x1000))
        XCTAssertEqual(layout.section(containing: CodeAddress(0x1010))?.name, ".text")
        XCTAssertEqual(layout.section(containingFileOffset: 0x68)?.name, ".text")

        // A TE image does not hold the headers that were stripped from it.
        XCTAssertNil(layout.fileOffset(for: CodeAddress(0x10)))
        XCTAssertNil(layout.address(forFileOffset: 0x10))
        // Nor does it invent bytes past the section's stored range.
        XCTAssertNil(layout.fileOffset(for: CodeAddress(0x1040)))
        XCTAssertNil(layout.fileOffset(for: CodeAddress(0x2000)))
    }

    /// The stage's acceptance check: a real artifact's instruction address maps
    /// to bytes that equal the instruction's own `bytes`.
    func testAnArtifactInstructionMapsToItsBytes() throws {
        var module = teImage(sections: [
            TestSection(name: ".text", virtualAddress: 0x1000, virtualSize: 0x40,
                        rawPointer: 0x240, rawSize: 0x40)
        ])
        writeBytes(&module, at: 0x68, [0x55, 0x8B, 0xEC, 0x83, 0xE4, 0xF8])
        let layout = try ModuleLayout(module: module)
        let artifact = try JSONDecoder().decode(CodeArtifact.self, from: Data("""
        {"script_version":2,"ghidra":"12.1.2","functions":[
          {"entry":"0x1000","name":"FUN_1000","instructions":[
            {"address":"0x1000","bytes":"55 8B EC 83 E4 F8","text":"PUSH EBP"}]}]}
        """.utf8))
        let instruction = try XCTUnwrap(artifact.functions.first?.instructions.first)
        let range = try XCTUnwrap(layout.fileRange(
            for: instruction.address, count: instruction.bytes.count,
            imageBase: artifact.program?.imageBase?.value))
        XCTAssertEqual(Array(module[Int(range.lowerBound)..<Int(range.upperBound)]),
                       instruction.bytes)
    }

    func testTwoSectionsMapToTheirOwnBytes() throws {
        var module = teImage(sections: [
            TestSection(name: ".text", virtualAddress: 0x1000, virtualSize: 0x40,
                        rawPointer: 0x240, rawSize: 0x40),
            TestSection(name: ".data", virtualAddress: 0x2000, virtualSize: 0x20,
                        rawPointer: 0x280, rawSize: 0x20)
        ])
        writeBytes(&module, at: 0x68, [0x55, 0x8B, 0xEC])
        writeBytes(&module, at: 0xA8, [0xDE, 0xAD, 0xBE, 0xEF])

        let layout = try ModuleLayout(module: module)
        XCTAssertEqual(layout.fileOffset(for: CodeAddress(0x1000)), 0x68)
        XCTAssertEqual(layout.fileOffset(for: CodeAddress(0x2000)), 0xA8)
        XCTAssertEqual(layout.section(containingFileOffset: 0x68)?.name, ".text")
        XCTAssertEqual(layout.section(containingFileOffset: 0xA8)?.name, ".data")
        XCTAssertEqual(layout.address(forFileOffset: 0x68), CodeAddress(0x1000))
        XCTAssertEqual(layout.address(forFileOffset: 0xA8), CodeAddress(0x2000))
    }

    func testATEWhoseSectionPointsBeforeTheStrippedHeadersIsRefused() {
        let module = teImage(sections: [
            TestSection(name: ".text", virtualAddress: 0x1000, virtualSize: 0x20,
                        rawPointer: 0x100, rawSize: 0x20)
        ])
        XCTAssertThrowsError(try ModuleLayout(module: module))
    }

    // MARK: - PE

    func testAPE32ImageMapsWithItsImageBase() throws {
        var module = peImage(pe32Plus: false, sections: [
            TestSection(name: ".text", virtualAddress: 0x1000, virtualSize: 0x40,
                        rawPointer: 0x200, rawSize: 0x40)
        ], imageBase: 0x1000_0000)
        writeBytes(&module, at: 0x200, [0x55, 0x8B, 0xEC])

        let layout = try ModuleLayout(module: module)
        XCTAssertEqual(layout.format, .pe32)
        XCTAssertEqual(layout.imageBase, 0x1000_0000)
        XCTAssertFalse(layout.is64Bit)
        XCTAssertEqual(layout.entryPoint, 0x1000)
        XCTAssertEqual(layout.fileOffset(for: CodeAddress(0x1000_1000)), 0x200)
        XCTAssertEqual(layout.fileRange(for: CodeAddress(0x1000_1000), count: 3),
                       UInt64(0x200)..<UInt64(0x203))
        XCTAssertEqual(Array(module[0x200..<0x203]), [0x55, 0x8B, 0xEC])
        XCTAssertEqual(layout.address(forFileOffset: 0x200), CodeAddress(0x1000_1000))

        // PE headers are in the module, at their RVA.
        XCTAssertEqual(layout.fileOffset(for: CodeAddress(0x1000_0010)), 0x10)
        XCTAssertEqual(layout.address(forFileOffset: 0x10), CodeAddress(0x1000_0010))
    }

    func testAPE32PlusImageMapsWithItsImageBase() throws {
        var module = peImage(pe32Plus: true, sections: [
            TestSection(name: ".text", virtualAddress: 0x1000, virtualSize: 0x40,
                        rawPointer: 0x200, rawSize: 0x40)
        ], imageBase: 0x1_4000_0000)
        writeBytes(&module, at: 0x200, [0x48, 0x89, 0xE5])

        let layout = try ModuleLayout(module: module)
        XCTAssertEqual(layout.format, .pe32Plus)
        XCTAssertEqual(layout.imageBase, 0x1_4000_0000)
        XCTAssertTrue(layout.is64Bit)
        XCTAssertEqual(layout.fileOffset(for: CodeAddress(0x1_4000_1000)), 0x200)
        XCTAssertEqual(Array(module[0x200..<0x203]), [0x48, 0x89, 0xE5])
        XCTAssertEqual(layout.address(forFileOffset: 0x200), CodeAddress(0x1_4000_1000))
    }

    func testASectionTailWithoutStoredBytesHasNoFileOffset() throws {
        let module = teImage(sections: [
            TestSection(name: ".text", virtualAddress: 0x1000, virtualSize: 0x100,
                        rawPointer: 0x240, rawSize: 0x10)
        ])
        let layout = try ModuleLayout(module: module)
        XCTAssertEqual(layout.section(containing: CodeAddress(0x1020))?.name, ".text")
        XCTAssertNil(layout.fileOffset(for: CodeAddress(0x1020)))
        XCTAssertNil(layout.fileRange(for: CodeAddress(0x1000), count: 0x20))
    }

    // MARK: - Refusals

    func testAModuleWithNoRecognisedSignatureIsRefused() {
        XCTAssertThrowsError(try ModuleLayout(module: Data(repeating: 0, count: 0x40)))
    }

    func testASHortModuleIsRefused() {
        XCTAssertThrowsError(try ModuleLayout(module: Data([0x56, 0x5A])))
    }

    func testAPEWithAnUnknownOptionalHeaderMagicIsRefused() {
        var module = peImage(pe32Plus: false, sections: [
            TestSection(name: ".text", virtualAddress: 0x1000, virtualSize: 0x20,
                        rawPointer: 0x200, rawSize: 0x20)
        ], imageBase: 0x1000_0000)
        write16(&module, at: 0x58, 0x999)
        XCTAssertThrowsError(try ModuleLayout(module: module))
    }

    func testAPEWhoseSectionTableRunsPastTheModuleIsRefused() {
        var module = Data(repeating: 0, count: 0x140)
        module[0] = 0x4D
        module[1] = 0x5A
        write32(&module, at: 0x3C, 0x40)
        module[0x40] = 0x50
        module[0x41] = 0x45
        write16(&module, at: 0x44, 0x14C)       // machine
        write16(&module, at: 0x46, 1)           // sections
        write16(&module, at: 0x54, 224)         // SizeOfOptionalHeader
        write16(&module, at: 0x58, 0x10B)       // PE32
        XCTAssertThrowsError(try ModuleLayout(module: module))
    }

    // MARK: - Builders

    /// A TE image of 1 KiB, with section data at the TE offsets its raw
    /// pointers imply: `rawPointer - StrippedSize + 40`.
    private func teImage(sections: [TestSection], stripped: UInt16 = 0x200,
                         machine: UInt16 = 0x14C, imageBase: UInt64 = 0,
                         entry: UInt32 = 0x1000, byteCount: Int = 0x400) -> Data {
        var data = Data(repeating: 0, count: byteCount)
        data[0] = 0x56
        data[1] = 0x5A
        write16(&data, at: 2, machine)
        data[4] = UInt8(sections.count)
        data[5] = 0x0B
        write16(&data, at: 6, stripped)
        write32(&data, at: 8, entry)
        write32(&data, at: 12, sections.first?.virtualAddress ?? 0)
        write64(&data, at: 16, imageBase)
        for (index, section) in sections.enumerated() {
            writeSection(&data, at: 40 + index * 40, section)
        }
        return data
    }

    /// A PE image of 1 KiB. Its headers are 0x200 bytes; `OptionalHeader` is
    /// the size PE32 (224) or PE32+ (240) has.
    private func peImage(pe32Plus: Bool, sections: [TestSection],
                         imageBase: UInt64, byteCount: Int = 0x400) -> Data {
        let optionalSize = pe32Plus ? 240 : 224
        let pe = 0x40
        let optional = pe + 24
        var data = Data(repeating: 0, count: byteCount)
        data[0] = 0x4D
        data[1] = 0x5A
        write32(&data, at: 0x3C, UInt32(pe))
        data[pe] = 0x50
        data[pe + 1] = 0x45
        write16(&data, at: pe + 4, pe32Plus ? 0x8664 : 0x14C)
        write16(&data, at: pe + 6, UInt16(sections.count))
        write16(&data, at: pe + 20, UInt16(optionalSize))
        write16(&data, at: optional, pe32Plus ? 0x20B : 0x10B)
        write32(&data, at: optional + 16, sections.first?.virtualAddress ?? 0)
        write32(&data, at: optional + 20, sections.first?.virtualAddress ?? 0)
        if pe32Plus {
            write64(&data, at: optional + 24, imageBase)
        } else {
            write32(&data, at: optional + 28, UInt32(imageBase))
        }
        write32(&data, at: optional + 32, 0x1000)   // SectionAlignment
        write32(&data, at: optional + 36, 0x200)    // FileAlignment
        write32(&data, at: optional + 56, 0x2000)   // SizeOfImage
        write32(&data, at: optional + 60, 0x200)    // SizeOfHeaders
        write32(&data, at: optional + (pe32Plus ? 108 : 92), 16)
        let table = optional + optionalSize
        for (index, section) in sections.enumerated() {
            writeSection(&data, at: table + index * 40, section)
        }
        return data
    }

    private func writeSection(_ data: inout Data, at offset: Int, _ section: TestSection) {
        let name = Array(section.name.utf8.prefix(8))
        for (index, byte) in name.enumerated() {
            data[offset + index] = byte
        }
        write32(&data, at: offset + 8, section.virtualSize)
        write32(&data, at: offset + 12, section.virtualAddress)
        write32(&data, at: offset + 16, section.rawSize)
        write32(&data, at: offset + 20, section.rawPointer)
        write32(&data, at: offset + 36, section.characteristics)
    }

    private func writeBytes(_ data: inout Data, at offset: Int, _ bytes: [UInt8]) {
        for (index, byte) in bytes.enumerated() {
            data[offset + index] = byte
        }
    }

    private func write16(_ data: inout Data, at offset: Int, _ value: UInt16) {
        for index in 0..<2 {
            data[offset + index] = UInt8((value >> (8 * UInt16(index))) & 0xFF)
        }
    }

    private func write32(_ data: inout Data, at offset: Int, _ value: UInt32) {
        for index in 0..<4 {
            data[offset + index] = UInt8((value >> (8 * UInt32(index))) & 0xFF)
        }
    }

    private func write64(_ data: inout Data, at offset: Int, _ value: UInt64) {
        for index in 0..<8 {
            data[offset + index] = UInt8((value >> (8 * UInt64(index))) & 0xFF)
        }
    }
}
