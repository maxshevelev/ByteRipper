import XCTest
@testable import UEFIImage

/// Reading AMI NVAR stores (§9): where they are found — three file GUIDs and
/// raw sections — and what a store reads as: entries, their chains, free
/// space, and the GUID table at the end.
final class NvarParseTests: XCTestCase {
    private let vendor = EFIGUID("8BE4DF61-93CA-11D2-AA0D-00E098032B8C")!

    private func file(in parsed: UEFIImage) -> UEFINode {
        parsed.roots[0].children[0]
    }

    // MARK: - A store

    /// Two variables — one carrying its GUID and an ASCII name, one naming its
    /// GUID by index and spelling its name in UCS-2 — then the erased rest of
    /// the store, then the one-GUID table the second entry points into.
    func testAStoreFileReadsAsItsEntriesFreeSpaceAndGuidTable() {
        let setup = TestNVAR.entry(name: "Setup", data: [0x01, 0x02])
        let lang = TestNVAR.entry(attributes: NVAR.valid, guidIndex: 0, name: "Lang", data: [0x65, 0x6E])
        let parsed = UEFIParser.parse(TestNVAR.volume(body: TestNVAR.store([setup, lang], guids: [vendor])))
        let file = file(in: parsed)
        let base = file.body.lowerBound

        XCTAssertEqual(file.children.map(\.kind), [.nvarEntry, .nvarEntry, .freeSpace, .nvarGuidStore])
        XCTAssertTrue(parsed.diagnostics.isEmpty, "\(parsed.diagnostics)")

        // Ten bytes of header, the sixteen-byte GUID and "Setup\0" are the
        // entry's header; the two bytes after are its value.
        let first = file.children[0]
        XCTAssertEqual(first.name, "Setup")
        XCTAssertEqual(first.guid, TestImage.driverGUID)
        XCTAssertEqual(first.subtype, UEFITypes.Sub.fullNvarEntry)
        XCTAssertEqual(first.header, base..<(base + 32))
        XCTAssertEqual(first.body, (base + 32)..<(base + 34))
        XCTAssertTrue(first.tail.isEmpty)

        let second = file.children[1]
        XCTAssertEqual(second.name, "Lang")
        XCTAssertEqual(second.guid, vendor)
        XCTAssertEqual(second.header, (base + 34)..<(base + 34 + 10 + 1 + 10))

        XCTAssertEqual(file.children[2].range, (base + UInt64(setup.count + lang.count))..<(base + 0x100 - 16))
        XCTAssertTrue(file.children[2].isErased)
        XCTAssertEqual(file.children[3].body, (base + 0x100 - 16)..<(base + 0x100))
        XCTAssertEqual(file.children[3].uefiItemType, UEFITypes.Item.nvarGuidStore.rawValue)
    }

    /// The PEI and BB defaults are stores too, under GUIDs of their own.
    func testBothDefaultsFilesReadAsStores() {
        for guid in [NvramGuids.nvramNvarPeiExternalDefaultsFileGuid, NvramGuids.nvramNvarBbDefaultsFileGuid] {
            let parsed = UEFIParser.parse(TestNVAR.volume(fileGuid: guid, body: TestNVAR.store([TestNVAR.entry()])))
            XCTAssertEqual(file(in: parsed).children.map(\.kind), [.nvarEntry, .freeSpace], "\(guid)")
        }
    }

    /// A raw file with any other GUID is bytes, whatever it holds.
    func testARawFileWithAnotherGuidIsNotReadAsAStore() {
        let parsed = UEFIParser.parse(TestNVAR.volume(fileGuid: TestImage.driverGUID, body: TestNVAR.store([TestNVAR.entry()])))
        XCTAssertTrue(file(in: parsed).children.isEmpty)
    }

    /// A store file that was never written is an empty store, not a defect.
    func testAnErasedStoreFileIsFreeSpace() {
        let parsed = UEFIParser.parse(TestNVAR.volume(body: TestNVAR.store([])))
        XCTAssertEqual(file(in: parsed).children.map(\.kind), [.freeSpace])
        XCTAssertTrue(parsed.diagnostics.isEmpty)
    }

    /// A store file whose body is not entries stays a leaf, and the parse
    /// says the store does not read.
    func testAStoreFileThatIsNotAStoreStaysALeafAndSaysSo() {
        let parsed = UEFIParser.parse(TestNVAR.volume(body: [0x12, 0x34, 0x56, 0x78] + TestNVAR.store([])))
        let file = file(in: parsed)
        XCTAssertTrue(file.children.isEmpty)
        XCTAssertEqual(parsed.diagnostics.map(\.kind), [.unreadableNvarEntry])
        XCTAssertEqual(parsed.diagnostics.first?.offset, file.body.lowerBound)
    }

    // MARK: - Chains

    /// A variable written twice: the first entry links to a data-only entry
    /// with the new value. The link holds the name and GUID; the data entry,
    /// the last of the chain, takes them from it. The chain starts at the
    /// store's first entry — the case the reference misses.
    func testADataEntryTakesItsNameFromTheEntryThatLinksToIt() {
        // `next` changes no size, so an entry's length is known before it
        // is written.
        let linked = TestNVAR.entry(next: UInt32(TestNVAR.entry(data: [0x01]).count), data: [0x01])
        let parsed = UEFIParser.parse(TestNVAR.volume(body: TestNVAR.store([
            linked, TestNVAR.dataEntry(data: [0x02]),
        ])))
        let entries = file(in: parsed).children

        XCTAssertEqual(entries[0].subtype, UEFITypes.Sub.linkNvarEntry)
        XCTAssertEqual(entries[1].subtype, UEFITypes.Sub.dataNvarEntry)
        XCTAssertEqual(entries[1].name, "Setup")
        XCTAssertEqual(entries[1].guid, TestImage.driverGUID)
        XCTAssertEqual(UInt64(entries[1].header.count), NVAR.headerSize)
        XCTAssertTrue(parsed.diagnostics.isEmpty)
    }

    /// A link in the middle of a chain is a link; only the last is data.
    func testOnlyTheLastLinkOfAChainIsData() {
        let head = TestNVAR.entry(next: UInt32(TestNVAR.entry(data: [0x01]).count), data: [0x01])
        let middle = TestNVAR.dataEntry(next: UInt32(TestNVAR.dataEntry(data: [0x02]).count), data: [0x02])
        let parsed = UEFIParser.parse(TestNVAR.volume(body: TestNVAR.store([
            TestNVAR.entry(name: "Other", data: [0x00]),
            head, middle, TestNVAR.dataEntry(data: [0x03]),
        ])))
        let entries = file(in: parsed).children

        XCTAssertEqual(entries[1].subtype, UEFITypes.Sub.linkNvarEntry)
        XCTAssertEqual(entries[2].subtype, UEFITypes.Sub.linkNvarEntry)
        XCTAssertEqual(entries[2].name, "Setup")
        XCTAssertEqual(entries[3].subtype, UEFITypes.Sub.dataNvarEntry)
        XCTAssertEqual(entries[3].name, "Setup")
    }

    /// A superseded entry is invalid, and a data entry whose chain starts at
    /// one — or at nothing — is a broken link.
    func testASupersededEntryAndADataEntryWithNoValidHeadAreInvalid() {
        let invalid = NVAR.localGuid | NVAR.asciiName
        let head = TestNVAR.entry(
            attributes: invalid, next: UInt32(TestNVAR.entry(attributes: invalid, data: [0x01]).count), data: [0x01]
        )
        let parsed = UEFIParser.parse(TestNVAR.volume(body: TestNVAR.store([
            head, TestNVAR.dataEntry(data: [0x02]), TestNVAR.dataEntry(data: [0x03]),
        ])))
        let entries = file(in: parsed).children

        XCTAssertEqual(entries[0].subtype, UEFITypes.Sub.invalidNvarEntry)
        XCTAssertEqual(entries[0].name, "Invalid")
        XCTAssertEqual(entries[1].subtype, UEFITypes.Sub.invalidLinkNvarEntry)
        XCTAssertEqual(entries[2].subtype, UEFITypes.Sub.invalidLinkNvarEntry)
        XCTAssertEqual(entries[2].name, "Invalid link")
        XCTAssertNil(entries[2].guid)
    }

    // MARK: - The extended header

    /// A checksum that adds up says nothing; one that does not is reported
    /// with the byte it should be. The extended header is the entry's tail.
    func testAnExtendedHeaderChecksumIsVerified() {
        let good = UEFIParser.parse(TestNVAR.volume(body: TestNVAR.store([
            TestNVAR.checksummedEntry(name: "Setup", data: [0x10, 0x20, 0x30]),
        ])))
        let entry = file(in: good).children[0]
        XCTAssertTrue(good.diagnostics.isEmpty, "\(good.diagnostics)")
        XCTAssertEqual(entry.tail.count, 4)
        XCTAssertEqual(entry.body.count, 3)

        let bad = UEFIParser.parse(TestNVAR.volume(body: TestNVAR.store([
            TestNVAR.checksummedEntry(name: "Setup", data: [0x10, 0x20, 0x30], wrongBy: 1),
        ])))
        guard case .checksumMismatch(.nvarEntry, let stored, let computed) = bad.diagnostics.first?.kind else {
            return XCTFail("\(bad.diagnostics)")
        }
        XCTAssertEqual(computed, (stored &- 1) & 0xFF)
        XCTAssertEqual(bad.diagnostics[0].offset, file(in: bad).children[0].range.upperBound - 3)
    }

    // MARK: - Broken stores

    /// An entry that does not read stops the walk: what came before stays,
    /// and the rest of the store is padding.
    func testABrokenEntryKeepsTheEntriesBeforeIt() {
        var broken = BinaryWriter()
        broken.u32(NVAR.signature)
        broken.u16(4)                  // smaller than the header
        broken.u24(NVAR.noNext)
        broken.u8(NVAR.valid)
        let first = TestNVAR.entry()
        let parsed = UEFIParser.parse(TestNVAR.volume(body: TestNVAR.store([first, broken.bytes])))
        let file = file(in: parsed)

        XCTAssertEqual(file.children.map(\.kind), [.nvarEntry, .padding])
        XCTAssertEqual(parsed.diagnostics.map(\.kind), [.unreadableNvarEntry])
        XCTAssertEqual(parsed.diagnostics.first?.offset, file.body.lowerBound + UInt64(first.count))
    }

    // MARK: - Nested stores

    /// A variable whose value is a store of its own opens onto it.
    func testAnEntryWhoseValueIsAStoreOpensOntoIt() {
        let inner = TestNVAR.entry(name: "Inner", data: [0x07])
        let parsed = UEFIParser.parse(TestNVAR.volume(body: TestNVAR.store([
            TestNVAR.entry(name: "StdDefaults", data: inner),
        ])))
        let outer = file(in: parsed).children[0]
        XCTAssertEqual(outer.children.map(\.name), ["Inner"])
        XCTAssertEqual(outer.children[0].range, outer.body)
    }

    // MARK: - Raw sections

    /// The reference tries every raw section as a store, and so does this.
    func testARawSectionHoldingAStoreReadsAsOne() {
        let store = TestNVAR.store([TestNVAR.entry()], length: 0x40)
        let parsed = UEFIParser.parse(TestNVAR.volume(sections: [
            TestImage.section(type: Section.raw, body: store),
        ]))
        let section = file(in: parsed).children[0]
        XCTAssertEqual(section.children.map(\.kind), [.nvarEntry, .freeSpace])
        XCTAssertTrue(parsed.diagnostics.isEmpty)
    }

    /// A raw section that is not a store is left alone, quietly — even one
    /// that opens on the same first byte.
    func testARawSectionThatIsNotAStoreIsLeftAloneQuietly() {
        for body: [UInt8] in [[0x4D, 0x5A, 0x90, 0x00], Array("Nope".utf8), [0xFF, 0xFF, 0xFF, 0xFF]] {
            let parsed = UEFIParser.parse(TestNVAR.volume(sections: [
                TestImage.section(type: Section.raw, body: body),
            ]))
            XCTAssertTrue(file(in: parsed).children[0].children.isEmpty, "\(body)")
            XCTAssertTrue(parsed.diagnostics.isEmpty, "\(body): \(parsed.diagnostics)")
        }
    }

    /// The external defaults file's raw section is meant to be a store: an
    /// erased one is an empty store, anything else is reported.
    func testTheExternalDefaultsRawSectionIsMeantToBeAStore() {
        let defaults = NvramGuids.nvramNvarExternalDefaultsFileGuid
        let erased = UEFIParser.parse(TestNVAR.volume(fileGuid: defaults, sections: [
            TestImage.section(type: Section.raw, body: [UInt8](repeating: 0xFF, count: 0x20)),
        ]))
        XCTAssertEqual(file(in: erased).children[0].children.map(\.kind), [.freeSpace])
        XCTAssertTrue(erased.diagnostics.isEmpty)

        let garbage = UEFIParser.parse(TestNVAR.volume(fileGuid: defaults, sections: [
            TestImage.section(type: Section.raw, body: [0x12, 0x34, 0x56, 0x78]),
        ]))
        XCTAssertEqual(garbage.diagnostics.map(\.kind), [.unreadableNvarEntry])
    }

    // MARK: - Classification

    func testAnEntryClassifiesAsAnNvarEntryWithItsSubtype() {
        let parsed = UEFIParser.parse(TestNVAR.volume(body: TestNVAR.store([TestNVAR.entry()])))
        let entry = file(in: parsed).children[0]
        XCTAssertEqual(entry.uefiItemType, UEFITypes.Item.nvarEntry.rawValue)
        XCTAssertEqual(entry.uefiItemSubtype, UEFITypes.Sub.fullNvarEntry)
        XCTAssertEqual(UEFITypes.subtypeName(type: entry.uefiItemType, entry.uefiItemSubtype!), "Full")
    }
}
