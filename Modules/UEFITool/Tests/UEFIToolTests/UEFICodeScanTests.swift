import Foundation
import XCTest
import CodeAnalysis
import FirmwareCompressionTestSupport
import UEFIImage
@testable import UEFITool

/// The background scan: image nodes whose body has a usable analysis in the
/// store. The bytes come from the caller, so the same scan serves a node in
/// the file and one in a decompressed buffer.
final class UEFICodeScanTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("UEFICodeScanTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private let teModule = Data([0x56, 0x5A]) + Data(repeating: 0, count: 14)
    private let peModule = Data([0x4D, 0x5A]) + Data(repeating: 0, count: 14)

    private var recipe: AnalysisRecipe {
        AnalysisRecipe(id: "code-v2-ghidra-12.1.2", exporter: 2,
                       ghidra: "12.1.2", script: "ExportCode.java")
    }

    @discardableResult
    private func analyze(_ module: Data, name: String = "Module",
                         source: SourceIdentity = SourceIdentity()) throws -> AnalysisManifest {
        let store = try ContentStore(root: directory)
        return try store.putAnalysis(
            module: ModuleIdentity(
                sha256: SHA256Digest(data: module), size: module.count, name: name,
                kind: "TE", language: "x86:LE:32:default", imageBase: "0x0"),
            recipe: recipe,
            artifact: Data("{\"script_version\":2}".utf8),
            source: source)
    }

    private func index() -> CodeAnalysisIndex {
        CodeAnalysisIndex.load(from: directory)
    }

    private func section(
        _ subtype: UInt8,
        bodySize: Int,
        space: ByteSpace = .file
    ) -> UEFINode {
        UEFINode(kind: .section, subtype: subtype, name: "Image",
                 header: 0..<4, body: 4..<(4 + UInt64(bodySize)), space: space)
    }

    private func rawFile(bodySize: Int) -> UEFINode {
        UEFINode(kind: .file, subtype: 0x01, name: "Module",
                 header: 0..<0x18, body: 0x18..<(0x18 + UInt64(bodySize)))
    }

    private func image(_ node: UEFINode) -> UEFIImage {
        UEFIImage(size: 0x200, roots: [node])
    }

    // MARK: - Finding

    func testAnAnalyzedTEImageIsFound() throws {
        let module = teModule
        try analyze(module)
        let image = image(section(0x12, bodySize: module.count))
        let found = UEFICodeScan.scan(in: image, index: index(),
                                      bytesOf: { _ in module })
        XCTAssertEqual(Set(found.keys), Set([image.roots[0].id]))
    }

    func testSourceNodeIDsAreParsedAndDeduplicated() throws {
        try analyze(teModule, name: "A", source: SourceIdentity(
            document: "d1", node: "0.6.4.0.0.205.2"))
        try analyze(peModule, name: "B", source: SourceIdentity(
            document: "d1", node: "0.6.4.0.0.205.2"))
        try analyze(Data([0x56, 0x5A]) + Data(repeating: 2, count: 14), name: "root",
                    source: SourceIdentity(node: "root"))
        try analyze(Data([0x4D, 0x5A]) + Data(repeating: 3, count: 14), name: "bad",
                    source: SourceIdentity(node: "not.a.path"))

        XCTAssertEqual(UEFICodeScan.sourceNodeIDs(in: index()),
                       [NodeID([0, 6, 4, 0, 0, 205, 2])])
        XCTAssertEqual(UEFICodeScan.sourceNodeIDs(in: index(), document: "d1"),
                       [NodeID([0, 6, 4, 0, 0, 205, 2])])
        XCTAssertTrue(UEFICodeScan.sourceNodeIDs(in: index(), document: "another.bin").isEmpty)
    }

    func testAnAnalyzedPE32ImageIsFound() throws {
        let module = peModule
        try analyze(module)
        let image = image(section(0x10, bodySize: module.count))
        let found = UEFICodeScan.scan(in: image, index: index(),
                                      bytesOf: { _ in module })
        XCTAssertEqual(Set(found.keys), Set([image.roots[0].id]))
    }

    func testAnAnalyzedRawFileIsFound() throws {
        let module = peModule
        try analyze(module)
        let image = image(rawFile(bodySize: module.count))
        let found = UEFICodeScan.scan(in: image, index: index(),
                                      bytesOf: { _ in module })
        XCTAssertEqual(Set(found.keys), Set([image.roots[0].id]))
    }

    func testAnImageInADecompressedSpaceIsFound() throws {
        let module = teModule
        try analyze(module)
        let node = section(0x12, bodySize: module.count,
                           space: .decompressed(chain: [0x60]))
        let image = image(node)
        let found = UEFICodeScan.scan(in: image, index: index(),
                                      bytesOf: { _ in module })
        XCTAssertEqual(Set(found.keys), Set([image.roots[0].id]))
    }

    /// The bytes really come through the decompressor: the child is a TE
    /// section inside an LZMA compression section, and the reader is the
    /// space reader the session would hand the scan.
    func testAnImageInsideACompressedSectionIsFound() throws {
        let module = teModule
        try analyze(module)
        let stream = LZMATestEncoder.lzma([UInt8](module))
        let size = UInt32(4 + 5 + stream.count)
        var bytes = (0..<3).map { UInt8((size >> (8 * UInt32($0))) & 0xFF) } + [0x01]
        bytes += (0..<4).map { UInt8((UInt32(module.count) >> (8 * UInt32($0))) & 0xFF) }
        bytes.append(0x02)
        bytes += stream

        let child = UEFINode(
            kind: .section, subtype: 0x12, name: "TE image",
            header: 0..<0, body: 0..<UInt64(module.count),
            space: .decompressed(chain: [0]))
        let compressed = UEFINode(
            kind: .section, subtype: 0x01, name: "LZMA compressed section",
            header: 0..<9, body: 9..<UInt64(bytes.count),
            compression: SectionCompression(algorithm: "LZMA", decodes: true),
            children: [child])
        let image = UEFIImage(size: UInt64(bytes.count), roots: [compressed])
        let readers = SpaceReaders(file: ImageReader(bytes))

        let found = UEFICodeScan.scan(in: image, index: index(), bytesOf: { node in
            guard let reader = readers.reader(for: node.space),
                  let data = reader.bytes(node.body)
            else { return nil }
            return Data(data)
        })
        XCTAssertEqual(Set(found.keys), Set([image.roots[0].children[0].id]))
    }

    // MARK: - Not finding

    func testAChangedBodyIsNotFound() throws {
        try analyze(teModule)
        var changedBytes = teModule
        changedBytes[changedBytes.count - 1] ^= 0xFF
        let changed = changedBytes
        let image = image(section(0x12, bodySize: changed.count))
        XCTAssertTrue(UEFICodeScan.scan(in: image, index: index(),
                                        bytesOf: { _ in changed }).isEmpty)
    }

    func testAnEmptyStoreFindsNothing() {
        let image = image(section(0x12, bodySize: teModule.count))
        let found = UEFICodeScan.scan(in: image, index: .empty, bytesOf: { _ in
            XCTFail("an empty store must not read a body")
            return nil
        })
        XCTAssertTrue(found.isEmpty)
    }

    func testAMissingObjectFindsNothing() throws {
        let module = teModule
        let manifest = try analyze(module)
        let store = try ContentStore(root: directory)
        try FileManager.default.removeItem(at: store.objectURL(manifest.artifact.sha256))

        let image = image(section(0x12, bodySize: module.count))
        XCTAssertTrue(UEFICodeScan.scan(in: image, index: index(),
                                        bytesOf: { _ in module }).isEmpty)
    }

    func testABodyOfAnotherLengthIsNotHashed() throws {
        let module = teModule
        try analyze(module)
        let image = image(section(0x12, bodySize: module.count + 1))
        XCTAssertTrue(UEFICodeScan.scan(in: image, index: index(),
                                        bytesOf: { _ in module }).isEmpty)
    }

    func testAForeignBodyIsNotAnImage() throws {
        try analyze(teModule)
        let image = image(section(0x12, bodySize: teModule.count))
        let foreign = Data(repeating: 0, count: teModule.count)
        XCTAssertTrue(UEFICodeScan.scan(in: image, index: index(),
                                        bytesOf: { _ in foreign }).isEmpty)
    }

    func testOnlyLimitsTheNodesScanned() throws {
        let module = teModule
        try analyze(module)
        let node = section(0x12, bodySize: module.count)
        let image = image(node)
        let found = UEFICodeScan.scan(in: image, index: index(),
                                      only: Set([NodeID([99])]),
                                      bytesOf: { _ in module })
        XCTAssertTrue(found.isEmpty)
    }
}
