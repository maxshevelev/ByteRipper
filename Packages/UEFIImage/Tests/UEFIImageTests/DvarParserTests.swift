import XCTest
@testable import UEFIImage

/// Dell's DVAR store (§9), built byte for byte: every field after the
/// signature is stored as its complement.
final class DvarParserTests: XCTestCase {
    static let namespace = KnownGUIDs.guid("417ACEE0-6FA9-4A82-99D7-F9B1DD271E48")

    /// An entry: state, flags, type and attributes, the namespace id, the
    /// namespace's GUID when the entry declares it, then an 8-bit name id and
    /// data size, and the data — complemented as the store keeps them.
    static func entry(state: UInt8, declares: Bool = false, namespaceId: UInt8 = 1,
                      nameId: UInt8, data: [UInt8], type: UInt8 = DVAR.nameId8Size8) -> [UInt8] {
        let flags = declares ? DVAR.flagNameId | DVAR.flagNamespaceGuid : DVAR.flagNameId
        var bytes: [UInt8] = [0xFF - state, 0xFF - flags, 0xFF - type, 0xFF - 0x07, 0xFF - namespaceId]
        if declares { bytes += namespace.bytes }
        bytes += [0xFF - nameId, 0xFF - UInt8(data.count)]
        return bytes + data
    }

    /// `DVAR`, the complemented size and flags, the entries, erased bytes.
    static func store(_ entries: [[UInt8]], size: Int = 0x100) -> [UInt8] {
        var bytes = Array("DVAR".utf8)
        let sizeC = 0xFFFF_FFFF - UInt32(size)
        bytes += (0..<4).map { UInt8(truncatingIfNeeded: sizeC >> (8 * $0)) }
        bytes.append(0xFF - 0x83)
        bytes += entries.flatMap { $0 }
        return bytes + [UInt8](repeating: 0xFF, count: max(0, size - bytes.count))
    }

    /// A store in a raw area, between erased bytes, as the scan finds it.
    private func parse(_ store: [UInt8]) -> (UEFIImage, UEFINode?) {
        let bytes = [UInt8](repeating: 0xFF, count: 0x40) + store + [UInt8](repeating: 0xFF, count: 0x40)
        let image = UEFIParser.parse(bytes)
        return (image, image.allNodes.first { $0.kind == .dvarStore })
    }

    /// The entries the reference shows: a declaration of the namespace, a
    /// copy no longer stored, the current one under the namespace's GUID, and
    /// the free space after them.
    func testAStoresEntriesAreReadAsTheReferenceReadsThem() throws {
        let (image, found) = parse(Self.store([
            Self.entry(state: DVAR.deleted, declares: true, nameId: 0x40, data: [1]),
            Self.entry(state: DVAR.deleted, nameId: 0x40, data: [2]),
            Self.entry(state: DVAR.stored, nameId: 0x40, data: [3, 3]),
        ]))
        let store = try XCTUnwrap(found)
        XCTAssertEqual(store.range, 0x40..<0x140)
        XCTAssertEqual(store.header.count, 9)
        XCTAssertEqual(store.children.map(\.kind), [.dvarEntry, .dvarEntry, .dvarEntry, .freeSpace])
        XCTAssertEqual(store.children.prefix(3).map(\.subtype), [
            UEFITypes.Sub.namespaceGuidDvarEntry, UEFITypes.Sub.invalidDvarEntry, UEFITypes.Sub.nameIdDvarEntry,
        ])
        XCTAssertEqual(store.children.prefix(3).map(\.name), ["40", "Invalid", "40"])
        XCTAssertEqual(store.children[2].guid, Self.namespace, "named by the namespace another entry declared")
        XCTAssertEqual(store.children[0].header.count, 5 + 16 + 2)
        XCTAssertEqual(store.children[2].body.count, 2)
        XCTAssertTrue(image.diagnostics.isEmpty)
        XCTAssertEqual(store.uefiItemType, UEFITypes.Item.dellDvarStore.rawValue)
    }

    /// A variable filed under a namespace nobody declared is Invalid, and
    /// said to be.
    func testAnUndeclaredNamespaceIsReported() throws {
        let (image, found) = parse(Self.store([
            Self.entry(state: DVAR.stored, namespaceId: 9, nameId: 0x10, data: [1]),
        ]))
        let entry = try XCTUnwrap(found?.children.first)
        XCTAssertEqual(entry.name, "Invalid")
        XCTAssertEqual(entry.subtype, UEFITypes.Sub.nameIdDvarEntry)
        XCTAssertEqual(image.diagnostics.map(\.kind), [.dvarNamespaceMissing])
    }

    /// An entry of a type nobody has seen ends what can be read: the rest is
    /// padding, and the store says so once.
    func testAnEntryOfUnknownShapeEndsTheWalk() throws {
        let (image, found) = parse(Self.store([
            Self.entry(state: DVAR.stored, declares: true, nameId: 0x40, data: [1]),
            Self.entry(state: DVAR.stored, nameId: 0x41, data: [2], type: 0x07),
        ]))
        let store = try XCTUnwrap(found)
        XCTAssertEqual(store.children.map(\.kind), [.dvarEntry, .padding])
        XCTAssertEqual(store.children.last?.range.upperBound, store.range.upperBound)
        XCTAssertEqual(image.diagnostics.map(\.kind), [.unknownDvarEntry])
    }

    /// `DVAR` with a size that does not fit, or entries that run past the
    /// store, is not a store — and no defect either.
    func testASignatureThatIsNotAStoreLeavesNothing() {
        var tooBig = Self.store([], size: 0x20)
        tooBig[4] = 0x00                       // a size far past the area
        XCTAssertNil(parse(tooBig).1)
        let cut = Self.store([Self.entry(state: DVAR.stored, declares: true, nameId: 1, data: [UInt8](repeating: 0, count: 40))], size: 0x30)
        let (image, found) = parse(cut)
        XCTAssertNil(found)
        XCTAssertTrue(image.diagnostics.isEmpty)
    }

    /// A copy is current when its state is stored; the others are its
    /// history, the declaration's value among them.
    func testTheStoresCopiesAreCountedAndAreAHistory() throws {
        let bytes = Self.store([
            Self.entry(state: DVAR.deleted, declares: true, nameId: 0x40, data: [1]),
            Self.entry(state: DVAR.deleted, nameId: 0x40, data: [2]),
            Self.entry(state: DVAR.stored, nameId: 0x40, data: [3]),
            Self.entry(state: DVAR.deleted, nameId: 0x50, data: [4]),
        ])
        let image = UEFIParser.parse(bytes)
        let store = try XCTUnwrap(image.allNodes.first { $0.kind == .dvarStore })
        let reader = ImageReader(bytes)
        let fill = try XCTUnwrap(NvramStoreFill.of(store, reader: reader))
        XCTAssertEqual([fill.current, fill.superseded, fill.deleted], [1, 2, 1])

        let history = try XCTUnwrap(NvramVariableHistory.of(store.children[1], in: store, reader: reader))
        XCTAssertEqual(history.name, "40")
        XCTAssertEqual(history.guid, Self.namespace)
        XCTAssertEqual(history.versions.map(\.state), [.superseded, .superseded, .current])
        XCTAssertEqual(history.versions.map { reader.bytes($0.value) }, [[1], [2], [3]])
        XCTAssertEqual(NvramVariableHistory.variable(of: store.children[3], in: store, reader: reader)?.name, "50")
    }
}
