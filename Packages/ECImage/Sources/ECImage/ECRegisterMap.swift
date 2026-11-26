import Foundation

/// A chip's registers as our own table keeps them
/// (`Skills/ghidra-ec/reference/<chip>-registers.tsv`): lines starting with
/// `#` are the header comment, the first other line names the columns
/// `name address width block description source`.
public struct ECRegisterMap: Equatable, Sendable {
    public struct Register: Codable, Equatable, Sendable {
        public let name: String
        public let address: UInt64
        /// In bytes.
        public let width: Int
        public let block: String
        /// Nil where the table says `-`.
        public let description: String?
        public let source: String
    }

    public struct Malformed: Error, CustomStringConvertible {
        public let line: Int
        public let reason: String
        public var description: String { "line \(line): \(reason)" }
    }

    public let registers: [Register]
    private let byAddress: [UInt64: Int]

    public init(tsv text: String) throws {
        var registers: [Register] = []
        for (number, row) in try Self.rows(text) {
            guard row.count >= 2, let address = Self.number(row[1]) else {
                throw Malformed(line: number, reason: "no address")
            }
            let width = row.count > 2 ? Int(row[2]) ?? 1 : 1
            guard [1, 2, 4].contains(width) else { throw Malformed(line: number, reason: "width \(row[2])") }
            let note = row.count > 4 ? row[4] : "-"
            registers.append(Register(name: row[0], address: address, width: width,
                                      block: row.count > 3 ? row[3] : "",
                                      description: note == "-" || note.isEmpty ? nil : note,
                                      source: row.count > 5 ? row[5] : ""))
        }
        self.registers = registers
        var byAddress: [UInt64: Int] = [:]
        for (index, register) in registers.enumerated() where byAddress[register.address] == nil {
            byAddress[register.address] = index
        }
        self.byAddress = byAddress
    }

    /// The first register the table lists at `address`.
    public func register(at address: UInt64) -> Register? {
        byAddress[address].map { registers[$0] }
    }

    /// The data rows with their line numbers, past the comments and the
    /// column line.
    static func rows(_ text: String) throws -> [(Int, [String])] {
        var rows: [(Int, [String])] = []
        var sawColumns = false
        for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = line.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            if line.isEmpty || line.hasPrefix("#") { continue }
            if !sawColumns {
                sawColumns = true
                continue
            }
            rows.append((index + 1, line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)))
        }
        return rows
    }

    static func number(_ text: String) -> UInt64? {
        text.hasPrefix("0x") || text.hasPrefix("0X") ? UInt64(text.dropFirst(2), radix: 16) : UInt64(text)
    }
}

/// The interrupt controller's numbers (`<chip>-irqs.tsv`: `irq name source`).
public struct ECInterruptMap: Equatable, Sendable {
    public let names: [Int: [String]]

    public init(tsv text: String) throws {
        var names: [Int: [String]] = [:]
        for (number, row) in try ECRegisterMap.rows(text) {
            guard row.count >= 2, let irq = Int(row[0]) else {
                throw ECRegisterMap.Malformed(line: number, reason: "no interrupt number")
            }
            if !(names[irq] ?? []).contains(row[1]) { names[irq, default: []].append(row[1]) }
        }
        self.names = names
    }

    /// The interrupt's source when the table names exactly one.
    public func source(of irq: Int) -> String? {
        guard let listed = names[irq], listed.count == 1 else { return nil }
        return listed[0]
    }
}
