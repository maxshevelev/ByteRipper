import XCTest
import MEFirmware
import MEPresentation
import ToolModuleKit
@testable import MEReads

/// `MEReads` — the bytes both panels hand the engine.
///
/// The reading is thin, and it is what decides which buffer the engine is given
/// and where the addresses in its analysis point, so the cases worth pinning
/// are the ones that choose a buffer: a region the tree resolved, a region that
/// is absent, and a region that is empty.
final class MEReadsTests: XCTestCase {
    /// A reader over a fixed buffer that throws rather than truncates, the way
    /// the real one does.
    private struct Bytes: ToolContentReader {
        let bytes: [UInt8]
        var size: UInt64 { UInt64(bytes.count) }

        func read(at offset: UInt64, length: Int) throws -> [UInt8] {
            guard length >= 0, offset <= UInt64(bytes.count),
                  offset + UInt64(length) <= UInt64(bytes.count) else {
                throw NSError(domain: "MEReadsTests", code: 1)
            }
            return Array(bytes[Int(offset)..<(Int(offset) + length)])
        }
    }

    private let file = Bytes(bytes: (0..<64).map(UInt8.init))

    func testTheRegionIsWhatIsReadWhenTheTreeCouldResolveIt() throws {
        XCTAssertEqual(try MEReads.regionBytes(file, 16..<24),
                       Data((16..<24).map(UInt8.init)), "the region's own bytes")
        XCTAssertEqual(MEReads.regionBase(16..<24), 16,
                       "and its own base, so the analysis stays absolute in the file")
    }

    func testTheWholeFileIsReadWhenTheRegionIsAbsent() throws {
        XCTAssertEqual(try MEReads.regionBytes(file, nil).count, 64, "the whole file")
        XCTAssertEqual(MEReads.regionBase(nil), 0, "from the file's own start")
    }

    func testAnEmptyRegionFallsBackLikeAnAbsentOne() throws {
        XCTAssertEqual(try MEReads.regionBytes(file, 16..<16).count, 64,
                       "an empty region names no bytes")
        XCTAssertEqual(MEReads.regionBase(16..<16), 0)
    }

    func testReadingPastTheEndThrows() {
        XCTAssertThrowsError(try MEReads.readRange(file, 0..<128),
                             "a range past the end is a failure, not a short read")
    }

    /// The reader is asked in 1 MB chunks, so a region that is not a whole
    /// number of them exercises the loop's tail — the last chunk being the
    /// remainder rather than a full one.
    func testAChunkedReadIsTheWholeRange() throws {
        let big = Bytes(bytes: (0..<(1 << 20) + 16).map { UInt8(truncatingIfNeeded: $0) })
        let data = try MEReads.readRange(big, 0..<UInt64(big.bytes.count))
        XCTAssertEqual(data.count, big.bytes.count)
        XCTAssertEqual(data.last, big.bytes.last, "the tail came with it")
    }

    // MARK: - What an analysis wants of the databases

    private func analysis(_ overrides: [String: Any] = [:]) throws -> FirmwareAnalysis {
        var base: [String: Any] = [
            "family": "csme", "variant": "CSME",
            "version": ["major": 15, "minor": 40, "hotfix": 37, "build": 3121],
            "release": "production", "type": "region", "sku": "", "platform": "",
            "sizeBytes": 0x200000, "regions": [], "issues": [],
        ]
        for (key, value) in overrides { base[key] = value }
        return try JSONDecoder().decode(FirmwareAnalysis.self,
                                        from: JSONSerialization.data(withJSONObject: base))
    }

    private func partition(_ modules: [CPDModule]) -> CodePartition {
        CodePartition(name: "FTPR", offset: 0x1000, headerVersion: 2, headerLength: 0x14,
                      entryCount: modules.count, checksumValid: true, modules: modules)
    }

    /// `Huffman.dat` is wanted for a Huffman-packed `pm` or `rbe` module
    /// whatever the image, and for any other Huffman module only on an
    /// identified one; an image of LZMA modules never wants it.
    func testTheDictionariesAreWantedForWhatTheyDecompress() throws {
        var a = try analysis()
        a.codePartition = partition([CPDModule(id: 0, name: "kernel", offset: 0x100, isHuffman: false, size: 0x100)])
        XCTAssertFalse(MEReads.huffmanDictionariesWanted(a))

        a.codePartition = partition([CPDModule(id: 0, name: "kernel", offset: 0x100, isHuffman: true, size: 0x100)])
        XCTAssertTrue(MEReads.huffmanDictionariesWanted(a))
        a.variant = ""
        XCTAssertFalse(MEReads.huffmanDictionariesWanted(a), "an image nobody named has no dictionary to pick")

        a.codePartition = partition([CPDModule(id: 0, name: "pm", offset: 0x100, isHuffman: true, size: 0x100)])
        XCTAssertTrue(MEReads.huffmanDictionariesWanted(a), "the metadata table is behind it")
        a.codePartition = nil
        XCTAssertFalse(MEReads.huffmanDictionariesWanted(a))
    }

    /// `FileTable.dat` is wanted for what cannot be read without it: here, an
    /// EFS volume, whose pages carry no directory.
    func testTheFileTableIsWantedForAnEFSVolume() throws {
        XCTAssertFalse(MEReads.fileTableWanted(try analysis()))
        let efs: [String: Any] = [
            "offset": 0x463000, "pageSize": 0x1000, "systemPageCount": 1,
            "dataPageCount": 14, "scratchPageCount": 1, "scratchPagesEmpty": true,
            "dataPageCountMatchesSystem": true, "dictionary": 0x0B,
            "revision": 1, "unknown1": 2, "dictionaryRevision": 1,
            "dataPagesCommitted": 10, "dataPagesReserved": 4,
            "systemHeaderCRCValid": true, "indexesCRCValid": true,
            "firstIndexPaddingEmpty": true, "dataPageOrder": [],
            "dataPageHeaderCRCsValid": true, "dataPageFooterCRCsValid": true,
        ]
        XCTAssertTrue(MEReads.fileTableWanted(try analysis(["efsVolume": efs])))
    }

    /// A first reading that did without a database it wanted says so; one
    /// that did without one the analysis does not want leaves nothing pending.
    func testAFirstReadingIsPendingOnlyOnWhatItWanted() throws {
        var a = try analysis()
        a.codePartition = partition([CPDModule(id: 0, name: "pm", offset: 0x100, isHuffman: true, size: 0x100)])
        let reading = MEAFirstReading(analysis: a, missedFileTable: true, missedHuffman: true)
        XCTAssertFalse(reading.isComplete)
        XCTAssertEqual(reading.pending, MEAPending(fileTable: false, huffman: true))
        XCTAssertTrue(MEAFirstReading(analysis: a, missedFileTable: false, missedHuffman: false).isComplete)
    }
}
