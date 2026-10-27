import Foundation

/// A code artifact arranged for reading: every lookup the Code panel and an
/// agent make, answered from indices built once rather than by walking the
/// artifact again on every click.
///
/// The artifact is what Ghidra wrote; this is the same facts, keyed. Functions
/// are found by entry, an instruction by the module bytes it covers (a sorted
/// table, searched by halves), and an address by the instructions that refer
/// to it. A model is a value, built off the main actor for a large module:
/// BdsDxe has 529 functions and 44 100 instructions.
public struct CodeModel: Sendable {
    /// One instruction in artifact order: its place in the whole listing, the
    /// function that holds it, and the instruction itself.
    public struct Line: Equatable, Sendable {
        public let global: Int
        public let function: Int
        public let instruction: CodeArtifact.Instruction
    }

    /// An instruction that refers to an address — a call, a jump, a read or a
    /// write — as the artifact records it.
    public struct Use: Equatable, Sendable {
        /// The instruction's place in `lines`.
        public let line: Int
        public let function: Int
        public let from: CodeAddress
        public let type: String
    }

    public let artifact: CodeArtifact
    /// The original module's headers, when the module bytes were given and
    /// could be trusted. Without it no address has a module offset.
    public let layout: ModuleLayout?
    /// The module's bytes, when given: what a global holds in the image.
    public let moduleBytes: Data?
    public let lines: [Line]

    private let imageBase: UInt64?
    private let functionByEntry: [CodeAddress: Int]
    /// Each function's lines: instructions are appended function by function,
    /// so a function's lines are one run.
    private let functionLines: [Range<Int>]
    /// Each line's module bytes, nil where the address has none.
    private let lineRanges: [Range<UInt64>?]
    /// The lines that have bytes, ordered by where those bytes start.
    private let byOffset: [Int]
    /// What a search matches a function against, lowered once.
    private let functionText: [String]
    private let uses: [CodeAddress: [Use]]
    /// The instruction at each address.
    private let lineByAddress: [CodeAddress: Int]
    /// A function by its name, for the C lexer: the first of a repeated name.
    let functionsByName: [String: Int]

    public init(artifact: CodeArtifact, moduleBytes: Data?) {
        self.init(artifact: artifact,
                  layout: moduleBytes.flatMap { try? ModuleLayout(module: $0) }, moduleBytes: moduleBytes)
    }

    public init(artifact: CodeArtifact, layout: ModuleLayout?, moduleBytes: Data? = nil) {
        self.artifact = artifact
        self.layout = layout
        self.moduleBytes = layout == nil ? nil : moduleBytes
        let base = artifact.program?.imageBase?.value
        imageBase = base

        var lines: [Line] = []
        var functionLines: [Range<Int>] = []
        var functionByEntry: [CodeAddress: Int] = [:]
        var functionText: [String] = []
        var uses: [CodeAddress: [Use]] = [:]
        for (index, function) in artifact.functions.enumerated() {
            // The first function at an entry wins, as a list search would.
            if functionByEntry[function.entry] == nil {
                functionByEntry[function.entry] = index
            }
            let start = lines.count
            var text = [function.name, function.entry.description, function.signature ?? ""]
            for instruction in function.instructions {
                let line = lines.count
                lines.append(Line(global: line, function: index, instruction: instruction))
                text.append(instruction.text)
                if let mnemonic = instruction.mnemonic { text.append(mnemonic) }
                for reference in instruction.references {
                    uses[reference.to, default: []].append(Use(
                        line: line, function: index,
                        from: instruction.address, type: reference.type))
                }
            }
            functionLines.append(start..<lines.count)
            functionText.append(text.joined(separator: "\n").lowercased())
        }

        let lineRanges: [Range<UInt64>?] = lines.map { line in
            layout?.fileRange(for: line.instruction.address,
                              count: line.instruction.bytes.count, imageBase: base)
        }
        let byOffset = lineRanges.indices
            .filter { lineRanges[$0] != nil }
            .sorted { left, right in
                let leftStart = lineRanges[left]!.lowerBound
                let rightStart = lineRanges[right]!.lowerBound
                return leftStart == rightStart ? left < right : leftStart < rightStart
            }

        var lineByAddress: [CodeAddress: Int] = [:]
        for line in lines where lineByAddress[line.instruction.address] == nil {
            lineByAddress[line.instruction.address] = line.global
        }
        var functionsByName: [String: Int] = [:]
        for (index, function) in artifact.functions.enumerated()
        where !function.name.isEmpty && functionsByName[function.name] == nil {
            functionsByName[function.name] = index
        }
        self.lineByAddress = lineByAddress
        self.functionsByName = functionsByName
        self.lines = lines
        self.functionLines = functionLines
        self.functionByEntry = functionByEntry
        self.functionText = functionText
        self.lineRanges = lineRanges
        self.byOffset = byOffset
        self.uses = uses
    }

    public var functions: [CodeArtifact.Function] { artifact.functions }

    // MARK: - Functions

    /// The function whose entry is `address`.
    public func function(at address: CodeAddress) -> Int? {
        functionByEntry[address]
    }

    /// A function by its name or by its entry address, as an agent names one.
    public func function(named text: String) -> Int? {
        let wanted = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let address = CodeAddress(hex: wanted), let index = function(at: address) {
            return index
        }
        return functions.firstIndex { $0.name == wanted }
    }

    /// The function's lines, in address order as Ghidra listed them.
    public func lines(ofFunction index: Int) -> ArraySlice<Line> {
        guard functionLines.indices.contains(index) else { return [] }
        return lines[functionLines[index]]
    }

    /// The functions whose name, entry, signature or instruction text
    /// contains `needle`, case aside. An empty needle matches every function.
    public func functions(matching needle: String) -> [Int] {
        let needle = needle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return Array(functions.indices) }
        return functionText.indices.filter { functionText[$0].contains(needle) }
    }

    /// What to call an address in a list: the function there, or the address
    /// as the listing shows it.
    public func name(for address: CodeAddress) -> String {
        if let index = function(at: address), !functions[index].name.isEmpty {
            return functions[index].name
        }
        return displayAddress(address)
    }

    // MARK: - Addresses and bytes

    /// The module offset of an address, or nil when the module holds no byte
    /// for it.
    public func moduleOffset(of address: CodeAddress) -> UInt64? {
        layout?.fileOffset(for: address, imageBase: imageBase)
    }

    public func moduleRange(of address: CodeAddress, count: Int) -> Range<UInt64>? {
        layout?.fileRange(for: address, count: count, imageBase: imageBase)
    }

    /// The bytes one line covers.
    public func moduleRange(ofLine line: Int) -> Range<UInt64>? {
        guard lineRanges.indices.contains(line) else { return nil }
        return lineRanges[line]
    }

    /// The whole stored range of a function: its size from the entry when the
    /// layout maps it, or else the span of its instructions' bytes.
    public func moduleRange(ofFunction index: Int) -> Range<UInt64>? {
        guard functions.indices.contains(index), layout != nil else { return nil }
        let function = functions[index]
        if let size = function.size, size > 0,
           let range = moduleRange(of: function.entry, count: size) {
            return range
        }
        let ranges = functionLines[index].compactMap { lineRanges[$0] }
        guard let lower = ranges.map(\.lowerBound).min(),
              let upper = ranges.map(\.upperBound).max()
        else { return nil }
        return lower..<upper
    }

    /// The bytes a string occupies: its terminator included, and two bytes per
    /// character when Ghidra says it is a wide string. When the layout has no
    /// range that long the first byte is still worth showing.
    public func moduleRange(of entry: CodeArtifact.StringEntry) -> Range<UInt64>? {
        let count = entry.isWide
            ? max(2, (entry.value.utf16.count + 1) * 2)
            : max(1, entry.value.utf8.count + 1)
        return moduleRange(of: entry.address, count: count)
            ?? moduleRange(of: entry.address, count: 1)
    }

    /// The line that holds a module range picked in the hex view: the one
    /// whose bytes contain an empty range's offset or overlap a range, or the
    /// nearest line before it when no line's bytes are there.
    public func line(forModuleRange range: Range<UInt64>) -> Int? {
        guard !byOffset.isEmpty else { return nil }
        // The first line starting after the range's start; every line before it
        // starts at or before the start.
        var low = 0
        var high = byOffset.count
        while low < high {
            let middle = (low + high) / 2
            if lineRanges[byOffset[middle]]!.lowerBound <= range.lowerBound {
                low = middle + 1
            } else {
                high = middle
            }
        }
        // A line starting at or before the start holds it when its bytes reach
        // past it. Instructions do not overlap, so the nearest one decides.
        if low > 0 {
            let candidate = byOffset[low - 1]
            let bytes = lineRanges[candidate]!
            if range.isEmpty ? bytes.contains(range.lowerBound) : bytes.overlaps(range) {
                return candidate
            }
        }
        // A non-empty range may begin in a gap and reach a later line.
        if !range.isEmpty, low < byOffset.count,
           lineRanges[byOffset[low]]!.overlaps(range) {
            return byOffset[low]
        }
        return low > 0 ? byOffset[low - 1] : nil
    }

    /// The offset of an address in the module bytes — the number the hex
    /// view's offset column shows. An address with no bytes (an external
    /// target, an uninitialised global) keeps Ghidra's address.
    public func displayAddress(_ address: CodeAddress) -> String {
        guard let offset = moduleOffset(of: address) else { return address.description }
        return "0x" + String(offset, radix: 16, uppercase: true)
    }

    /// The instruction at an address, when the listing has one.
    public func line(at address: CodeAddress) -> Int? {
        lineByAddress[address]
    }

    /// The instruction's text with every address it refers to written as a
    /// module offset, the way the listing's first column is. Ghidra prints a
    /// target as its own virtual address (`JZ 0x000010bc`); in a TE image
    /// that is not where the bytes are. Only the instruction's references are
    /// rewritten — an immediate that happens to look like an address is a
    /// value, and stays as Ghidra wrote it.
    public func displayText(of instruction: CodeArtifact.Instruction) -> String {
        display(instruction).text
    }

    /// The displayed text and where in it each reference's target is, with
    /// what a click on it leads to.
    func display(_ instruction: CodeArtifact.Instruction)
        -> (text: String, targets: [(start: Int, length: Int, link: CodeLink?)]) {
        guard !instruction.references.isEmpty else { return (instruction.text, []) }
        let targets = Set(instruction.references.map(\.to.value))
        var result = ""
        var found: [(start: Int, length: Int, link: CodeLink?)] = []
        var rest = Substring(instruction.text)
        while let start = rest.range(of: "0x") {
            result += rest[..<start.lowerBound]
            let digits = rest[start.upperBound...].prefix { $0.isHexDigit }
            let literal = rest[start.lowerBound..<digits.endIndex]
            if let value = UInt64(digits, radix: 16), targets.contains(value) {
                let address = CodeAddress(value)
                let written = moduleOffset(of: address)
                    .map { "0x" + String($0, radix: 16, uppercase: true) } ?? String(literal)
                found.append((result.utf16.count, written.utf16.count, link(to: address)))
                result += written
            } else {
                result += literal
            }
            rest = rest[digits.endIndex...]
        }
        return (result + rest, found)
    }

    // MARK: - Uses

    /// The instructions that refer to `address`, in listing order: who calls a
    /// function, jumps to a label, or reads and writes a global or a string.
    public func uses(of address: CodeAddress) -> [Use] {
        uses[address] ?? []
    }
}

extension CodeArtifact.StringEntry {
    /// Whether Ghidra stored the string as UTF-16 (`unicode`,
    /// `TerminatedUnicode`) rather than as bytes.
    public var isWide: Bool {
        let type = type.lowercased()
        return type.contains("unicode") || type.contains("wide") || type.contains("utf16")
    }
}
