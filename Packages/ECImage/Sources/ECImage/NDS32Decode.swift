import Foundation

/// The few Andes NDS32 instructions the image's own layout is read from:
/// constant loads, byte and word loads and stores, calls and jumps. Anything
/// else decodes as `.other` with its length, so a walk keeps its place.
///
/// NDS32 stores an instruction big-endian whatever the data's byte order; a
/// halfword with its top bit set is a 16-bit instruction, else the word is a
/// 32-bit one.
enum NDS32 {
    enum Op: Equatable {
        /// rt = value (sethi, movi, movi55, movpi45).
        case constant(rt: Int, value: UInt32)
        /// rt = ra | imm (ori).
        case or(rt: Int, ra: Int, imm: UInt32)
        /// rt = ra + imm (addi, addi333).
        case add(rt: Int, ra: Int, imm: Int32)
        /// A load or a store of `size` bytes at [ra + imm].
        case load(rt: Int, ra: Int, imm: Int32, size: Int)
        case store(rt: Int, ra: Int, imm: Int32, size: Int)
        /// lw rt, [ra + (rb << sv)].
        case loadIndexed(rt: Int, ra: Int, rb: Int, shift: Int)
        case call(target: UInt64)
        /// A call through a register (jral, jral5).
        case callRegister(rb: Int)
        case jump(target: UInt64)
        /// beqz/bnez on rt (the 16-bit forms).
        case branchZero(rt: Int, ifZero: Bool)
        case other
    }

    struct Instruction: Equatable {
        let address: UInt64
        let length: Int
        let op: Op
    }

    static func decode(_ bytes: Data, at offset: Int, base: UInt64 = 0) -> Instruction? {
        let start = bytes.startIndex + offset
        guard offset >= 0, offset + 2 <= bytes.count else { return nil }
        let half = UInt16(bytes[start]) << 8 | UInt16(bytes[start + 1])
        let address = base + UInt64(offset)
        if half & 0x8000 != 0 {
            return Instruction(address: address, length: 2, op: decode16(half, address: address))
        }
        guard offset + 4 <= bytes.count else { return nil }
        let word = UInt32(half) << 16 | UInt32(bytes[start + 2]) << 8 | UInt32(bytes[start + 3])
        return Instruction(address: address, length: 4, op: decode32(word, address: address))
    }

    private static func signed(_ value: UInt32, bits: Int) -> Int32 {
        let shift = 32 - bits
        return Int32(bitPattern: value << UInt32(shift)) >> Int32(shift)
    }

    private static func decode32(_ w: UInt32, address: UInt64) -> Op {
        let opcode = (w >> 25) & 0x3F
        let rt = Int((w >> 20) & 0x1F)
        let ra = Int((w >> 15) & 0x1F)
        let imm15 = w & 0x7FFF
        switch opcode {
        case 0x23: return .constant(rt: rt, value: (w & 0xFFFFF) << 12)                       // sethi
        case 0x22: return .constant(rt: rt, value: UInt32(bitPattern: signed(w & 0xFFFFF, bits: 20)))  // movi
        case 0x2C: return .or(rt: rt, ra: ra, imm: imm15)                                      // ori
        case 0x28: return .add(rt: rt, ra: ra, imm: signed(imm15, bits: 15))                   // addi
        case 0x00: return .load(rt: rt, ra: ra, imm: signed(imm15, bits: 15), size: 1)         // lbi
        case 0x10: return .load(rt: rt, ra: ra, imm: signed(imm15, bits: 15), size: 1)         // lbsi
        case 0x01: return .load(rt: rt, ra: ra, imm: signed(imm15, bits: 15) << 1, size: 2)    // lhi
        case 0x02: return .load(rt: rt, ra: ra, imm: signed(imm15, bits: 15) << 2, size: 4)    // lwi
        case 0x08: return .store(rt: rt, ra: ra, imm: signed(imm15, bits: 15), size: 1)        // sbi
        case 0x09: return .store(rt: rt, ra: ra, imm: signed(imm15, bits: 15) << 1, size: 2)   // shi
        case 0x0A: return .store(rt: rt, ra: ra, imm: signed(imm15, bits: 15) << 2, size: 4)   // swi
        case 0x1C where w & 0xFF == 0x02:                                                      // lw (indexed)
            return .loadIndexed(rt: rt, ra: ra, rb: Int((w >> 10) & 0x1F), shift: Int((w >> 8) & 0x3))
        case 0x24:                                                                             // j / jal
            // A word that only looks like a jump — data in the code, or
            // another chip's image — may point below zero: not a target.
            let reach = Int64(address) + Int64(signed(w & 0xFFFFFF, bits: 24)) * 2
            guard reach >= 0 else { return .other }
            let target = UInt64(reach)
            return w & 0x0100_0000 != 0 ? .call(target: target) : .jump(target: target)
        case 0x25 where w & 0x1F == 0x01:                                                      // jral
            return .callRegister(rb: Int((w >> 10) & 0x1F))
        default: return .other
        }
    }

    private static func decode16(_ h: UInt16, address: UInt64) -> Op {
        let w = UInt32(h)
        let rt3 = Int((w >> 6) & 0x7)
        let ra3 = Int((w >> 3) & 0x7)
        let imm3 = Int32(w & 0x7)
        switch (w >> 9) & 0x3F {                                     // the 333 forms
        case 0x10: return .load(rt: rt3, ra: ra3, imm: imm3 << 2, size: 4)     // lwi333
        case 0x12: return .load(rt: rt3, ra: ra3, imm: imm3 << 1, size: 2)     // lhi333
        case 0x13: return .load(rt: rt3, ra: ra3, imm: imm3, size: 1)          // lbi333
        case 0x14: return .store(rt: rt3, ra: ra3, imm: imm3 << 2, size: 4)    // swi333
        case 0x16: return .store(rt: rt3, ra: ra3, imm: imm3 << 1, size: 2)    // shi333
        case 0x17: return .store(rt: rt3, ra: ra3, imm: imm3, size: 1)         // sbi333
        case 0x0E: return .add(rt: rt3, ra: ra3, imm: imm3)                    // addi333
        default: break
        }
        if (w >> 10) & 0x1F == 0x01 {                                          // movi55
            return .constant(rt: Int((w >> 5) & 0x1F), value: UInt32(bitPattern: signed(w & 0x1F, bits: 5)))
        }
        if (w >> 9) & 0x3F == 0x3D {                                           // movpi45
            let rt4 = Int((w >> 5) & 0xF)
            return .constant(rt: rt4 < 12 ? rt4 : rt4 + 4, value: (w & 0x1F) + 16)
        }
        if (w >> 11) & 0xF == 0x8 { return .branchZero(rt: Int((w >> 8) & 0x7), ifZero: true) }    // beqz38
        if (w >> 11) & 0xF == 0x9 { return .branchZero(rt: Int((w >> 8) & 0x7), ifZero: false) }   // bnez38
        if w >> 5 == 0x6E9 { return .callRegister(rb: Int(w & 0x1F)) }        // jral5
        if (w >> 8) & 0x7F == 0x55 {                                           // j8
            return .jump(target: UInt64(truncatingIfNeeded: Int64(address) + Int64(signed(w & 0xFF, bits: 8)) * 2))
        }
        return .other
    }

    /// Register constants along a straight walk: what `sethi`/`ori`/`movi`/
    /// `addi` leave in each register. Any other write is not followed — the
    /// walks here read set-up code, where the values are built that way.
    struct Constants {
        private(set) var values: [Int: UInt32] = [:]

        mutating func step(_ op: Op) {
            switch op {
            case let .constant(rt, value): values[rt] = value
            case let .or(rt, ra, imm): values[rt] = values[ra].map { $0 | imm }
            case let .add(rt, ra, imm): values[rt] = values[ra].map { UInt32(bitPattern: Int32(bitPattern: $0) &+ imm) }
            case let .load(rt, _, _, _): values[rt] = nil
            case let .loadIndexed(rt, _, _, _): values[rt] = nil
            default: break
            }
        }

        subscript(_ register: Int) -> UInt32? { values[register] }
    }
}
