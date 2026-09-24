import ByteRipperCore
import XCTest
@testable import ByteRipper

/// §21.7 a piece that remembers the file it came from: how a link travels with
/// the content, what a joined image's bytes are painted against, Revert Segment
/// (both lengths), and the two guards — a source that changed on disk, and a
/// save that would write over one.
@MainActor
final class SegmentLinkTests: XCTestCase {
    override func setUp() {
        super.setUp()
        AppDefaults.store.set(1, forKey: WordSize.userDefaultsKey)
    }

    // MARK: - The arithmetic (a partition on its own)

    private let source = SegmentSourceID(raw: 0)
    private let other = SegmentSourceID(raw: 1)

    private func linked(_ range: Range<UInt64>) -> SegmentLink {
        SegmentLink(source: source, sourceRange: range)
    }

    /// One piece of 16 bytes, linked to the whole of a 16-byte file.
    private func wholeFile(_ size: UInt64 = 16) -> Segmentation {
        Segmentation(contentSize: size,
                     pieces: [Piece(start: 0, name: "chip.bin", link: linked(0..<size))])
    }

    /// A cut splits the link with the piece: both halves keep the source, at the
    /// offsets they sit at in it (§21.7).
    func testACutSplitsTheLinkWithThePiece() {
        var partition = wholeFile()
        partition.addCut(at: 6)

        XCTAssertEqual(partition.segments[0].link, linked(0..<6),
                       "the earlier half keeps the source's first six bytes")
        XCTAssertEqual(partition.segments[1].link, linked(6..<16),
                       "and the new piece opens six bytes into the same file")
    }

    /// Merging keeps the absorbing piece's link and grows its extent by what it
    /// absorbed, the way it keeps that piece's name (§21.7).
    func testMergingGrowsTheAbsorbingPiecesExtent() {
        var partition = wholeFile()
        partition.addCut(at: 6)
        partition.removePiece(at: 1)

        XCTAssertEqual(partition.segments.count, 1)
        XCTAssertEqual(partition.segments[0].link, linked(0..<16),
                       "S0 absorbed S1's bytes, so its extent in the file covers them again")
    }

    /// Merging S0 shifts the survivor's extent back by S0's length — exactly
    /// right when both halves came from one file (§21.7).
    func testMergingTheFirstPieceShiftsTheSurvivorsExtentBack() {
        var partition = wholeFile()
        partition.addCut(at: 6)
        partition.removePiece(at: 0)

        XCTAssertEqual(partition.segments[0].range, 0..<16)
        XCTAssertEqual(partition.segments[0].link, linked(0..<16),
                       "what was S1 reopens at the file start, and so does its extent")
    }

    /// A survivor whose source has no room for the bytes it absorbed loses its
    /// link rather than claim offsets before the file's start (§21.7).
    func testMergingTheFirstPieceDropsALinkThatWouldUnderflow() {
        var partition = Segmentation(contentSize: 16, pieces: [
            Piece(start: 0, name: "a", link: nil),
            Piece(start: 8, name: "b", link: SegmentLink(source: other, sourceRange: 0..<8)),
        ])
        partition.removePiece(at: 0)

        XCTAssertNil(partition.segments[0].link,
                     "the piece now opens eight bytes before anything its source holds")
    }

    /// A cut moved slides the extent of the piece that opens there and moves the
    /// far end of the piece before it (§21.7).
    func testMovingACutSlidesBothExtents() {
        var partition = wholeFile()
        partition.addCut(at: 6)
        partition.moveCut(from: 6, to: 10)

        XCTAssertEqual(partition.segments[0].link, linked(0..<10))
        XCTAssertEqual(partition.segments[1].link, linked(10..<16))
    }

    /// An insert leaves every link alone: the added bytes have no source and the
    /// rest of the piece is off by the insert's length, so both read as
    /// modified — which is what an insert already does to a plain file (§21.7).
    func testAnInsertLeavesTheLinksAlone() {
        var partition = wholeFile()
        partition.addCut(at: 6)
        partition.apply(.insert(at: 2, length: 4), newSize: 20)

        XCTAssertEqual(partition.segments[0].range, 0..<10, "the piece grew with the insert")
        XCTAssertEqual(partition.segments[0].link, linked(0..<6), "but its extent did not")
        XCTAssertEqual(partition.segments[1].link, linked(6..<16),
                       "and the piece after it moved whole, extent untouched")
    }

    /// A run that lost its head opens that much further into its source; a run
    /// that kept its head keeps its extent (§21.7).
    func testADeleteMovesOnlyATrimmedHead() {
        var partition = wholeFile()
        partition.addCut(at: 8)
        // Takes the first three bytes of S1, leaving the cut where it is.
        partition.apply(.delete(range: 8..<11), newSize: 13)

        XCTAssertEqual(partition.segments[0].link, linked(0..<8),
                       "S0 still opens where it did, so its extent is unchanged")
        XCTAssertEqual(partition.segments[1].link, linked(11..<16),
                       "S1 lost its first three bytes, so it opens three bytes later in the file")
    }

    /// A delete before a cut leaves the pieces after it as themselves: they
    /// shift left, and each keeps its own name and its own link (§21.2, §21.7).
    func testADeleteBeforeACutLeavesTheLaterPiecesAlone() {
        var partition = Segmentation(contentSize: 16, pieces: [
            Piece(start: 0, name: "a", link: linked(0..<8)),
            Piece(start: 8, name: "b", link: SegmentLink(source: other, sourceRange: 0..<8)),
        ])
        partition.apply(.delete(range: 2..<4), newSize: 14)

        XCTAssertEqual(partition.segments.map(\.name), ["a", "b"])
        XCTAssertEqual(partition.segments[1].range, 6..<14)
        XCTAssertEqual(partition.segments[1].link,
                       SegmentLink(source: other, sourceRange: 0..<8),
                       "the piece moved whole, so its extent in its own file did not move")
    }

    /// Reset drops every link: a fresh file is one piece of itself (§21.7).
    func testResetDropsTheLinks() {
        var partition = wholeFile()
        partition.reset(size: 16, name: "other.bin")
        XCTAssertNil(partition.segments[0].link)
    }

    /// An edit made the way the app makes one: through the pane, so the
    /// partition follows the content (§21.2). A direct write to the document
    /// would leave the partition behind and prove nothing about either.
    private func write(_ pane: PaneViewModel, at offset: UInt64, _ bytes: [UInt8]) throws {
        pane.document?.setSelection(SelectionModel.empty(at: offset, fileSize: pane.fileSize))
        try pane.pasteWrite(bytes)
    }

    private func insert(_ pane: PaneViewModel, at offset: UInt64, _ bytes: [UInt8]) throws {
        pane.document?.setSelection(SelectionModel.empty(at: offset, fileSize: pane.fileSize))
        try pane.pasteInsert(bytes)
    }

    // MARK: - A join links both sides

    /// A join links the donor's piece to the donor file *and* the content the
    /// pane already held to the file the join takes away from it (§21.7, §22.2).
    func testAJoinLinksBothSides() throws {
        let pane = PaneViewModel()
        let original = try tempFile([UInt8](repeating: 0xAA, count: 16))
        let donorURL = try tempFile([UInt8](repeating: 0xBB, count: 8))
        try pane.open(url: original)

        try pane.join(contentsOf: donorURL, at: .end)

        let pieces = pane.segmentStore.segments
        XCTAssertEqual(pieces.count, 2)
        XCTAssertEqual(pane.segmentSource(of: pieces[0])?.url.lastPathComponent,
                       original.lastPathComponent,
                       "the content the pane already held is linked to the file it came from")
        XCTAssertEqual(pieces[0].link?.sourceRange, 0..<16)
        XCTAssertEqual(pane.segmentSource(of: pieces[1])?.url.lastPathComponent,
                       donorURL.lastPathComponent)
        XCTAssertEqual(pieces[1].link?.sourceRange, 0..<8)
        pane.close()
    }

    /// An append names and links the *last* piece, whichever piece the seam's
    /// cut split — not piece 1, which is only the last one in a dump that was
    /// never cut (§21.7).
    func testAnAppendLinksTheLastPieceOfAPartitionedDump() throws {
        let pane = PaneViewModel()
        let original = try tempFile([UInt8](repeating: 0xAA, count: 16))
        let donorURL = try tempFile([UInt8](repeating: 0xBB, count: 8))
        try pane.open(url: original)
        XCTAssertTrue(pane.segmentStore.addCut(at: 8), "the dump is cut before the join")

        try pane.join(contentsOf: donorURL, at: .end)

        let pieces = pane.segmentStore.segments
        XCTAssertEqual(pieces.count, 3)
        XCTAssertEqual(pieces[2].name, donorURL.lastPathComponent,
                       "the joined bytes are the last piece, and wear the donor's name")
        XCTAssertEqual(pane.segmentSource(of: pieces[2])?.url.lastPathComponent,
                       donorURL.lastPathComponent)
        XCTAssertEqual(pieces[1].name, "", "the pane's own pieces keep the names they had")
        pane.close()
    }

    /// Undoing a join gives the file back, so the links it made go with it
    /// (§21.7): the partition is restored by snapshot, links and all.
    func testUndoingAJoinTakesTheLinksWithIt() throws {
        let pane = PaneViewModel()
        let original = try tempFile([UInt8](repeating: 0xAA, count: 16))
        let donorURL = try tempFile([UInt8](repeating: 0xBB, count: 8))
        try pane.open(url: original)
        try pane.join(contentsOf: donorURL, at: .end)

        _ = try pane.undo()

        XCTAssertEqual(pane.segmentStore.segments.count, 1)
        XCTAssertNil(pane.segmentStore.segments[0].link,
                     "the pane is attached to its file again, so nothing needs a link")
        XCTAssertFalse(pane.isUntitled)
        pane.close()
    }

    // MARK: - What the bytes are painted against

    /// The bug this feature exists for: an image a join left had no baseline at
    /// all, so a patch in it was not painted modified. Now each half is measured
    /// against its own file (§21.7).
    func testAJoinedImagePaintsEachHalfAgainstItsOwnFile() throws {
        let pane = PaneViewModel()
        let original = try tempFile([UInt8](repeating: 0xAA, count: 16))
        let donorURL = try tempFile([UInt8](repeating: 0xBB, count: 8))
        try pane.open(url: original)
        try pane.join(contentsOf: donorURL, at: .end)
        XCTAssertTrue(pane.isUntitled, "a join leaves an image with no file of its own")
        XCTAssertTrue(pane.marksModifiedBytes, "and it is still painted against something")

        // A byte patched in each half.
        try write(pane, at: 2, [0x01])
        try write(pane, at: 20, [0x02])

        let states = pane.hexByteStates(in: 0..<24)
        XCTAssertTrue(states[2].isModified, "the patch in the first chip's half is red")
        XCTAssertTrue(states[20].isModified, "and so is the one in the second chip's")
        XCTAssertFalse(states[3].isModified, "bytes that still match their source are not")
        XCTAssertFalse(states[19].isModified)
        pane.close()
    }

    /// Once the image has a file of its own, that file answers the question
    /// again: red means "not saved yet", and the links stay for everything else
    /// (§21.7).
    func testSavingHandsTheBaselineBackToTheSavedFile() throws {
        let pane = PaneViewModel()
        let original = try tempFile([UInt8](repeating: 0xAA, count: 16))
        let donorURL = try tempFile([UInt8](repeating: 0xBB, count: 8))
        try pane.open(url: original)
        try pane.join(contentsOf: donorURL, at: .end)
        try write(pane, at: 2, [0x01])

        let joined = try tempFile([])
        try pane.saveAs(to: joined)

        XCTAssertFalse(pane.hexByteStates(in: 0..<24)[2].isModified,
                       "the patch is on disk now, so nothing is unsaved")
        XCTAssertNotNil(pane.segmentStore.segments[0].link,
                        "but the piece still knows where its bytes came from")
        pane.close()
    }

    /// A piece nothing brought in is never painted modified in an untitled
    /// image — the rule an untitled document always followed (§21.7).
    func testAPieceWithNoLinkIsUnmarkedInAnUntitledImage() throws {
        let pane = PaneViewModel()
        pane.openUntitled()
        try insert(pane, at: 0, [UInt8](repeating: 0xAA, count: 16))
        let donorURL = try tempFile([UInt8](repeating: 0xBB, count: 8))
        try pane.join(contentsOf: donorURL, at: .end)

        let states = pane.hexByteStates(in: 0..<24)
        XCTAssertFalse(states[2].isModified, "the bytes that came from nowhere are unmarked")
        XCTAssertFalse(states[19].isModified, "and the donor's still match its file")
        try write(pane, at: 19, [0x02])
        XCTAssertTrue(pane.hexByteStates(in: 0..<24)[19].isModified,
                      "a patch in the donor's half is measured against the donor")
        pane.close()
    }

    // MARK: - How a piece stands to its source

    func testTheLinkStateFollowsThePiece() throws {
        let pane = PaneViewModel()
        let original = try tempFile([UInt8](repeating: 0xAA, count: 16))
        let donorURL = try tempFile([UInt8](repeating: 0xBB, count: 8))
        try pane.open(url: original)
        try pane.join(contentsOf: donorURL, at: .end)

        XCTAssertEqual(pane.segmentLinkState(of: pane.segmentStore.segments[1]), .matching)

        try write(pane, at: 20, [0x02])
        XCTAssertEqual(pane.segmentLinkState(of: pane.segmentStore.segments[1]), .edited,
                       "a patched piece no longer is what its file holds")

        try insert(pane, at: 20, [0x03])
        XCTAssertEqual(pane.segmentLinkState(of: pane.segmentStore.segments[1]),
                       .lengthChanged(piece: 9, source: 8),
                       "and an insert leaves it longer than the stretch it came from")
        pane.close()
    }

    // MARK: - Revert Segment

    /// The plain case: the piece goes back to its file's bytes, in one undo
    /// step, and the link stays (§21.7).
    func testRevertSegmentPutsThePieceBack() throws {
        let pane = PaneViewModel()
        let original = try tempFile([UInt8](repeating: 0xAA, count: 16))
        let donorURL = try tempFile([UInt8](repeating: 0xBB, count: 8))
        try pane.open(url: original)
        try pane.join(contentsOf: donorURL, at: .end)
        try write(pane, at: 20, [0x02])

        try pane.revertSegment(pane.segmentStore.segments[1])

        XCTAssertEqual(try pane.document?.read(at: 20, length: 1), [0xBB])
        XCTAssertEqual(pane.segmentLinkState(of: pane.segmentStore.segments[1]), .matching)
        XCTAssertNotNil(pane.segmentStore.segments[1].link, "the bytes are still that file's")
        XCTAssertEqual(pane.fileSize, 24, "a same-length revert moves nothing")
        pane.close()
    }

    /// A revert that restores the source's length adds the difference at the
    /// piece's tail — and the cut that closed it moves with it, so the restored
    /// bytes belong to the piece that was reverted, not to the one after it
    /// (§21.7).
    func testRevertSegmentRestoresTheSourcesLength() throws {
        let pane = PaneViewModel()
        let original = try tempFile([UInt8](repeating: 0xAA, count: 16))
        let donorURL = try tempFile([UInt8](repeating: 0xBB, count: 8))
        try pane.open(url: original)
        // The donor goes in at the start, so there is a piece after it to move.
        try pane.join(contentsOf: donorURL, at: .start)
        // Four bytes cut out of the donor's half: it is now shorter than its file.
        try pane.deleteBytes(in: 2..<6)
        XCTAssertEqual(pane.segmentStore.segments[0].range, 0..<4)

        try pane.revertSegment(pane.segmentStore.segments[0], allowingLengthChange: true)

        XCTAssertEqual(pane.fileSize, 24, "the four bytes are back")
        XCTAssertEqual(pane.segmentStore.segments[0].range, 0..<8,
                       "and they belong to the piece that was reverted")
        XCTAssertEqual(pane.segmentStore.segments[1].range, 8..<24)
        XCTAssertEqual(try pane.document?.read(at: 0, length: 8),
                       [UInt8](repeating: 0xBB, count: 8))
        XCTAssertEqual(pane.segmentLinkState(of: pane.segmentStore.segments[0]), .matching)
        pane.close()
    }

    /// Without the user's agreement a mismatch changes nothing — the same
    /// refusal a replace makes (§21.6, §21.7).
    func testRevertSegmentRefusesALengthChangeItWasNotAllowed() throws {
        let pane = PaneViewModel()
        let original = try tempFile([UInt8](repeating: 0xAA, count: 16))
        let donorURL = try tempFile([UInt8](repeating: 0xBB, count: 8))
        try pane.open(url: original)
        try pane.join(contentsOf: donorURL, at: .start)
        try pane.deleteBytes(in: 2..<6)

        XCTAssertThrowsError(try pane.revertSegment(pane.segmentStore.segments[0])) { error in
            XCTAssertEqual(error as? SegmentReplaceError,
                           .lengthMismatch(pieceLength: 4, donorLength: 8))
        }
        XCTAssertEqual(pane.fileSize, 20, "nothing moved")
        pane.close()
    }

    // MARK: - The two guards

    /// A save that would write over a file some piece came from is refused, and
    /// the panel opens again (§21.7).
    func testSavingOverASourceIsRefused() throws {
        let pane = PaneViewModel()
        let original = try tempFile([UInt8](repeating: 0xAA, count: 16))
        let donorURL = try tempFile([UInt8](repeating: 0xBB, count: 8))
        try pane.open(url: original)
        try pane.join(contentsOf: donorURL, at: .end)

        XCTAssertEqual(pane.linkedSource(at: donorURL)?.url.lastPathComponent,
                       donorURL.lastPathComponent,
                       "the donor is a source, so a save over it has to be stopped")
        XCTAssertEqual(pane.linkedSource(at: original)?.url.lastPathComponent,
                       original.lastPathComponent,
                       "and so is the file the join detached from")
        let elsewhere = try tempFile([])
        XCTAssertNil(pane.linkedSource(at: elsewhere), "any other name is fine")
        pane.close()
    }

    /// A source rewritten on disk is read again, not remembered: the link is to
    /// the file (§21.7). The prompt itself resolves to Keep under XCTest, so
    /// what is pinned here is the baseline that moved underneath it.
    func testASourceRewrittenOnDiskBecomesTheNewBaseline() throws {
        let pane = PaneViewModel()
        let original = try tempFile([UInt8](repeating: 0xAA, count: 16))
        let donorURL = try tempFile([UInt8](repeating: 0xBB, count: 8))
        try pane.open(url: original)
        try pane.join(contentsOf: donorURL, at: .end)
        XCTAssertFalse(pane.hexByteStates(in: 16..<24)[0].isModified)

        try Data([UInt8](repeating: 0xCC, count: 8)).write(to: donorURL)
        pane.segmentSources.invalidate(try XCTUnwrap(pane.segmentStore.segments[1].link).source)

        XCTAssertTrue(pane.hexByteStates(in: 16..<24)[0].isModified,
                      "the dump's bytes are no longer what the file holds there")
        pane.close()
    }
}

/// §21.7 the commands a link brings with it, driven through the real
/// `MainViewController`: the menus that name the source file, the one question a
/// length mismatch asks, and the prompt a source changed on disk raises.
@MainActor
final class SegmentLinkCommandTests: XCTestCase {
    override func setUp() {
        super.setUp()
        AppDefaults.store.set(1, forKey: WordSize.userDefaultsKey)
    }

    override func tearDown() {
        MainViewController.modalResponder = nil
        super.tearDown()
    }

    /// A controller whose active pane holds a 16-byte dump with an 8-byte donor
    /// appended — the image a join leaves, with a link on each half.
    private func makeJoined() throws -> (MainViewController, PaneViewModel, URL) {
        let wc = MainWindowController()
        let controller = try XCTUnwrap(wc.mainViewController)
        let original = try tempFile([UInt8](repeating: 0xAA, count: 16))
        let donorURL = try tempFile([UInt8](repeating: 0xBB, count: 8))
        let pane = controller.windowModel.pane1
        try pane.open(url: original)
        controller.apply(mode: .singleFile)
        wc.window?.layoutIfNeeded()
        try pane.join(contentsOf: donorURL, at: .end)
        addTeardownBlock { @MainActor in
            pane.close()
            wc.close()
        }
        return (controller, pane, donorURL)
    }

    /// The strip's menu offers Revert Segment only where the piece came from a
    /// file, and names the file (§21.7).
    func testTheStripsMenuNamesTheSourceFile() throws {
        let (controller, pane, donorURL) = try makeJoined()
        let menu = try XCTUnwrap(controller.minimapSegmentMenu(mapIndex: 0, pieceIndex: 1,
                                                               point: .zero))
        let titles = menu.items.map(\.title)
        XCTAssertTrue(titles.contains("Revert Segment S1 to “\(donorURL.lastPathComponent)”"),
                      "the item says which file the piece would go back to: \(titles)")
        XCTAssertNotNil(pane.segmentStore.segments[1].link)
    }

    /// A same-length revert runs without asking anything (§21.7).
    func testASameLengthRevertAsksNothing() throws {
        let (controller, pane, _) = try makeJoined()
        pane.document?.setSelection(SelectionModel.empty(at: 20, fileSize: pane.fileSize))
        try pane.pasteWrite([0x02])
        var asked = 0
        MainViewController.modalResponder = { _ in
            asked += 1
            return .alertSecondButtonReturn   // Cancel, if it is ever reached
        }

        XCTAssertTrue(controller.revertPiece(pane.segmentStore.segments[1], of: pane))

        XCTAssertEqual(asked, 0, "the lengths agree, so there is nothing to ask")
        XCTAssertEqual(try pane.document?.read(at: 20, length: 1), [0xBB])
    }

    /// A length mismatch asks, and a Cancel leaves the dump exactly as it was
    /// (§21.7).
    func testALengthMismatchAsksAndCancelChangesNothing() throws {
        let (controller, pane, _) = try makeJoined()
        pane.document?.setSelection(SelectionModel.empty(at: 20, fileSize: pane.fileSize))
        try pane.pasteInsert([0x03])
        var asked = 0
        MainViewController.modalResponder = { _ in
            asked += 1
            return .alertSecondButtonReturn   // Cancel
        }

        XCTAssertFalse(controller.revertPiece(pane.segmentStore.segments[1], of: pane))

        XCTAssertEqual(asked, 1, "the piece is a byte longer than its source, so it asks once")
        XCTAssertEqual(pane.fileSize, 25, "and a Cancel moves nothing")
    }

    /// Agreeing restores the source's length (§21.7).
    func testAgreeingToTheLengthQuestionRestoresTheSource() throws {
        let (controller, pane, _) = try makeJoined()
        pane.document?.setSelection(SelectionModel.empty(at: 20, fileSize: pane.fileSize))
        try pane.pasteInsert([0x03])
        MainViewController.modalResponder = { _ in .alertFirstButtonReturn }   // Restore Length

        XCTAssertTrue(controller.revertPiece(pane.segmentStore.segments[1], of: pane))

        XCTAssertEqual(pane.fileSize, 24)
        XCTAssertEqual(pane.segmentStore.segments[1].range, 16..<24)
        XCTAssertEqual(pane.segmentLinkState(of: pane.segmentStore.segments[1]), .matching)
    }

    /// The source-changed prompt resolves to Keep under XCTest, like every other
    /// blocking prompt: the bytes stay, and only what they are measured against
    /// moved (§21.7).
    func testTheSourceChangedPromptKeepsTheBytesInTests() throws {
        let (controller, pane, donorURL) = try makeJoined()
        try Data([UInt8](repeating: 0xCC, count: 8)).write(to: donorURL)
        let source = try XCTUnwrap(pane.segmentStore.segments[1].link).source
        pane.segmentSources.invalidate(source)

        controller.presentSegmentSourceChange(for: pane, source: source)

        XCTAssertEqual(try pane.document?.read(at: 16, length: 1), [0xBB],
                       "Keep leaves the dump's own bytes alone")
        XCTAssertTrue(pane.hexByteStates(in: 16..<24)[0].isModified,
                      "but they are no longer what the file holds there")
    }

    /// Reload takes the source's new bytes into the dump (§21.7).
    func testTheSourceChangedPromptCanReloadTheSegment() throws {
        let (controller, pane, donorURL) = try makeJoined()
        try Data([UInt8](repeating: 0xCC, count: 8)).write(to: donorURL)
        let source = try XCTUnwrap(pane.segmentStore.segments[1].link).source
        pane.segmentSources.invalidate(source)
        MainViewController.modalResponder = { _ in .alertFirstButtonReturn }   // Reload

        controller.presentSegmentSourceChange(for: pane, source: source)

        XCTAssertEqual(try pane.document?.read(at: 16, length: 8),
                       [UInt8](repeating: 0xCC, count: 8))
        XCTAssertFalse(pane.hexByteStates(in: 16..<24)[0].isModified)
    }
}

/// §21.7 the one boundary rule a length-changing swap needs: the bytes it adds
/// belong to the piece it replaced, so the piece after it moves whole — link
/// and all.
@MainActor
final class SegmentGrowthTests: XCTestCase {
    private let a = SegmentSourceID(raw: 0)
    private let b = SegmentSourceID(raw: 1)

    func testGrowthMovesTheLaterPiecesWhole() {
        var partition = Segmentation(contentSize: 16, pieces: [
            Piece(start: 0, name: "a", link: SegmentLink(source: a, sourceRange: 0..<8)),
            Piece(start: 8, name: "b", link: SegmentLink(source: b, sourceRange: 0..<8)),
        ])

        partition.applyGrowth(of: 0, by: 4, newSize: 20)

        XCTAssertEqual(partition.segments[0].range, 0..<12,
                       "the added bytes are the piece's, not the next one's")
        XCTAssertEqual(partition.segments[1].range, 12..<20)
        XCTAssertEqual(partition.segments[0].link,
                       SegmentLink(source: a, sourceRange: 0..<12),
                       "its extent in its own source grew with it")
        XCTAssertEqual(partition.segments[1].link,
                       SegmentLink(source: b, sourceRange: 0..<8),
                       "and the piece after it moved whole, so its extent did not move")
    }

    /// The last piece has no closing cut: it simply runs to the new end.
    func testGrowingTheLastPieceMovesNothing() {
        var partition = Segmentation(contentSize: 16, pieces: [
            Piece(start: 0, name: "a", link: nil),
            Piece(start: 8, name: "b", link: SegmentLink(source: b, sourceRange: 0..<8)),
        ])

        partition.applyGrowth(of: 1, by: 4, newSize: 20)

        XCTAssertEqual(partition.segments[0].range, 0..<8)
        XCTAssertEqual(partition.segments[1].range, 8..<20)
    }
}

/// §21.7 the guard on every write: nothing the app writes may replace a file a
/// piece came from — not a Save As, not Save Segment…, not Save All as Separate
/// Files… Each refusal sends the panel back up, because the useful answer is
/// another name.
@MainActor
final class SegmentSourceWriteGuardTests: XCTestCase {
    override func setUp() {
        super.setUp()
        AppDefaults.store.set(1, forKey: WordSize.userDefaultsKey)
    }

    /// A controller whose active pane holds a dump with `donor.bin` appended —
    /// so both halves have a source, and both names are ones no write may take.
    private func makeJoined() throws -> (MainViewController, PaneViewModel, URL) {
        let controller = MainViewController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        // ARC owns this window; letting AppKit release it on close as well is an
        // over-release, and it crashes the test host at the pool pop.
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        let original = try tempFile([UInt8](repeating: 0xAA, count: 16))
        let donorURL = try tempFile([UInt8](repeating: 0xBB, count: 8))
        let pane = controller.windowModel.pane1
        try pane.open(url: original)
        controller.apply(mode: .singleFile)
        window.layoutIfNeeded()
        try pane.join(contentsOf: donorURL, at: .end)
        addTeardownBlock { @MainActor in
            pane.close()
            window.close()
        }
        return (controller, pane, donorURL)
    }

    private func makeOutputDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SourceGuard-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    /// The form's save seams, with the write captured rather than run.
    private func wire(_ controller: MainViewController,
                      _ written: @escaping ([SegmentWriter.Part], URL) -> Void) {
        controller.segmentWriteConfirm = { _ in .alertFirstButtonReturn }
        controller.segmentWriteRunner = { parts, _, directory in written(parts, directory) }
    }

    /// Save Segment… onto a segment's source is refused and the panel opens
    /// again; the second, free name is the one that gets written (§21.7).
    func testSaveSegmentAsksAgainForAName() throws {
        let (controller, pane, donorURL) = try makeJoined()
        let directory = try makeOutputDirectory()
        var writtenTo: URL?
        wire(controller) { _, dir in writtenTo = dir }

        // First the donor's own name — which no write may take — then a free one.
        var answers = [donorURL, directory.appendingPathComponent("half.bin")]
        var asked = 0
        controller.segmentSavePanel = { _ in
            asked += 1
            return answers.isEmpty ? nil : answers.removeFirst()
        }

        let form = try XCTUnwrap(presentedForm(controller))
        XCTAssertEqual(form.savePiece?(pane.segmentStore.segments[1]), true)

        XCTAssertEqual(asked, 2, "the first name was refused, so the panel came back")
        XCTAssertEqual(writtenTo, directory, "and the second, free name is what was written")
        XCTAssertEqual(controller.lastAlertTitle,
                       "“\(donorURL.lastPathComponent)” is a segment's source")
    }

    /// Cancelling the second panel leaves the write unstarted: a refusal is a
    /// question, and no answer is an answer (§21.7).
    func testCancellingAfterTheRefusalWritesNothing() throws {
        let (controller, pane, donorURL) = try makeJoined()
        var wrote = false
        wire(controller) { _, _ in wrote = true }
        var answers: [URL?] = [donorURL, nil]
        controller.segmentSavePanel = { _ in answers.isEmpty ? nil : answers.removeFirst() }

        let form = try XCTUnwrap(presentedForm(controller))
        XCTAssertEqual(form.savePiece?(pane.segmentStore.segments[1]), false)

        XCTAssertFalse(wrote)
    }

    /// Save All as Separate Files… into a folder where one of the part names is
    /// a segment's source is refused, and the folder panel opens again (§21.7).
    func testSaveAllAsksAgainForAFolder() throws {
        let (controller, pane, _) = try makeJoined()
        let clash = try makeOutputDirectory()
        let free = try makeOutputDirectory()
        // A file in `clash` with the name Save All would give S0, joined in, so
        // that folder holds a source the write would replace.
        let trap = clash.appendingPathComponent("\(pane.status.fileName)_S0.bin")
        try Data([UInt8](repeating: 0xCC, count: 4)).write(to: trap)
        try pane.join(contentsOf: trap, at: .end)

        var writtenTo: URL?
        wire(controller) { _, dir in writtenTo = dir }
        var answers = [clash, free]
        var asked = 0
        controller.segmentDirectoryPanel = { _ in
            asked += 1
            return answers.isEmpty ? nil : answers.removeFirst()
        }

        let form = try XCTUnwrap(presentedForm(controller))
        XCTAssertEqual(form.saveAll?(), true)

        XCTAssertEqual(asked, 2, "the first folder held a source, so the panel came back")
        XCTAssertEqual(writtenTo, free)
    }

    /// The form the controller would present, captured rather than shown.
    private func presentedForm(_ controller: MainViewController) -> SegmentsFormController? {
        var captured: SegmentsFormController?
        controller.segmentsFormPresenter = { form in
            form.loadViewIfNeeded()
            form.dismissForm = {}
            captured = form
        }
        controller.showSegments()
        controller.segmentsFormPresenter = nil
        return captured
    }
}
