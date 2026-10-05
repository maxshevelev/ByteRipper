import UEFIImage
import XCTest
@testable import UEFITool

/// The search over the tree's rows: what a query matches, the order the walk
/// offers rows in — down before across, round once — what it asks to be read
/// first, and what it has opened and owes a closing.
final class UEFITreeSearchTests: XCTestCase {
    // MARK: - A tree as a table

    /// A tree given as `path: children`, where a branch not in `read` has not
    /// been read: it lists nothing until `expand` says it has been.
    private final class Table {
        var children: [NodeID: [NodeID]]
        var read: Set<NodeID>
        var topRows: [NodeID]

        init(top: Int, _ children: [[Int]: Int], read: Set<[Int]>? = nil) {
            topRows = (0..<top).map { NodeID([$0]) }
            self.children = [:]
            for (path, count) in children {
                self.children[NodeID(path)] = (0..<count).map { NodeID(path + [$0]) }
            }
            // Unless told which, every branch with a row of its own is read.
            let all = Set(topRows.map(\.path)).union(children.keys)
            self.read = Set((read ?? all).map { NodeID($0) })
        }

        var source: UEFITreeSearchSource {
            UEFITreeSearchSource(topRows: { self.topRows }, listedChildren: { self.listedChildren(of: $0) })
        }

        func listedChildren(of id: NodeID) -> [NodeID]? {
            guard read.contains(id) || children[id] == nil else { return nil }
            return children[id] ?? []
        }

        func expand(_ id: NodeID) { read.insert(id) }
    }

    /// Everything the walk offers from `origin`, expanding what it asks for.
    private func walk(_ table: Table, from origin: NodeID?, _ direction: UEFITreeSearch.Direction,
                      limit: Int = 100) -> (rows: [String], expanded: [String], wrapped: Bool) {
        var search = UEFITreeSearch(origin: origin, direction: direction)
        var rows: [String] = [], expanded: [String] = []
        while rows.count < limit {
            switch search.advance(in: table.source) {
            case .candidate(let id): rows.append(id.description)
            case .expand(let id):
                expanded.append(id.description)
                table.expand(id)
            case .exhausted: return (rows, expanded, search.wrapped)
            }
        }
        return (rows, expanded, search.wrapped)
    }

    /// 0 ─ 0.0, 0.1 ─ 0.1.0     1     2 ─ 2.0
    private func sample(read: Set<[Int]>? = nil) -> Table {
        Table(top: 3, [[0]: 2, [0, 1]: 1, [2]: 1], read: read)
    }

    // MARK: - The order

    func testForwardGoesDownBeforeAcrossAndComesRoundToTheOrigin() {
        let result = walk(sample(), from: NodeID([0, 1]), .forward)
        XCTAssertEqual(result.rows, ["0.1.0", "1", "2", "2.0", "0", "0.0", "0.1"],
                       "the origin is the last row offered, once the walk has come round")
        XCTAssertTrue(result.wrapped)
    }

    func testBackwardGoesThroughWhatIsInARowBeforeTheRow() {
        let result = walk(sample(), from: NodeID([2]), .backward)
        XCTAssertEqual(result.rows, ["1", "0.1.0", "0.1", "0.0", "0", "2.0", "2"])
        XCTAssertTrue(result.wrapped)
    }

    func testNoOriginStartsAtAnEndAndDoesNotComeRound() {
        XCTAssertEqual(walk(sample(), from: nil, .forward).rows, ["0", "0.0", "0.1", "0.1.0", "1", "2", "2.0"])
        XCTAssertEqual(walk(sample(), from: nil, .backward).rows, ["2.0", "2", "1", "0.1.0", "0.1", "0.0", "0"])
        XCTAssertFalse(walk(sample(), from: nil, .forward).wrapped)
    }

    func testAnOriginThatIsNoLongerThereStillEndsTheWalk() {
        let result = walk(sample(), from: NodeID([9]), .forward)
        XCTAssertEqual(result.rows.count, 7, "every row once, and then it stops")
    }

    func testAnEmptyTreeOffersNothing() {
        XCTAssertEqual(walk(Table(top: 0, [:]), from: nil, .forward).rows, [])
        XCTAssertEqual(walk(Table(top: 0, [:]), from: NodeID([0]), .backward).rows, [])
    }

    // MARK: - What has to be read first

    func testAnUnreadBranchIsAskedForBeforeTheWalkGoesInto() {
        let table = sample(read: [[0], [2]])      // 0.1 is not read, nor 1
        let result = walk(table, from: NodeID([0, 0]), .forward)
        XCTAssertEqual(result.expanded, ["0.1"], "0.1 holds a row, and is asked for as the walk reaches it")
        XCTAssertEqual(Array(result.rows.prefix(3)), ["0.1", "0.1.0", "1"])
    }

    func testBackWardsAnUnreadBranchIsReadBeforeTheRowAfterIt() {
        let table = sample(read: [[0], [2]])
        let result = walk(table, from: NodeID([1]), .backward)
        XCTAssertEqual(result.expanded.first, "0.1", "its last row comes before the row itself")
        XCTAssertEqual(Array(result.rows.prefix(2)), ["0.1.0", "0.1"])
    }

    // MARK: - What a query matches

    private func file(_ name: String, guid: String? = nil, type: UInt8 = 0x07) -> UEFINode {
        UEFINode(kind: .file, subtype: type, name: name, guid: guid.flatMap(EFIGUID.init),
                 header: 0..<0x18, body: 0x18..<0x40)
    }

    func testTextIsASubstringOfTheNameWhateverTheCase() {
        let node = file("SetupUtility")
        XCTAssertTrue(UEFITreeQuery(text: "setup").matches(node, name: "SetupUtility"))
        XCTAssertTrue(UEFITreeQuery(text: "UTIL ").matches(node, name: "x"), "the space after it is not part of it")
        XCTAssertFalse(UEFITreeQuery(text: "smm").matches(node, name: "SetupUtility"))
    }

    func testTheRowsNameAndTheGUIDItStandsForAreBothFound() {
        let node = file("DxeCore", guid: "D6A2CB7F-6A18-4E2F-B43B-9920A733700A")
        let query: (String) -> Bool = { UEFITreeQuery(text: $0).matches(node, name: "DXE Core") }
        XCTAssertTrue(query("dxe core"), "the catalogue's name, as the row says it")
        XCTAssertTrue(query("DxeCore"), "the node's own")
        XCTAssertTrue(query("6a18-4e2f"))
        XCTAssertTrue(query("d6a2cb7f6a18"), "hex without the dashes")
        XCTAssertFalse(query("zzzz"))
    }

    func testTypeAndSubtypeNarrowTheName() {
        let driver = file("Smm", type: 0x07), pei = file("Smm", type: 0x06)
        let query = UEFITreeQuery(text: "smm", type: UEFITypes.Item.file.rawValue, subtype: 0x07)
        XCTAssertTrue(query.matches(driver, name: "Smm"))
        XCTAssertFalse(query.matches(pei, name: "Smm"))
        let section = UEFINode(kind: .section, subtype: 0x10, name: "Smm", header: 0..<4, body: 4..<8)
        XCTAssertFalse(query.matches(section, name: "Smm"), "not the type")
    }

    func testASubtypeMeansNothingWithoutAFileOrASectionType() {
        let volume = UEFINode(kind: .volume, name: "FFS", header: 0..<0x48, body: 0x48..<0x100)
        let query = UEFITreeQuery(type: UEFITypes.Item.volume.rawValue, subtype: 0x07)
        XCTAssertTrue(query.matches(volume, name: "FFS"))
        XCTAssertFalse(UEFITreeQuery.hasSubtypes(UEFITypes.Item.volume.rawValue))
        XCTAssertTrue(UEFITreeQuery.hasSubtypes(UEFITypes.Item.section.rawValue))
    }

    func testAQueryThatAsksForNothingIsEmpty() {
        XCTAssertTrue(UEFITreeQuery().isEmpty)
        XCTAssertTrue(UEFITreeQuery(text: "  ").isEmpty)
        XCTAssertFalse(UEFITreeQuery(type: 0x42).isEmpty)
        XCTAssertFalse(UEFITreeQuery(text: "a").isEmpty)
    }

    func testTheChoicesAreTheColumnsOwnWords() {
        XCTAssertEqual(UEFITreeSearchChoices.types.first, .init(code: 0x3D, name: "Capsule"))
        XCTAssertEqual(UEFITreeSearchChoices.types.last?.name, "AMD microcode")
        XCTAssertTrue(UEFITreeSearchChoices.types.contains(.init(code: 0x42, name: "File")))
        XCTAssertTrue(UEFITreeSearchChoices.subtypes(of: 0x42).contains(.init(code: 0x07, name: "Driver")))
        XCTAssertTrue(UEFITreeSearchChoices.subtypes(of: 0x43).contains(.init(code: 0x10, name: "PE32 image")))
        XCTAssertEqual(UEFITreeSearchChoices.subtypes(of: 0x41), [])
        XCTAssertEqual(UEFITreeSearchChoices.subtypes(of: nil), [])
    }

    // MARK: - What the search opened

    func testARowAboveTheNextMatchStaysAndTheRestIsShutDeepestFirst() {
        var openings = UEFISearchOpenings()
        [NodeID([0]), NodeID([0, 1]), NodeID([0, 1, 2]), NodeID([3])].forEach { openings.record($0) }

        XCTAssertEqual(openings.closings(whenLandingOn: NodeID([0, 1, 5])), [NodeID([0, 1, 2]), NodeID([3])],
                       "0 and 0.1 are above the match; 0.1.2 and 3 are not")
        XCTAssertEqual(openings.closings(whenLandingOn: NodeID([0, 1])), [NodeID([0, 1, 2]), NodeID([3])],
                       "the match itself stays open")
        let all = openings.closings(whenLandingOn: NodeID([7]))
        XCTAssertEqual(Array(all.prefix(2)), [NodeID([0, 1, 2]), NodeID([0, 1])], "deepest first")
        XCTAssertEqual(Set(all), [NodeID([0, 1, 2]), NodeID([0, 1]), NodeID([0]), NodeID([3])])
    }

    func testARowTheReaderTookOverOrThatIsReleasedIsNotShut() {
        var openings = UEFISearchOpenings()
        openings.record(NodeID([0]))
        openings.record(NodeID([0, 1]))
        openings.record(NodeID([0, 1]))
        XCTAssertEqual(openings.opened.count, 2, "once")

        openings.forget(NodeID([0, 1]))
        XCTAssertEqual(openings.closings(whenLandingOn: NodeID([4])), [NodeID([0])])
        openings.release()
        XCTAssertTrue(openings.isEmpty)
        XCTAssertEqual(openings.closings(whenLandingOn: NodeID([4])), [])
    }
}
