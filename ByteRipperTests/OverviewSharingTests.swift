import ByteRipperCore
import XCTest
@testable import ByteRipper

/// § 19.9: the overview of a comparison bins a row both files hold the same
/// bytes for once, from the first file, and copies its density to the second.
/// The copy must be invisible — the picture equals the one each file would get
/// on its own — and it must actually save the reads.
final class OverviewSharingTests: XCTestCase {
    /// A storage that counts the bytes read from it, to tell a copied row from
    /// a read one.
    private final class CountingStorage: ByteStorage, @unchecked Sendable {
        private let bytes: [UInt8]
        private let lock = NSLock()
        private var readRanges: [Range<UInt64>] = []

        init(_ bytes: [UInt8]) { self.bytes = bytes }

        var size: UInt64 { UInt64(bytes.count) }

        func read(at offset: UInt64, length: Int) throws -> [UInt8] {
            let start = Int(min(offset, size))
            let end = min(start + length, bytes.count)
            lock.lock()
            readRanges.append(UInt64(start)..<UInt64(end))
            lock.unlock()
            return Array(bytes[start..<end])
        }

        var reads: [Range<UInt64>] {
            lock.lock()
            defer { lock.unlock() }
            return readRanges
        }
    }

    /// The comparison index of two byte arrays, built the way §8.1 defines it:
    /// runs of same and different over the longer file, the shorter file's
    /// missing tail counting as different.
    private func index(_ left: [UInt8], _ right: [UInt8]) -> DiffBlockIndex {
        let extent = max(left.count, right.count)
        var blocks: [DiffBlock] = []
        var runStart = 0
        var runKind: DiffBlock.Kind?
        for offset in 0..<extent {
            let same = offset < left.count && offset < right.count && left[offset] == right[offset]
            let kind: DiffBlock.Kind = same ? .same : .different
            if kind != runKind {
                if let runKind {
                    blocks.append(DiffBlock(kind: runKind, range: UInt64(runStart)..<UInt64(offset)))
                }
                runKind = kind
                runStart = offset
            }
        }
        if let runKind {
            blocks.append(DiffBlock(kind: runKind, range: UInt64(runStart)..<UInt64(extent)))
        }
        return DiffBlockIndex(leftSize: UInt64(left.count), rightSize: UInt64(right.count),
                              blocks: blocks)
    }

    private func source(_ storage: CountingStorage, differences: DiffBlockIndex?)
        -> SurfaceMinimapController.OverviewSource {
        SurfaceMinimapController.OverviewSource(
            storage: storage, baseline: .none, size: storage.size, edited: [],
            differences: differences)
    }

    /// A dump-like file: erased padding, then content.
    private func dump(count: Int, seed: UInt8 = 0) -> [UInt8] {
        (0..<count).map { offset in
            offset < count / 3 ? 0xFF : UInt8(truncatingIfNeeded: offset &* 31 &+ Int(seed))
        }
    }

    private func pictures(_ left: [UInt8], _ right: [UInt8], rowCount: Int, share: Bool)
        async throws -> (summaries: [MinimapView.OverviewSummary], rightReads: [Range<UInt64>]) {
        let comparison = index(left, right)
        let leftStorage = CountingStorage(left)
        let rightStorage = CountingStorage(right)
        let summaries = try await XCTUnwrapAsync(
            await SurfaceMinimapController.overviewSummaries(
                sources: [source(leftStorage, differences: comparison),
                          source(rightStorage, differences: comparison)],
                extent: UInt64(max(left.count, right.count)), rowCount: rowCount,
                sameBytes: share ? comparison : nil))
        return (summaries, rightStorage.reads)
    }

    private func XCTUnwrapAsync<T>(_ value: T?, file: StaticString = #filePath,
                                   line: UInt = #line) async throws -> T {
        try XCTUnwrap(value, file: file, line: line)
    }

    /// Every shape the binning has — rows of many bytes, rows thinner than a
    /// byte, files of different lengths — gives the same picture shared or not.
    func testASharedPictureEqualsTheUnsharedOne() async throws {
        var right = dump(count: 40_000)
        let left = right
        for offset in [5, 13_000, 13_001, 27_500, 39_999] { right[offset] ^= 0x5A }
        let shorter = Array(right.prefix(31_337))
        for (b, rowCount) in [(right, 1000), (right, 50_000), (shorter, 700), (shorter, 64_000)] {
            let shared = try await pictures(left, b, rowCount: rowCount, share: true)
            let plain = try await pictures(left, b, rowCount: rowCount, share: false)
            XCTAssertEqual(shared.summaries, plain.summaries,
                           "a copied row is the row the file would have drawn (\(b.count) bytes, \(rowCount) rows)")
        }
    }

    /// The picture assembled from two files' halves is the picture one plain
    /// pass over each file gives — including a difference spanning half the
    /// file, whose marks a pass over a later run of rows once dropped.
    func testASplitPictureEqualsOnePassPerFile() async throws {
        let left = dump(count: 300_000)
        var right = Array(left.prefix(200_000))
        for offset in 120_000..<190_000 { right[offset] ^= 0x01 }
        let comparison = index(left, right)
        for rowCount in [997, 1600, 4096] {
            let sources = [source(CountingStorage(left), differences: comparison),
                           source(CountingStorage(right), differences: comparison)]
            let split = try await XCTUnwrapAsync(
                await SurfaceMinimapController.overviewSummaries(
                    sources: sources, extent: 300_000, rowCount: rowCount,
                    sameBytes: comparison))
            for (map, source) in sources.enumerated() {
                let whole = try XCTUnwrap(SurfaceMinimapController.overviewRows(
                    source: source, extent: 300_000, rowCount: rowCount,
                    rows: 0...(rowCount - 1)))
                XCTAssertEqual(split[map].density, whole.density, "map \(map), \(rowCount) rows")
                XCTAssertEqual(split[map].modified, whole.modified, "map \(map), \(rowCount) rows")
                XCTAssertEqual(split[map].different, whole.different, "map \(map), \(rowCount) rows")
            }
        }
    }

    /// A run of rows starting mid-file — a patch after an edit — still gets
    /// the marks of a difference that began before it. The first byte of such a
    /// run can divide into the row before, and `mark` used to drop the block.
    func testARunOfRowsMidFileKeepsADifferenceThatBeganEarlier() {
        let binning = OverviewBinning(extent: 300_000, rowCount: 997)
        var bits = [UInt16](repeating: 0, count: 100)
        binning.mark(0..<300_000, rows: 500...599, into: &bits)
        XCTAssertTrue(bits.allSatisfy { $0 == .max }, "a block spanning the run marks all of it")
    }

    /// The point of it: a row both files hold the same is read from one of
    /// them, and the two files share that work half and half.
    func testASharedRowIsReadOnce() async throws {
        let left = dump(count: 160_000)
        var right = left
        right[100_000] ^= 0x01
        let comparison = index(left, right)
        let leftStorage = CountingStorage(left)
        let rightStorage = CountingStorage(right)
        let shared = try await XCTUnwrapAsync(
            await SurfaceMinimapController.overviewSummaries(
                sources: [source(leftStorage, differences: comparison),
                          source(rightStorage, differences: comparison)],
                extent: 160_000, rowCount: 1000, sameBytes: comparison))   // 160 bytes per row
        let plain = try await pictures(left, right, rowCount: 1000, share: false)
        XCTAssertEqual(shared, plain.summaries)

        func total(_ reads: [Range<UInt64>]) -> UInt64 { reads.reduce(0) { $0 + UInt64($1.count) } }
        let leftRead = total(leftStorage.reads), rightRead = total(rightStorage.reads)
        XCTAssertEqual(leftRead + rightRead, 160_000 + 160,
                       "every row is read once, and the differing one from both files")
        XCTAssertEqual(Double(leftRead), 80_000, accuracy: 400, "the first file reads half")
        XCTAssertTrue(rightStorage.reads.contains { $0.contains(100_000) }
                      && leftStorage.reads.contains { $0.contains(100_000) },
                      "the differing row is read from both files")
        XCTAssertEqual(total(plain.rightReads), UInt64(right.count),
                       "without an index the whole file is read")
    }

    /// An index that describes other files — a size that does not match — is
    /// not trusted with the picture.
    func testAnIndexOfOtherSizesSharesNothing() async throws {
        let left = dump(count: 20_000)
        var right = left
        right[7] ^= 0x01
        let stale = index(Array(left.prefix(19_000)), Array(right.prefix(19_000)))
        let leftStorage = CountingStorage(left)
        let rightStorage = CountingStorage(right)
        let summaries = await SurfaceMinimapController.overviewSummaries(
            sources: [source(leftStorage, differences: stale),
                      source(rightStorage, differences: stale)],
            extent: 20_000, rowCount: 500, sameBytes: stale)
        XCTAssertNotNil(summaries)
        for storage in [leftStorage, rightStorage] {
            XCTAssertEqual(storage.reads.reduce(UInt64(0)) { $0 + UInt64($1.count) }, 20_000,
                           "each file is read whole")
        }
    }

    /// The row rule itself: a row is the same only when every byte it is
    /// computed from is the same in both files and inside both of them.
    func testRowsWithSameBytes() {
        let left = [UInt8](repeating: 0x41, count: 1000)
        var right = Array(left.prefix(900))
        right[250] = 0x42
        let binning = OverviewBinning(extent: 1000, rowCount: 10)   // 100 bytes per row
        let same = binning.rowsWithSameBytes(in: index(left, right), rows: 0...9)
        XCTAssertEqual(same, [true, true, false, true, true, true, true, true, true, false],
                       "row 2 holds the difference, row 9 lies past the shorter file's end")

        // Rows thinner than a byte: several rows stand for byte 3, all of them differ.
        var small = [UInt8](repeating: 0x41, count: 10)
        let other = { () -> [UInt8] in var o = small; o[3] = 0; return o }()
        small[0] = 0x41
        let thin = OverviewBinning(extent: 10, rowCount: 40)
        let thinSame = thin.rowsWithSameBytes(in: index(small, other), rows: 0...39)
        for row in 0..<40 {
            XCTAssertEqual(thinSame[row], thin.start(ofRow: row) != 3,
                           "row \(row) reads byte \(thin.start(ofRow: row))")
        }
    }
}
