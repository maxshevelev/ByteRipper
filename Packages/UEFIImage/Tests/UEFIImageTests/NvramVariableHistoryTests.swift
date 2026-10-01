import XCTest
@testable import UEFIImage

/// The copies a store keeps of one variable, oldest first, and what each one
/// changed (§9).
final class NvramVariableHistoryTests: XCTestCase {
    private static let marked: UInt8 = 0x3C

    /// The parsed store — the node whose children are the entries — and a
    /// reader over the bytes.
    private func vssStore(_ variables: [[UInt8]]) -> (UEFINode, ImageReader) {
        let bytes = TestNVRAM.nvramVolume(stores: [TestNVRAM.vssStore(variables: variables, freeSpace: 0x40)])
        return (UEFIParser.parse(bytes).roots[0].children[0], ImageReader(bytes))
    }

    private func nvarStore(_ entries: [[UInt8]]) -> (UEFINode, ImageReader) {
        let bytes = TestNVAR.volume(body: TestNVAR.store(entries))
        return (UEFIParser.parse(bytes).roots[0].children[0], ImageReader(bytes))
    }

    /// Two marked copies and the current one, read from any of the three, and
    /// each copy's value without the name before it.
    func testAVSSVariablesCopiesAreItsHistory() throws {
        let (store, reader) = vssStore([
            TestNVRAM.vssVariable(name: "BootOrder", data: [0x01, 0x00], state: Self.marked),
            TestNVRAM.vssVariable(name: "Lang", data: [0x65]),
            TestNVRAM.vssVariable(name: "BootOrder", data: [0x01, 0x00, 0x02, 0x00], state: Self.marked),
            TestNVRAM.vssVariable(name: "BootOrder", data: [0x02, 0x00, 0x01, 0x00]),
        ])
        let entries = store.children.filter { $0.kind == .vssEntry }
        let history = try XCTUnwrap(NvramVariableHistory.of(entries[0], in: store, reader: reader))

        XCTAssertEqual(history.name, "BootOrder")
        XCTAssertEqual(history.versions.map(\.entry), [entries[0].id, entries[2].id, entries[3].id])
        XCTAssertEqual(history.versions.map(\.state), [.superseded, .superseded, .current])
        XCTAssertEqual(history.versions.map { reader.bytes($0.value) }, [[1, 0], [1, 0, 2, 0], [2, 0, 1, 0]])
        XCTAssertEqual(NvramVariableHistory.of(entries[3], in: store, reader: reader), history, "the same from the current copy")
        XCTAssertNil(NvramVariableHistory.of(entries[1], in: store, reader: reader), "one copy is no history")
    }

    /// The tree calls a marked entry Invalid; the variable is read from it.
    func testAMarkedEntrySaysWhoseCopyItIs() throws {
        let (store, reader) = vssStore([TestNVRAM.vssVariable(name: "Setup", state: Self.marked)])
        let entry = try XCTUnwrap(store.children.first { $0.kind == .vssEntry })

        XCTAssertEqual(entry.name, "Invalid")
        XCTAssertEqual(NvramVariableHistory.variable(of: entry, in: store, reader: reader)?.name, "Setup")
    }

    /// A variable with no current copy was deleted, as its last copy.
    func testAVariableWithNoCurrentCopyWasDeleted() throws {
        let (store, reader) = vssStore([
            TestNVRAM.vssVariable(name: "Gone", state: Self.marked),
            TestNVRAM.vssVariable(name: "Gone", state: Self.marked),
        ])
        let entry = try XCTUnwrap(store.children.first { $0.kind == .vssEntry })
        XCTAssertEqual(NvramVariableHistory.of(entry, in: store, reader: reader)?.versions.map(\.state),
                       [.superseded, .deleted])
    }

    /// An NVAR chain is one variable: the head names it, the links carry
    /// its later values, the last is current. A superseded whole entry —
    /// valid bit cleared — is read for its name too.
    func testAnNVARVariablesChainAndSupersededEntriesAreItsHistory() throws {
        let head = TestNVAR.entry(next: UInt32(TestNVAR.entry(data: [0x01]).count), name: "Setup", data: [0x01])
        let (store, reader) = nvarStore([
            head,
            TestNVAR.dataEntry(data: [0x03]),
            TestNVAR.supersededEntry(name: "Lang", data: [0x65, 0x6E]),
            TestNVAR.entry(name: "Lang", data: [0x64, 0x65]),
        ])
        let entries = store.children.filter { $0.kind == .nvarEntry }
        let setup = try XCTUnwrap(NvramVariableHistory.of(entries[1], in: store, reader: reader))
        XCTAssertEqual(setup.name, "Setup")
        XCTAssertEqual(setup.versions.map(\.state), [.superseded, .current])
        XCTAssertEqual(setup.versions.map { reader.bytes($0.value) }, [[0x01], [0x03]])

        let lang = try XCTUnwrap(NvramVariableHistory.of(entries[2], in: store, reader: reader))
        XCTAssertEqual(entries[2].name, "Invalid")
        XCTAssertEqual(lang.versions.map(\.state), [.superseded, .current])
        XCTAssertEqual(lang.versions.map { reader.bytes($0.value) }, [[0x65, 0x6E], [0x64, 0x65]])
    }

    /// What a tree can leave out: each replaced copy, standing behind the
    /// current one; a deleted variable keeps its last copy; a variable with
    /// one copy, and every current one, stays.
    func testSupersededCopiesStandBehindTheCopyThatReplacedThem() throws {
        let (store, reader) = vssStore([
            TestNVRAM.vssVariable(name: "BootOrder", state: Self.marked),
            TestNVRAM.vssVariable(name: "Gone", state: Self.marked),
            TestNVRAM.vssVariable(name: "BootOrder", state: Self.marked),
            TestNVRAM.vssVariable(name: "Gone", state: Self.marked),
            TestNVRAM.vssVariable(name: "Lang"),
            TestNVRAM.vssVariable(name: "BootOrder"),
        ])
        let e = store.children.filter { $0.kind == .vssEntry }.map(\.id)
        XCTAssertEqual(NvramVariableHistory.supersededCopies(in: store, reader: reader),
                       [e[0]: e[5], e[2]: e[5], e[1]: e[3]])
    }

    /// The bytes that differ, as runs over the length both copies have, and
    /// the sizes.
    func testAChangeIsItsSizesAndTheRunsThatDiffer() throws {
        let (store, reader) = vssStore([
            TestNVRAM.vssVariable(name: "Setup", data: [0, 0, 0, 0, 0, 0], state: Self.marked),
            TestNVRAM.vssVariable(name: "Setup", data: [0, 1, 1, 0, 2, 0, 9]),
        ])
        let entry = try XCTUnwrap(store.children.first { $0.kind == .vssEntry })
        let versions = try XCTUnwrap(NvramVariableHistory.of(entry, in: store, reader: reader)).versions
        let change = try XCTUnwrap(NvramVariableHistory.change(from: versions[0], to: versions[1], reader: reader))

        XCTAssertEqual(change.oldSize, 6)
        XCTAssertEqual(change.newSize, 7)
        XCTAssertEqual(change.changed, [1..<3, 4..<5])
        XCTAssertEqual(change.changedBytes, 3)
        XCTAssertFalse(change.isNone)
        XCTAssertTrue(try XCTUnwrap(NvramVariableHistory.change(from: versions[0], to: versions[0], reader: reader)).isNone)
    }
}
