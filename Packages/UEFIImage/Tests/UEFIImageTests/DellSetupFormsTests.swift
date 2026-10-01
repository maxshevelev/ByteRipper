import XCTest
@testable import UEFIImage

/// A driver's HII, built byte for byte: string packages and an IFR form
/// package, as Dell's Setup driver carries them.
enum TestDellSetup {
    static let namespace = DvarParserTests.namespace

    /// A string package: the header, the language tag, the strings as UCS-2
    /// blocks from id 1, the end block.
    static func strings(_ language: String, _ texts: [String]) -> [UInt8] {
        var blocks: [UInt8] = []
        for text in texts {
            blocks.append(0x14)
            for unit in text.utf16 { blocks += [UInt8(unit & 0xFF), UInt8(unit >> 8)] }
            blocks += [0, 0]
        }
        blocks.append(0x00)
        let headerSize = 46 + language.utf8.count + 1
        var writer = BinaryWriter()
        writer.u24(UInt32(headerSize + blocks.count))
        writer.u8(0x04)
        writer.u32(UInt32(headerSize))
        writer.u32(UInt32(headerSize))
        writer.fill(32, with: 0)
        writer.u16(1)
        writer.raw(Array(language.utf8) + [0])
        writer.raw(blocks)
        return writer.bytes
    }

    static func op(_ code: UInt8, scope: Bool = false, _ body: [UInt8] = []) -> [UInt8] {
        [code, UInt8(2 + body.count) | (scope ? 0x80 : 0)] + body
    }

    static let end = op(0x29)

    /// A question: prompt, help, question id, variable store and offset,
    /// flags, then what its kind adds; scoped when it has children.
    static func question(_ code: UInt8, prompt: UInt16, help: UInt16 = 0,
                         extra: [UInt8] = [0], children: [[UInt8]] = []) -> [UInt8] {
        var body = BinaryWriter()
        body.u16(prompt)
        body.u16(help)
        body.u16(1)
        body.u16(0x1000)
        body.u16(0)
        body.u8(0)
        body.raw(extra)
        let scoped = !children.isEmpty
        return op(code, scope: scoped, body.bytes) + children.flatMap { $0 } + (scoped ? end : [])
    }

    static func option(text: UInt16, value: UInt8) -> [UInt8] {
        op(0x09, [UInt8(text & 0xFF), UInt8(text >> 8), 0, 0, value])
    }

    /// Dell's opcode that ties the question before it to a DVAR variable.
    static func binding(nameId: UInt32, namespace: EFIGUID = namespace) -> [UInt8] {
        var body = BinaryWriter()
        body.guid(DellSetup.opcodeGuid)
        body.u8(DellSetup.bindsVariable)
        body.guid(namespace)
        body.u32(nameId)
        return op(0x5F, body.bytes)
    }

    static func form(title: UInt16, _ content: [[UInt8]]) -> [UInt8] {
        op(0x01, scope: true, [1, 0, UInt8(title & 0xFF), UInt8(title >> 8)]) + content.flatMap { $0 } + end
    }

    /// A form package: the form set, its forms, the end of its scope.
    static func formPackage(_ forms: [[UInt8]]) -> [UInt8] {
        var set = BinaryWriter()
        set.guid(KnownGUIDs.guid("22222222-3333-4444-5555-666666666666"))
        set.u16(0)
        set.u16(0)
        set.u8(0)
        let ops = op(0x0E, scope: true, set.bytes) + forms.flatMap { $0 } + end
        var writer = BinaryWriter()
        writer.u24(UInt32(4 + ops.count))
        writer.u8(0x02)
        writer.raw(ops)
        return writer.bytes
    }

    /// Prompts and help in English, keywords in `x-UEFI`, one page of three
    /// questions: a checkbox and a list, each tied to a variable, and a
    /// question whose opcode comes after something else.
    static func driver() -> [UInt8] {
        let english = strings("en-US", [
            "Allow BIOS Downgrade",                // 1
            "Lets an older BIOS be flashed.",      // 2
            "Security",                            // 3
            "Boot Mode",                           // 4
            "Legacy",                              // 5
            "UEFI",                                // 6
            "Sunday",                              // 7
        ])
        let keywords = strings("x-UEFI", ["AllowBiosDowngrade", "", "", "BootMode[SuppressIf:Legacy]", "", "", "AutoOnSun"])
        let forms = formPackage([form(title: 3, [
            question(0x06, prompt: 1, help: 2, children: [op(0x5B, scope: true, [0, 0, 8]), end]),
            binding(nameId: 0x535),
            question(0x05, prompt: 4, extra: [0x10, 0, 1, 1], children: [option(text: 5, value: 0), option(text: 6, value: 1)]),
            binding(nameId: 0x40),
            question(0x06, prompt: 7),
            op(0x12, [0x11, 0, 0, 0]),
            binding(nameId: 0x600),
        ])])
        // Code around them, as in a PE image, and each array's length first.
        let code = [UInt8](repeating: 0xCC, count: 0x41)
        return code + le32(english.count + keywords.count + 4) + english + keywords + code + le32(forms.count + 4) + forms + code
    }

    static func le32(_ value: Int) -> [UInt8] {
        (0..<4).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) }
    }
}

@MainActor
final class DellSetupFormsTests: XCTestCase {
    private let key = { DellSetup.Key(namespace: TestDellSetup.namespace, nameId: $0) }

    /// A question is tied to the variable the opcode right after it names, and
    /// reads as its page words it — keyword, prompt, help and page.
    func testAQuestionIsTiedToTheVariableTheOpcodeAfterItNames() throws {
        let settings = DellSetup.settings(in: TestDellSetup.driver())
        let downgrade = try XCTUnwrap(settings[key(0x535)])
        XCTAssertEqual(downgrade.prompt, "Allow BIOS Downgrade")
        XCTAssertEqual(downgrade.keyword, "AllowBiosDowngrade")
        XCTAssertEqual(downgrade.name, "AllowBiosDowngrade", "the keyword names the row")
        XCTAssertEqual(downgrade.help, "Lets an older BIOS be flashed.")
        XCTAssertEqual(downgrade.form, "Security")
        XCTAssertEqual(downgrade.kind, .checkbox)
    }

    /// A list's values are called what its options say; the keyword leaves
    /// out the condition some carry after it.
    func testAListsValuesAreItsOptions() throws {
        let mode = try XCTUnwrap(DellSetup.settings(in: TestDellSetup.driver())[key(0x40)])
        XCTAssertEqual(mode.kind, .oneOf)
        XCTAssertEqual(mode.keyword, "BootMode")
        XCTAssertEqual(mode.options.map(\.text), ["Legacy", "UEFI"])
        XCTAssertEqual(mode.option(for: 1), "UEFI")
        XCTAssertNil(mode.option(for: 2))
    }

    /// Dell's opcode after some other opcode is about that one, not about the
    /// question before both.
    func testAnOpcodeAfterSomethingElseTiesNothing() {
        let settings = DellSetup.settings(in: TestDellSetup.driver())
        XCTAssertNil(settings[key(0x600)])
        XCTAssertEqual(settings.count, 2)
    }

    /// Without keywords the prompt names the row.
    func testWithoutKeywordsThePromptNamesIt() throws {
        var driver = TestDellSetup.driver()
        let tag = Array("x-UEFI".utf8)
        let at = try XCTUnwrap((0...(driver.count - tag.count)).first { driver[$0..<($0 + tag.count)].elementsEqual(tag) })
        driver[at] = 0x01                       // a tag that is not printable is no package
        let downgrade = try XCTUnwrap(DellSetup.settings(in: driver)[key(0x535)])
        XCTAssertNil(downgrade.keyword)
        XCTAssertEqual(downgrade.name, "Allow BIOS Downgrade")
    }

    /// A DVAR store beside a volume whose driver is in a compressed section:
    /// the tree reads the forms off a copy of itself, and an entry is named by
    /// what its question is.
    func testTheTreeReadsTheFormsOfAnImageWithADvarStore() async throws {
        let driver = TestImage.sectionedFile(sections: [
            TestImage.compressionSection(algorithm: 0, body: TestImage.section(type: DellSetup.pe32Section, body: TestDellSetup.driver()),
                                         uncompressedLength: nil),
        ])
        let store = DvarParserTests.store([
            DvarParserTests.entry(state: DVAR.stored, declares: true, nameId: 0x40, data: [1]),
        ])
        let bytes = TestImage.image(TestImage.volume(length: 0x1000, files: [driver])) + store
            + [UInt8](repeating: 0xFF, count: 0x100)
        let entry = try XCTUnwrap(UEFIParser.parse(bytes).allNodes.first { $0.kind == .dvarEntry })

        let tree = LazyUEFITree(bytes)
        await withCheckedContinuation { continuation in tree.whenReady { continuation.resume() } }
        await withCheckedContinuation { continuation in tree.resolveDvarSettings { continuation.resume() } }
        XCTAssertEqual(tree.dvarSettings?.setting(for: entry)?.name, "BootMode")
        XCTAssertEqual(tree.image().dvarSettings?.settings.count, 2)
    }

    /// No DVAR store, nothing to name: the catalogue is empty.
    func testAnImageWithoutAStoreHasNoSettings() async {
        let driver = TestImage.sectionedFile(sections: [
            TestImage.section(type: DellSetup.pe32Section, body: TestDellSetup.driver()),
        ])
        let tree = LazyUEFITree(TestImage.image(TestImage.volume(length: 0x1000, files: [driver])))
        await withCheckedContinuation { continuation in tree.whenReady { continuation.resume() } }
        await withCheckedContinuation { continuation in tree.resolveDvarSettings { continuation.resume() } }
        XCTAssertEqual(tree.dvarSettings, DellSetup.Catalogue())
    }
}
