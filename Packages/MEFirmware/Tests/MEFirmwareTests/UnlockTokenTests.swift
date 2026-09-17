import XCTest
import Foundation
@testable import MEFirmware

/// `UTFL_Header` — the Unlock Token Flags a `UTOK`/`STKN` partition may end
/// with (upstream MEA.py 2038, read at 6637/6650).
///
/// The real-byte check is a run, not a test: on `CSME 15.bin` (UTOK @0x460000)
/// and `CSME 12.BIN` (UTOK @0x6B000) the structure decodes to Delayed
/// Authentication Mode 0 and 27 erased reserved bytes, identical to what
/// upstream's own `-unp86` prints for both ("No", 0xFF…FF). No dump is
/// committed, so the cases here are synthetic.
final class UnlockTokenTests: XCTestCase {

    /// A partition of `size` bytes whose last 0x20 are the flags structure.
    /// `tag` is what those four bytes hold, so a wrong one can be asked about.
    private static func partition(size: Int = 0x2000, tag: String = "UTFL",
                                  delayedAuthMode: UInt8 = 0,
                                  reserved: UInt8 = 0xFF) -> Data {
        var out = Data(repeating: 0xAB, count: size)
        let start = size - 0x20
        out.replaceSubrange(start..<(start + 4), with: Data(tag.utf8))
        out[start + 0x04] = delayedAuthMode
        out.replaceSubrange((start + 0x05)..<size,
                            with: Data(repeating: reserved, count: 0x1B))
        return out
    }

    /// The four facts the structure holds, and the position it holds them at:
    /// the offset is the structure's own, not the partition's.
    func testTheFlagsAreReadFromThePartitionsLastBytes() throws {
        let region = Self.partition()
        let flags = try XCTUnwrap(UnlockTokenParser.flags(
            in: region, offset: 0, size: region.count,
            absoluteOffset: 0x460000, partition: "UTOK"))
        XCTAssertEqual(flags.partition, "UTOK")
        XCTAssertEqual(flags.offset, 0x461FE0, "the partition's end minus 0x20")
        XCTAssertEqual(flags.delayedAuthMode, 0)
        XCTAssertEqual(flags.reservedHex, String(repeating: "FF", count: 0x1B))
    }

    /// The mode byte is kept raw — 1 is a real value on a token that has it,
    /// and a byte nobody has seen is reported as it stands rather than rounded
    /// to Yes.
    func testTheModeByteIsKeptAsItStands() throws {
        for value: UInt8 in [0, 1, 7, 0xFF] {
            let region = Self.partition(delayedAuthMode: value)
            let flags = try XCTUnwrap(UnlockTokenParser.flags(
                in: region, offset: 0, size: region.count,
                absoluteOffset: 0, partition: "STKN"))
            XCTAssertEqual(flags.delayedAuthMode, Int(value))
        }
    }

    /// The reserved bytes are hex in storage order, so a written value reads
    /// the way the bytes sit — upstream prints the same bytes little-endian.
    func testTheReservedBytesAreHexInStorageOrder() throws {
        var region = Self.partition(reserved: 0x00)
        let start = region.count - 0x20
        region[start + 0x05] = 0x12
        region[start + 0x06] = 0x34
        let flags = try XCTUnwrap(UnlockTokenParser.flags(
            in: region, offset: 0, size: region.count,
            absoluteOffset: 0, partition: "UTOK"))
        XCTAssertTrue(flags.reservedHex.hasPrefix("1234"))
        XCTAssertEqual(flags.reservedHex.count, 0x1B * 2)
    }

    /// The structure is optional in the format: a token that does not end with
    /// the tag has none, which is not a defect and not a row.
    func testAPartitionWithoutTheTagHasNoFlags() {
        let region = Self.partition(tag: "XXXX")
        XCTAssertNil(UnlockTokenParser.flags(in: region, offset: 0,
                                             size: region.count,
                                             absoluteOffset: 0, partition: "UTOK"))
    }

    /// Located by the partition's end, not by searching: a `UTFL` sitting
    /// anywhere else in the token is a coincidence, and reading it as the
    /// structure would report flags from the middle of a signed blob.
    func testATagElsewhereInThePartitionIsNotTheStructure() {
        var region = Data(repeating: 0xAB, count: 0x2000)
        region.replaceSubrange(0x100..<0x104, with: Data("UTFL".utf8))
        XCTAssertNil(UnlockTokenParser.flags(in: region, offset: 0,
                                             size: region.count,
                                             absoluteOffset: 0, partition: "UTOK"))
    }

    /// A partition shorter than the structure, or one whose declared size runs
    /// past the region, is read as having none rather than off the end.
    func testAPartitionTooSmallOrOutOfBoundsHasNoFlags() {
        let short = Self.partition(size: 0x40).prefix(0x10)
        XCTAssertNil(UnlockTokenParser.flags(in: Data(short), offset: 0, size: 0x10,
                                             absoluteOffset: 0, partition: "UTOK"))
        let region = Self.partition()
        XCTAssertNil(UnlockTokenParser.flags(in: region, offset: 0,
                                             size: region.count + 0x10,
                                             absoluteOffset: 0, partition: "UTOK"))
        XCTAssertNil(UnlockTokenParser.flags(in: region, offset: -1,
                                             size: region.count,
                                             absoluteOffset: 0, partition: "UTOK"))
    }

    /// The offset is read past the partition's *own* start, so a token found
    /// somewhere other than at the region's head still reports the structure
    /// where it really is.
    func testTheFlagsAreFoundAtAnOffsetIntoTheRegion() throws {
        var region = Data(repeating: 0x00, count: 0x1000)
        region.append(Self.partition(size: 0x2000))
        let flags = try XCTUnwrap(UnlockTokenParser.flags(
            in: region, offset: 0x1000, size: 0x2000,
            absoluteOffset: 0x71000, partition: "UTOK"))
        XCTAssertEqual(flags.offset, 0x72FE0)
    }

    /// The two names upstream treats as unlock tokens, and nothing else.
    func testTheTokenPartitionNames() {
        XCTAssertEqual(UnlockTokenParser.partitionNames, ["UTOK", "STKN"])
    }
}
