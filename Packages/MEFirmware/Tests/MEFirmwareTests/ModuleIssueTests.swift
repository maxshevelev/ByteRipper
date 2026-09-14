import XCTest
import Foundation
import CryptoKit
@testable import MEFirmware

/// A module check's issue names the module it is about, so a panel can put it
/// on that module's row; an issue about the image names none.
final class ModuleIssueTests: XCTestCase {
    /// An LZMA module whose `.met` says it runs past the region: the check
    /// cannot verify it, and says which module.
    func testAnLZMACheckNamesItsModule() {
        let attributes = ModuleAttributesExtension(
            compression: 2, encryption: 0, uncompressedSize: 0x2000,
            compressedSize: 0x1000, deviceID: 0, vendorID: 0x8086, moduleHash: "")
        let partition = CodePartition(
            name: "FTPR", offset: 0, headerVersion: 2, headerLength: 0x14, entryCount: 2,
            checksumValid: true,
            modules: [
                CPDModule(id: 0, name: "kernel", offset: 0x100, isHuffman: false, size: 0x2000),
                CPDModule(id: 1, name: "kernel.met", offset: 0x80, isHuffman: false, size: 0x60,
                          extensions: [CPDExtension(id: 0, tag: 0x0A, size: 0x60, offset: 0x80,
                                                    moduleAttributes: attributes)])
            ])

        let issues = MEFirmwareAnalyzer.lzmaValidationIssues(
            for: partition, in: Data(count: 0x800), baseOffset: 0)

        XCTAssertEqual(issues.map(\.id), [19])
        XCTAssertEqual(issues.first?.module, "kernel")
    }

    /// The hashes an RBEP partition's `rbe` metadata table lists: a `$CPD`
    /// named RBEP with one uncompressed `rbe` module holding three R4 rows
    /// (0x40 each, VEN_ID 0x8086 at +6, a SHA-384 at +0x10). A row's hash reads
    /// as the digest of what it was taken over, and nothing else is listed.
    func testTheRBEPTablesHashesAreRead() {
        func u32(_ value: Int) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) } }
        let digests = (0..<3).map { index -> Data in
            Data(SHA384.hash(data: Data("module \(index)".utf8)))
        }
        var body: [UInt8] = []
        for (index, digest) in digests.enumerated() {
            body += u32(0) + [UInt8(index), 0] + [0x86, 0x80] + u32(0x1000) + u32(0x800)
            body += digest.reversed()   // stored little-endian, read as one integer
        }

        var region: [UInt8] = Array("$CPD".utf8) + u32(1) + [2, 1, 0x14, 0] + Array("RBEP".utf8) + u32(0)
        region += Array("rbe".utf8) + [UInt8](repeating: 0, count: 9) + u32(0x40) + u32(body.count) + u32(0)
        region += [UInt8](repeating: 0, count: 0x40 - region.count)
        region += body
        region += [UInt8](repeating: 0, count: 0x40)

        let hashes = MEFirmwareAnalyzer.rbeMetadataHashes(
            atCPDs: [0], in: Data(region), baseOffset: 0, family: .csme15,
            variant: "CSME", major: 15, minor: 0, dictionaries: nil)

        XCTAssertEqual(hashes, digests.map { Digest.sha384Hex(Data("module \(digests.firstIndex(of: $0)!)".utf8)) })
    }

    /// A payload from before the field decodes with no module.
    func testAnIssueFromBeforeTheFieldHasNoModule() throws {
        let json = Data(#"{"id": 3, "severity": "note", "message": "Not in the database."}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(Issue.self, from: json).module)
    }
}
