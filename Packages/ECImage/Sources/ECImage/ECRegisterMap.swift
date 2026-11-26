import Foundation

/// A chip's registers as our own table keeps them
/// (`Skills/ghidra-ec/reference/<chip>-registers.tsv`): lines starting with
/// `#` are the header comment, the first other line names the columns
/// `name address width block description source status`.
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
        /// `published`, `firmware` or `unverified` (column 7); nil in a
        /// table without the column.
        public var status: String? = nil
    }

    public struct Malformed: Error, CustomStringConvertible {
        public let line: Int
        public let reason: String
        public var description: String { "line \(line): \(reason)" }
    }

    public let registers: [Register]
    /// The published entries an IT8227E entry took the place of (the
    /// table's `# replaced:` lines): the names an earlier map gave.
    public let replaced: [Register]
    private let byAddress: [UInt64: Int]

    public init(tsv text: String) throws {
        func register(_ row: [String], line number: Int) throws -> Register {
            guard row.count >= 2, let address = Self.number(row[1]) else {
                throw Malformed(line: number, reason: "no address")
            }
            let width = row.count > 2 ? Int(row[2]) ?? 1 : 1
            guard [1, 2, 4].contains(width) else { throw Malformed(line: number, reason: "width \(row[2])") }
            let note = row.count > 4 ? row[4] : "-"
            return Register(name: row[0], address: address, width: width,
                            block: row.count > 3 ? row[3] : "",
                            description: note == "-" || note.isEmpty ? nil : note,
                            source: row.count > 5 ? row[5] : "",
                            status: row.count > 6 && !row[6].isEmpty ? row[6] : nil)
        }
        self.registers = try Self.rows(text).map { try register($0.1, line: $0.0) }
        self.replaced = try Self.replacedRows(text).map { try register($0.1, line: $0.0) }
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

    /// The `# replaced: <row>\t(by <name>)` lines, without the `(by …)`.
    static func replacedRows(_ text: String) -> [(Int, [String])] {
        var rows: [(Int, [String])] = []
        for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = line.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            guard line.hasPrefix("# replaced: ") else { continue }
            var row = line.dropFirst("# replaced: ".count).split(separator: "\t", omittingEmptySubsequences: false)
                .map(String.init)
            if row.last?.hasPrefix("(by ") == true { row.removeLast() }
            rows.append((index + 1, row))
        }
        return rows
    }

    static func number(_ text: String) -> UInt64? {
        text.hasPrefix("0x") || text.hasPrefix("0X") ? UInt64(text.dropFirst(2), radix: 16) : UInt64(text)
    }
}

/// The interrupt controller's numbers (`<chip>-irqs.tsv`: `irq name source`).
public struct ECInterruptMap: Equatable, Sendable {
    /// One row: `irq name description source status`, or the older
    /// `irq name source`.
    public struct Entry: Codable, Equatable, Sendable {
        public let irq: Int
        public let name: String
        /// Nil where the table says `-`.
        public let description: String?
        public let source: String
        /// `published`, `firmware` or `unverified`; nil in a list without
        /// the column.
        public let status: String?
    }

    public let names: [Int: [String]]
    public let entries: [Entry]
    /// The published entries an IT8227E entry took the place of (`# replaced:`).
    public let replaced: [Entry]

    public init(tsv text: String) throws {
        func entry(_ row: [String], line number: Int) throws -> Entry {
            guard row.count >= 2, let irq = Int(row[0]) else {
                throw ECRegisterMap.Malformed(line: number, reason: "no interrupt number")
            }
            if row.count <= 3 {
                return Entry(irq: irq, name: row[1], description: nil, source: row.count > 2 ? row[2] : "", status: nil)
            }
            return Entry(irq: irq, name: row[1], description: row[2] == "-" || row[2].isEmpty ? nil : row[2],
                         source: row[3], status: row.count > 4 && !row[4].isEmpty ? row[4] : nil)
        }
        let entries = try ECRegisterMap.rows(text).map { try entry($0.1, line: $0.0) }
        var names: [Int: [String]] = [:]
        for entry in entries where !(names[entry.irq] ?? []).contains(entry.name) {
            names[entry.irq, default: []].append(entry.name)
        }
        self.names = names
        self.entries = entries
        self.replaced = try ECRegisterMap.replacedRows(text).map { try entry($0.1, line: $0.0) }
    }

    /// The interrupt's entry when the table names exactly one.
    public func entry(of irq: Int) -> Entry? {
        let listed = entries.filter { $0.irq == irq }
        return listed.count == 1 ? listed[0] : nil
    }

    /// The interrupt's source when the table names exactly one.
    public func source(of irq: Int) -> String? {
        guard let listed = names[irq], listed.count == 1 else { return nil }
        return listed[0]
    }
}
