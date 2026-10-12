import BytePattern
import FirmwareCompressionTestSupport
import XCTest
import UEFIImage
@testable import UEFITool

/// The search through what the tree holds: the volumes' bytes, and what their
/// compressed sections decompress to, each match placed at its node and in its
/// volume.
@MainActor
final class UEFIContentSearchTests: XCTestCase {
    /// Text that is in the image only inside the compressed section.
    private let hidden = "HiddenSetupText"

    /// A volume of two files: a raw one holding `DE AD BE EF`, and one whose
    /// LZMA compression section holds a name section and a raw section with
    /// `hidden` in it — twice, in ASCII and in UTF-16.
    private func image() -> (bytes: [UInt8], rawFileAt: UInt64) {
        let text = Array(hidden.utf8)
        let wide = Array(hidden.utf16).flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }
        let inner = sections([
            section(type: 0x15, body: Array("Inner".utf16).flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] } + [0, 0]),
            section(type: 0x19, body: [0x11, 0x22] + text + [0x00] + wide)
        ])
        var compression: [UInt8] = []
        compression += le(UInt64(inner.count), 4)
        compression.append(0x02)
        compression += LZMATestEncoder.lzma(inner)
        let compressed = section(type: 0x01, body: compression)
        let raw = file(guid: 0x11, type: 0x01, body: [0x00, 0x01, 0xDE, 0xAD, 0xBE, 0xEF, 0x02, 0x03])
        let driver = file(guid: 0x22, type: 0x07, body: sections([compressed]))
        let built = volume(length: 0x2000, files: [raw, driver])
        XCTAssertNil(find(Array(hidden.utf8), in: built), "the text is not in the file as stored")
        return (built, 0x48)
    }

    private func tree(_ bytes: [UInt8]) async -> LazyUEFITree {
        let tree = LazyUEFITree(bytes)
        await withCheckedContinuation { continuation in tree.whenReady { continuation.resume() } }
        return tree
    }

    func testTextInACompressedSectionIsFoundInWhatItDecompressesTo() async throws {
        let built = image()
        let tree = await tree(built.bytes)
        let result = try await UEFIContentSearch.run(
            [try MaskedPattern.ascii(hidden.lowercased(), ignoringCase: true),
             try MaskedPattern.utf16LE(hidden, ignoringCase: false)],
            from: .root, in: tree)

        XCTAssertEqual(result.total, 2)
        XCTAssertEqual(result.matches.map(\.pattern), [0, 1], "ASCII first: it comes first in the section")
        let match = result.matches[0]
        XCTAssertNil(match.fileRange, "decompressed bytes have no file address")
        let node = try XCTUnwrap(match.node.flatMap(tree.node))
        XCTAssertEqual(node.kind, .section)
        XCTAssertEqual(node.subtype, 0x19, "the raw section that holds it, not the compressed one")
        XCTAssertEqual(match.nodeOffset, UInt64(node.header.count) + 2)
        let section = try XCTUnwrap(match.section.flatMap(tree.node))
        XCTAssertNotNil(section.compression, "said which compressed section it came out of")
        XCTAssertEqual(match.volume.flatMap(tree.node)?.kind, .volume)
        XCTAssertNil(match.volumeOffset, "the volume is in the file, the match is not")
        XCTAssertEqual(result.buffers, 1)
        XCTAssertTrue(result.unreadSections.isEmpty)
    }

    func testAMatchInTheFileHasItsAddressAndItsPlaceInTheVolume() async throws {
        let built = image()
        let tree = await tree(built.bytes)
        let result = try await UEFIContentSearch.run([try MaskedPattern.hex("DE AD ?? EF")], from: .root, in: tree)

        XCTAssertEqual(result.total, 1)
        let match = try XCTUnwrap(result.matches.first)
        let address = built.rawFileAt + 0x18 + 2
        XCTAssertEqual(match.fileRange, address..<(address + 4))
        XCTAssertEqual(match.node.flatMap(tree.node)?.kind, .file)
        XCTAssertEqual(match.nodeOffset, 0x18 + 2)
        XCTAssertEqual(match.volumeOffset, address, "the volume starts the image")
        XCTAssertNil(match.section)
    }

    func testASearchFromANodeLooksOnlyUnderIt() async throws {
        let built = image()
        let tree = await tree(built.bytes)
        _ = await UEFIAgentQueries.expanded(NodeID([0]), in: tree)
        let rawFile = NodeID([0, 0])
        let driver = NodeID([0, 1])
        XCTAssertEqual(tree.node(rawFile)?.subtype, 0x01)

        let text = [try MaskedPattern.ascii(hidden, ignoringCase: false)]
        let inRaw = try await UEFIContentSearch.run(text, from: rawFile, in: tree)
        XCTAssertEqual(inRaw.total, 0)
        XCTAssertEqual(inRaw.buffers, 0)
        let inDriver = try await UEFIContentSearch.run(text, from: driver, in: tree)
        XCTAssertEqual(inDriver.total, 1)
        XCTAssertTrue(inDriver.matches[0].node?.path.starts(with: driver.path) == true)

        let bytes = [try MaskedPattern.hex("DEADBEEF")]
        let notInDriver = try await UEFIContentSearch.run(bytes, from: driver, in: tree)
        XCTAssertEqual(notInDriver.total, 0)
    }

    func testANodeNotInTheTreeIsRefused() async throws {
        let tree = await tree(image().bytes)
        do {
            _ = try await UEFIContentSearch.run([try MaskedPattern.hex("00")], from: NodeID([7, 7]), in: tree)
            XCTFail("a node that is not there")
        } catch let error as UEFIContentSearchError {
            XCTAssertEqual(error, .unknownNode(NodeID([7, 7])))
        }
    }

    // MARK: - Building an image

    private func le(_ value: UInt64, _ count: Int) -> [UInt8] {
        (0..<count).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) }
    }

    private func section(type: UInt8, body: [UInt8]) -> [UInt8] {
        le(UInt64(4 + body.count), 3) + [type] + body
    }

    private func sections(_ list: [[UInt8]]) -> [UInt8] {
        var bytes: [UInt8] = []
        for section in list {
            while bytes.count % 4 != 0 { bytes.append(0xFF) }
            bytes += section
        }
        return bytes
    }

    /// An FFS file with a correct header checksum and the fixed body one.
    private func file(guid: UInt8, type: UInt8, body: [UInt8]) -> [UInt8] {
        var header = [UInt8](repeating: guid, count: 16)
        header += [0, 0xAA, type, 0]
        header += le(UInt64(0x18 + body.count), 3)
        header.append(0xF8)
        let sum = header.enumerated()
            .filter { ![0x10, 0x11, 0x17].contains($0.offset) }
            .reduce(UInt8(0)) { $0 &+ $1.element }
        header[0x10] = 0 &- sum
        return header + body
    }

    private func volume(length: UInt64, files: [[UInt8]]) -> [UInt8] {
        var header = [UInt8](repeating: 0, count: 16)
        header += KnownGUIDs.ffsV2.bytes
        header += le(length, 8)
        header += Array("_FVH".utf8)
        header += le(0x800, 4)          // erase polarity
        header += le(0x48, 2)           // header length
        header += [0, 0]                // checksum, below
        header += [0, 0, 0, 2]          // no extended header, reserved, revision 2
        header += le(1, 4) + le(length, 4) + le(0, 8)
        var sum: UInt16 = 0
        for index in stride(from: 0, to: header.count, by: 2) {
            sum &+= UInt16(header[index]) | UInt16(header[index + 1]) << 8
        }
        let checksum = 0 &- sum
        header[0x32] = UInt8(checksum & 0xFF)
        header[0x33] = UInt8(checksum >> 8)
        var bytes = header
        for file in files {
            while bytes.count % 8 != 0 { bytes.append(0xFF) }
            bytes += file
        }
        bytes += [UInt8](repeating: 0xFF, count: Int(length) - bytes.count)
        return bytes
    }

    private func find(_ needle: [UInt8], in haystack: [UInt8]) -> Int? {
        guard needle.count <= haystack.count else { return nil }
        return (0...(haystack.count - needle.count)).first { Array(haystack[$0..<($0 + needle.count)]) == needle }
    }
}
