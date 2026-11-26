import Foundation
import XCTest
@testable import ECImage

/// Over a real image: `GHIDRA_EC_MODULE` names the BIOS copy of the ITE EC
/// firmware (0x30000 bytes); a run without it skips.
final class ECFirmwareTests: XCTestCase {
    private func image() throws -> Data {
        guard let path = ProcessInfo.processInfo.environment["GHIDRA_EC_MODULE"], !path.isEmpty else {
            throw XCTSkip("GHIDRA_EC_MODULE names no EC image")
        }
        return try Data(contentsOf: URL(fileURLWithPath: path))
    }

    func testSignatureAndVersion() throws {
        let data = try image()
        XCTAssertEqual(ECChipFamily.family(of: data)?.id, "ite-nds32")
        XCTAssertEqual(ECChipFamily.iteNDS32.version(of: data), "ITE8380-EC-V0.00")
        var broken = data
        broken[0x84] = 0x00
        XCTAssertNil(ECChipFamily.family(of: broken))
        XCTAssertNil(ECChipFamily.family(of: Data("MZ".utf8) + Data(count: 0x200)))
        XCTAssertThrowsError(try ECFirmware(slice: broken)) { XCTAssertEqual($0 as? ECFirmware.Failure, .notEC) }
        // The second form the BIOS accepts: "ITE EC-V" at +0x50.
        var text = broken
        text.replaceSubrange(0x50..<0x60, with: Array("ITE EC-V1.23".utf8) + [0, 0, 0, 0])
        XCTAssertEqual(ECChipFamily.iteNDS32.signatureForm(of: text), 2)
        XCTAssertEqual(ECChipFamily.iteNDS32.version(of: text), "ITE EC-V1.23")
        XCTAssertEqual(ECChipFamily.iteNDS32.signatureForm(of: data), 1)
        XCTAssertEqual(ECChipFamily.iteNDS32.hostUpdateSize, 0x2C000)
    }

    func testExtentAndIdentity() throws {
        let data = try image()
        let firmware = try ECFirmware(slice: data)
        XCTAssertEqual(firmware.extent, 0x2497C)
        XCTAssertEqual(firmware.extentSource, .crt0)
        XCTAssertEqual(firmware.startup?.resetEntry, 0x3800)
        XCTAssertEqual(firmware.startup?.dataSource, 0x24974)
        XCTAssertEqual(firmware.startup?.dataTarget, 0x81400)
        XCTAssertEqual(firmware.startup?.dataLength, 8)
        XCTAssertEqual(firmware.startup?.main, 0x2C00)
        XCTAssertEqual(firmware.sha256, "889159a794a3015e5547312b224db1f43c76daeddb90069ee856e32b6eac2b39")
        XCTAssertEqual(firmware.masked, [.init(offset: 0x8D, actual: 0xAF, normalised: 0x00)])
        XCTAssertFalse(firmware.chipRead)
        XCTAssertEqual(firmware.image.count, 0x2497C)
        XCTAssertEqual(firmware.moduleName, "ITE8380-EC-V0.00")
        XCTAssertEqual(firmware.sliceSize, data.count)

        // The byte the EC rewrote: the same module.
        var rewritten = data
        rewritten[0x8D] = 0x00
        let again = try ECFirmware(slice: rewritten)
        XCTAssertEqual(again.sha256, firmware.sha256)
        XCTAssertNotEqual(again.rawSHA256, firmware.rawSHA256)
        XCTAssertEqual(again.masked.first?.actual, 0x00)
    }

    func testChipReadTailIsAccepted() throws {
        var data = try image()
        data[0x8D] = 0x00
        data[0x2A600] = 0x12
        data[0x2A800] = 0x34
        for at in 0x2B800..<0x2B840 { data[at] = UInt8(at & 0xFF) }
        let firmware = try ECFirmware(slice: data)
        XCTAssertTrue(firmware.chipRead)
        XCTAssertEqual(firmware.extent, 0x2497C)
        XCTAssertEqual(firmware.sha256, "889159a794a3015e5547312b224db1f43c76daeddb90069ee856e32b6eac2b39")
    }

    func testBIOSCopyWithBytesPastTheImageIsRefused() throws {
        var data = try image()
        data[0x25000] = 0x00
        XCTAssertThrowsError(try ECFirmware(slice: data)) { error in
            XCTAssertEqual(error as? ECFirmware.Failure, .tailNotErased(firstAt: 0x25000, extent: 0x2497C))
            XCTAssertTrue("\(error)".contains("0x25000"))
        }
    }

    func testHeuristicWhenTheResetCodeCannotBeRead() throws {
        var data = try image()
        // The reset vector jumps to itself: no start-up code to read.
        data.replaceSubrange(0..<4, with: [0x48, 0x00, 0x00, 0x00])
        let firmware = try ECFirmware(slice: data)
        XCTAssertEqual(firmware.extentSource, .heuristic)
        XCTAssertEqual(firmware.extent, 0x2497C)
    }

    func testLayout() throws {
        let layout = try ECFirmware(slice: try image()).layout
        XCTAssertEqual(layout.vectors.first?.name, "ResetEntry")
        XCTAssertEqual(layout.vectors.first?.target, 0x3800)
        XCTAssertEqual(layout.vectors.first { $0.index == 7 }?.name, "Exc_General")
        XCTAssertEqual(layout.vectors.first { $0.index == 9 }?.name, "Isr_Lvl0")
        XCTAssertEqual(layout.vectors.first { $0.index == 9 }?.target, 0x4AA)
        XCTAssertEqual(layout.vectors.first { $0.index == 25 }?.level, 16)
        XCTAssertEqual(layout.commonEntry, 0x448)
        XCTAssertEqual(layout.levelTable, 0x400)
        XCTAssertEqual(layout.levelHandlers.count, 17)
        XCTAssertEqual(layout.dispatcher, 0x3200)
        XCTAssertEqual(layout.dispatcherLevel, 1)
        XCTAssertEqual(layout.irqTable, 0x5000)
        XCTAssertEqual(layout.irqHandlers.count, 240)
        XCTAssertEqual(layout.irqHandlers.first?.target, 0x53C0)
        XCTAssertNoThrow(try layout.json())
    }

    /// The flash past the extent the code uses as a flash address: built and
    /// passed to the flash routines 0x20E6/0x2400, or split into bytes for
    /// 0x1E596 and its wrapper 0x71CE. 0x249F0 at 0x15424 is 150000 ms for
    /// the timer routine 0x20E36: no reference.
    func testReferencesPastTheExtent() throws {
        let firmware = try ECFirmware(slice: try image())
        let references = firmware.referencesPastExtent
        print("refs past extent:", references.map { String(format: "0x%X<-0x%X", $0.address, $0.from) })
        let expected: [(Int, Int)] = [
            (0x2A600, 0x718C), (0x2A600, 0x71B2), (0x2A600, 0x16A16),
            (0x2A800, 0x11DD4), (0x2A800, 0x11E4A), (0x2A800, 0x11E70),
            (0x2B800, 0x11E1A), (0x2B800, 0x11EB8), (0x2B800, 0x11EE2),
            (0x2BC00, 0x124DC), (0x2BC00, 0x149A2)]
        XCTAssertEqual(references, expected.map { .init(address: $0.0, from: $0.1) })
        XCTAssertFalse(references.contains { $0.address == 0x249F0 }, "\(references)")
        XCTAssertTrue(references.allSatisfy { $0.address >= firmware.extent && $0.address < firmware.sliceSize })
    }

    func testRegisterMap() throws {
        let text = """
        # header
        name\taddress\twidth\tblock\tdescription\tsource
        GPIO_GPDRA\t0x00F01601\t1\tGPIO\t-\tregisters.h:1
        ETWD_ETXCNTLR\t0x00F01F10\t4\tETWD\tcounter\tregisters.h:2
        """
        let map = try ECRegisterMap(tsv: text)
        XCTAssertEqual(map.registers.count, 2)
        XCTAssertEqual(map.registers[1].width, 4)
        XCTAssertEqual(map.registers[1].description, "counter")
        XCTAssertNil(map.registers[0].description)
        XCTAssertEqual(map.register(at: 0xF01601)?.name, "GPIO_GPDRA")
        XCTAssertThrowsError(try ECRegisterMap(tsv: "name\taddress\nX\tnope\n"))
    }

    func testShippedRegisterMapReads() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let map = try ECRegisterMap(tsv: String(contentsOf: root.appendingPathComponent(
            "Skills/ghidra-ec/reference/it83xx-registers.tsv"), encoding: .utf8))
        XCTAssertGreaterThan(map.registers.count, 500)
        XCTAssertTrue(map.registers.allSatisfy { ECChipFamily.iteNDS32.registers.contains($0.address) })
        let irqs = try ECInterruptMap(tsv: String(contentsOf: root.appendingPathComponent(
            "Skills/ghidra-ec/reference/it83xx-irqs.tsv"), encoding: .utf8))
        XCTAssertEqual(irqs.source(of: 1), "WKO20")
    }

    /// The parts the UEFI tree shows, over a real BIOS copy: no gap, no
    /// overlap, the `.data` initializer where the reset code copies from.
    func testParts() throws {
        let firmware = try ECFirmware(slice: try image())
        XCTAssertEqual(firmware.parts.map(\.kind), [.vectors, .signature, .code, .dataInitializer, .free])
        XCTAssertEqual(firmware.parts.map(\.range), [0..<0x80, 0x80..<0xA0, 0xA0..<0x24974, 0x24974..<0x2497C,
                                                     0x2497C..<0x30000])
    }

    /// A slice built byte by byte: no start-up code to read, so no `.data`
    /// part; a chip read ends in the run-time data area.
    func testPartsOfASyntheticImage() throws {
        var data = Data(repeating: 0xFF, count: 0x2C000)
        data.replaceSubrange(0..<4, with: [0x48, 0x00, 0x00, 0x00])
        data.replaceSubrange(0x80..<0x90, with: [0xA5, 0xA5, 0xA5, 0xA5, 0xA5, 0xA5, 0xA5, 0x94, 0x85, 0x12,
                                                 0x5A, 0x5A, 0xAA, 0xAF, 0x55, 0x55])
        data.replaceSubrange(0x90..<0xA0, with: Array("ITE8380-EC-V9.99".utf8))
        for at in 0x100..<0x1FE { data[at] = 0x11 }
        let copy = try ECFirmware(slice: data)
        XCTAssertEqual(copy.extentSource, .heuristic)
        XCTAssertEqual(copy.parts.map(\.kind), [.vectors, .signature, .code, .free])
        XCTAssertEqual(copy.parts.last?.range, 0x200..<0x2C000)

        data[0x2A010] = 0x00
        let read = try ECFirmware(slice: data)
        XCTAssertTrue(read.chipRead)
        XCTAssertEqual(read.parts.map(\.kind), [.vectors, .signature, .code, .free, .runtimeData])
        XCTAssertEqual(read.parts.suffix(2).map(\.range), [0x200..<0x2A000, 0x2A000..<0x2C000])
    }
}
