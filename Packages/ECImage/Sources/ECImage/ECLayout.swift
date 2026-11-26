import Foundation

/// The places of an ITE EC image the review pass names, read from its
/// instructions: the exception vectors, the interrupt level stubs and the
/// entry they share, the table of level handlers it calls through, and the
/// INTC dispatcher with its table of interrupt handlers.
///
/// Only structure, nothing semantic: what a handler does is the review's.
/// A part that cannot be read is left out, never guessed.
public struct ECLayout: Codable, Equatable, Sendable {
    public struct Vector: Codable, Equatable, Sendable {
        public let index: Int
        public let target: UInt64
        /// `ResetEntry`, `Exc_<name>` or `Isr_Lvl<N>`.
        public let name: String
        /// The interrupt level the stub passes on: the value it loads into r0
        /// before it jumps to the shared entry. Nil for an exception.
        public let level: Int?
    }

    public struct Handler: Codable, Equatable, Sendable {
        /// The interrupt level or the INTC interrupt number.
        public let number: Int
        /// Where the table holds it.
        public let slot: UInt64
        public let target: UInt64
    }

    public let vectors: [Vector]
    /// The entry every level stub jumps to.
    public let commonEntry: UInt64?
    /// The table the entry calls through, one handler per level.
    public let levelTable: UInt64?
    public let levelHandlers: [Handler]
    /// The function that reads the INTC's vector register and calls the
    /// interrupt's handler from its table.
    public let dispatcher: UInt64?
    /// The level whose handler calls the dispatcher.
    public let dispatcherLevel: Int?
    /// The slot of interrupt 0 in the dispatcher's table.
    public let irqTable: UInt64?
    public let irqHandlers: [Handler]
    public let startup: ECStartup?

    init(_ data: Data, family: ECChipFamily, startup: ECStartup?) {
        self.startup = startup
        let size = UInt64(data.count)
        func inCode(_ address: UInt64) -> Bool { address >= 0x100 && address < size && address % 2 == 0 }
        func word(_ at: UInt64) -> UInt64? {
            let at = Int(at)
            guard at >= 0, at + 4 <= data.count else { return nil }
            return UInt64(data[at]) | UInt64(data[at + 1]) << 8 | UInt64(data[at + 2]) << 16 | UInt64(data[at + 3]) << 24
        }
        /// The instructions from `start`, at most `count`, up to the first
        /// unconditional jump (included).
        func walk(_ start: UInt64, _ count: Int) -> [NDS32.Instruction] {
            var out: [NDS32.Instruction] = []
            var offset = Int(start)
            while out.count < count, let instruction = NDS32.decode(data, at: offset) {
                out.append(instruction)
                if case .jump = instruction.op { break }
                offset += instruction.length
            }
            return out
        }

        // The vectors: `j` words from 0 on.
        var vectors: [Vector] = []
        var entries: Set<UInt64> = []
        var offset = 0
        while offset + 4 <= data.count, data[offset] == 0x48,
              let instruction = NDS32.decode(data, at: offset), case let .jump(target) = instruction.op,
              target < size {
            let index = offset / 4
            if index == 0 {
                vectors.append(Vector(index: 0, target: target, name: "ResetEntry", level: nil))
            } else if index < family.firstInterruptVector {
                vectors.append(Vector(index: index, target: target,
                                      name: "Exc_" + (family.exceptionVectors[index] ?? "Vector\(index)"), level: nil))
            } else {
                // A level stub: saves, loads its level into r0, jumps on.
                var constants = NDS32.Constants()
                var level: Int?
                for step in walk(target, 6) {
                    if case let .jump(to) = step.op, to != step.address, let value = constants[0] {
                        level = Int(value)
                        entries.insert(to)
                    }
                    constants.step(step.op)
                }
                vectors.append(Vector(index: index, target: target,
                                      name: level.map { "Isr_Lvl\($0)" } ?? "Exc_Vector\(index)", level: level))
            }
            offset += 4
        }
        self.vectors = vectors
        let commonEntry = entries.count == 1 ? entries.first : nil
        self.commonEntry = commonEntry

        // The entry's table: `lw rt, [ra + (r0 << 2)]` with ra a constant.
        var levelTable: UInt64?
        if let commonEntry {
            var constants = NDS32.Constants()
            for step in walk(commonEntry, 40) {
                if case let .loadIndexed(_, ra, 0, 2) = step.op, let base = constants[ra] {
                    levelTable = UInt64(base)
                    break
                }
                constants.step(step.op)
            }
        }
        self.levelTable = levelTable
        var levelHandlers: [Handler] = []
        let levels = vectors.compactMap(\.level)
        if let levelTable, let top = levels.max() {
            for level in 0...top {
                let slot = levelTable + UInt64(level * 4)
                guard let target = word(slot), inCode(target) else { continue }
                levelHandlers.append(Handler(number: level, slot: slot, target: target))
            }
        }
        self.levelHandlers = levelHandlers

        // The dispatcher: called by a level handler, reads the INTC's vector
        // register, and loads the handler from a table indexed by it.
        var dispatcher: UInt64?
        var dispatcherLevel: Int?
        var irqTable: UInt64?
        search: for handler in levelHandlers {
            for step in walk(handler.target, 8) {
                guard case let .call(callee) = step.op, inCode(callee) else { continue }
                var constants = NDS32.Constants()
                var readsIVCT = false
                var table: UInt64?
                var lastConstant: UInt32?
                for inner in walk(callee, 40) {
                    switch inner.op {
                    case let .load(_, ra, imm, 1):
                        if let base = constants[ra], UInt64(Int64(base) + Int64(imm)) == family.ivctRegister {
                            readsIVCT = true
                        }
                    case let .constant(_, value) where readsIVCT && UInt64(value) < size:
                        lastConstant = value
                    case let .load(_, _, imm, 4) where readsIVCT && lastConstant != nil:
                        table = UInt64(Int64(lastConstant!) + Int64(imm)) + UInt64(family.ivctBias * 4)
                    default:
                        break
                    }
                    constants.step(inner.op)
                    if table != nil { break }
                }
                if readsIVCT, let table {
                    dispatcher = callee
                    dispatcherLevel = handler.number
                    irqTable = table
                    break search
                }
            }
        }
        self.dispatcher = dispatcher
        self.dispatcherLevel = dispatcherLevel
        self.irqTable = irqTable

        // Its entries: code addresses, up to the first that is not one, or
        // to where the handlers begin (the table sits before them).
        var irqHandlers: [Handler] = []
        if let irqTable {
            var lowest = UInt64.max
            for number in 0..<256 {
                let slot = irqTable + UInt64(number * 4)
                guard slot < lowest, let target = word(slot), inCode(target) else { break }
                lowest = min(lowest, target)
                irqHandlers.append(Handler(number: number, slot: slot, target: target))
            }
        }
        self.irqHandlers = irqHandlers
    }

    /// The layout as the Ghidra pass reads it: JSON, addresses as numbers.
    public func json() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
}
