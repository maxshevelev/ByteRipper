import CryptoKit
import Foundation

/// An EC firmware image read from a slice of a dump: where the linked image
/// ends, its identity, and what of the slice is not the image.
///
/// The identity is the SHA-256 of [0, extent) with the bytes the EC rewrites
/// in its own flash set to the family's values, so a BIOS copy and a read of
/// the chip of the same firmware are one module. The extent is where the
/// start-up code's `.data` copy source ends — the end of what the linker
/// placed — and, when that code cannot be read, the last byte that is not
/// erased (`ExtentSource.heuristic`).
public struct ECFirmware: Equatable, Sendable {
    public enum ExtentSource: String, Codable, Sendable {
        /// The end of the `.data` copy the reset code makes.
        case crt0
        /// The last byte that is not 0xFF, rounded up to 4.
        case heuristic
    }

    /// A byte the EC rewrites: where, what the slice holds, what the identity
    /// takes.
    public struct MaskedByte: Codable, Equatable, Sendable {
        public let offset: Int
        public let actual: UInt8
        public let normalised: UInt8
    }

    public let family: ECChipFamily
    public let sliceSize: Int
    public let extent: Int
    public let extentSource: ExtentSource
    /// The SHA-256 of the whole slice as read.
    public let rawSHA256: String
    /// The module's identity: [0, extent) normalised.
    public let sha256: String
    public let masked: [MaskedByte]
    /// True when bytes past the image are the EC's run-time data — a read of
    /// the chip, not a copy in a BIOS update.
    public let chipRead: Bool
    public let version: String?
    /// The image as Ghidra gets it: [0, extent), normalised.
    public let image: Data
    /// What the reset code does, when it was read.
    public let startup: ECStartup?

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case notEC
        case tailNotErased(firstAt: Int, extent: Int)

        public var description: String {
            switch self {
            case .notEC:
                return "not an EC firmware image of a known family"
            case let .tailNotErased(at, extent):
                return String(format: "the slice holds bytes past the image's end (0x%X) at 0x%X, outside the "
                              + "area the EC keeps its run-time data in: neither an erased BIOS copy nor a "
                              + "read of the chip", extent, at)
            }
        }
    }

    public static func isEC(_ data: Data) -> Bool { ECChipFamily.family(of: data) != nil }

    public init(slice data: Data) throws {
        let data = Data(data)   // zero-based indices
        guard let family = ECChipFamily.family(of: data) else { throw Failure.notEC }
        self.family = family
        sliceSize = data.count
        rawSHA256 = Self.hex(data)
        version = family.version(of: data)

        let startup = ECStartup(data, family: family)
        let extent: Int
        if let startup, let end = startup.dataSourceEnd {
            extent = end
            extentSource = .crt0
        } else {
            let limit = min(data.count, family.runtimeAreaStart)
            var last = limit - 1
            while last >= 0, data[last] == 0xFF { last -= 1 }
            extent = min(data.count, (last + 1 + 3) & ~3)
            extentSource = .heuristic
        }
        self.extent = extent
        self.startup = startup

        // Past the image: erased in a BIOS copy; in a chip read, the EC's
        // run-time data and nothing between.
        var firstWritten: Int?
        for at in extent..<data.count where data[at] != 0xFF {
            firstWritten = at
            break
        }
        if let first = firstWritten {
            guard first >= family.runtimeAreaStart else {
                throw Failure.tailNotErased(firstAt: first, extent: extent)
            }
            chipRead = true
        } else {
            chipRead = false
        }

        var image = data.prefix(extent)
        var masked: [MaskedByte] = []
        for (offset, value) in family.rewrittenBytes.sorted(by: { $0.key < $1.key }) where offset < extent {
            masked.append(MaskedByte(offset: offset, actual: image[offset], normalised: value))
            image[offset] = value
        }
        self.masked = masked
        self.image = Data(image)
        sha256 = Self.hex(self.image)
    }

    /// The name a module gets: the version string, in the letters a module's
    /// name may have.
    public var moduleName: String {
        let text = version ?? "EC-\(sha256.prefix(8))"
        let name = String(text.unicodeScalars.map {
            CharacterSet.alphanumerics.contains($0) && $0.isASCII || "._-".unicodeScalars.contains($0)
                ? Character($0) : "-"
        })
        return name.isEmpty ? "EC" : name
    }

    /// A constant the code builds that points past the image's extent but
    /// still inside the flash slice: `address`, and `from`, the instruction
    /// that completes it (the `ori`/`addi` after a `sethi`, or the load or
    /// store whose base and offset reach it).
    public struct FlashReference: Codable, Equatable, Sendable {
        public let address: Int
        public let from: Int
    }

    /// Every such reference, found by a straight walk of the code — from
    /// the vectors' end to the `.data` copy's source, or the extent — with
    /// the register constants `sethi`/`ori`/`movi`/`addi` leave. A value is
    /// taken when it is complete: not while the next instruction still adds
    /// to the same register. Sorted by address, then by `from`.
    public var referencesPastExtent: [FlashReference] {
        let base = Int(family.flashBase)
        let target = (base + extent)..<(base + sliceSize)
        let end = startup?.dataSource.map { min(Int($0), extent) } ?? extent
        var constants = NDS32.Constants()
        var found = Set<[Int]>()
        var pending: (register: Int, address: Int, from: Int)?
        var offset = 0x100
        while offset < end, let instruction = NDS32.decode(image, at: offset, base: family.flashBase) {
            let op = instruction.op
            if let held = pending {
                let extends: Bool
                switch op {
                case let .or(rt, ra, _), let .add(rt, ra, _): extends = ra == held.register && rt == held.register
                default: extends = false
                }
                if !extends { found.insert([held.address, held.from]) }
                pending = nil
            }
            switch op {
            case let .load(_, ra, imm, _), let .store(_, ra, imm, _):
                if let value = constants[ra] {
                    let at = Int(Int64(value) + Int64(imm))
                    if target.contains(at) { found.insert([at, Int(instruction.address)]) }
                }
            default: break
            }
            constants.step(op)
            switch op {
            case let .constant(rt, _), let .or(rt, _, _), let .add(rt, _, _):
                if let value = constants[rt], target.contains(Int(value)) {
                    pending = (rt, Int(value), Int(instruction.address))
                }
            default: break
            }
            offset += instruction.length
        }
        if let held = pending { found.insert([held.address, held.from]) }
        return found.sorted { $0[0] != $1[0] ? $0[0] < $1[0] : $0[1] < $1[1] }
            .map { FlashReference(address: $0[0], from: $0[1]) }
    }

    /// The layout the review pass names, read from the image.
    public var layout: ECLayout { ECLayout(image, family: family, startup: startup) }

    static func hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// What the reset code does, read from its instructions: the `.data` copy
/// (source, target, length) and the call it ends in, `main`.
public struct ECStartup: Codable, Equatable, Sendable {
    public let resetEntry: UInt64
    public let dataSource: UInt64?
    public let dataTarget: UInt64?
    public let dataLength: UInt64?
    /// The last direct call before the reset code's endless loop.
    public let main: UInt64?

    public var dataSourceEnd: Int? {
        guard let dataSource, let dataLength else { return nil }
        return Int(dataSource + dataLength)
    }

    /// Nil when the first vector is not a jump into the image.
    init?(_ data: Data, family: ECChipFamily) {
        guard let first = NDS32.decode(data, at: 0), case let .jump(reset) = first.op,
              reset < UInt64(data.count) else { return nil }
        resetEntry = reset
        var constants = NDS32.Constants()
        var tested: Int?
        var source: UInt64?
        var target: UInt64?
        var length: UInt64?
        var lastCall: UInt64?
        var main: UInt64?
        var offset = Int(reset)
        for _ in 0..<400 {
            guard let instruction = NDS32.decode(data, at: offset) else { break }
            switch instruction.op {
            case let .branchZero(rt, true):
                tested = rt
            case let .load(_, ra, imm, _) where source == nil:
                // The first load from a constant address in the image, past
                // the vectors: the copy's source, its length the register the
                // copy was guarded by.
                if let base = constants[ra] {
                    let at = UInt64(Int64(base) + Int64(imm))
                    if at >= 0x100, at < UInt64(data.count), let tested, let count = constants[tested], count > 0 {
                        source = at
                        length = UInt64(count)
                    }
                }
            case let .store(_, ra, imm, _) where source != nil && target == nil:
                if let base = constants[ra] {
                    let at = UInt64(Int64(base) + Int64(imm))
                    if family.ram.contains(at) { target = at }
                }
            case let .call(callee):
                lastCall = callee
            case let .callRegister(rb):
                lastCall = constants[rb].map(UInt64.init)
            case let .jump(to) where to == instruction.address:
                main = lastCall
            default:
                break
            }
            constants.step(instruction.op)
            if main != nil { break }
            offset += instruction.length
        }
        if let source, let length, Int(source + length) <= data.count, target != nil {
            dataSource = source
            dataTarget = target
            dataLength = length
        } else {
            dataSource = nil
            dataTarget = nil
            dataLength = nil
        }
        self.main = main
    }
}
