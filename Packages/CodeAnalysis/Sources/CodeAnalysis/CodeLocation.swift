import Foundation

/// A place in a module's code, as Ghidra addresses it: a function, and
/// perhaps one instruction in it. What an annotation on code, an agent's
/// `open_code` and a Code panel opened at a place all name.
public struct CodeLocation: Equatable, Hashable, Sendable {
    /// The entry of the function.
    public var function: CodeAddress?
    /// An instruction; the function holding it when `function` is nil.
    public var address: CodeAddress?

    public init(function: CodeAddress? = nil, address: CodeAddress? = nil) {
        self.function = function
        self.address = address
    }

    public var isEmpty: Bool { function == nil && address == nil }
}

extension CodeArtifact {
    /// Where a location is in this artifact: the function's index and the
    /// instruction's index in the whole listing — the numbers a Code screen
    /// is restored to. An address outside every function finds nothing.
    public func indices(of location: CodeLocation) -> (function: Int?, line: Int?) {
        var line = 0
        var found: (function: Int?, line: Int?) = (nil, nil)
        for (index, function) in functions.enumerated() {
            if let entry = location.function, function.entry == entry, found.function == nil {
                found.function = index
            }
            if let address = location.address, found.line == nil,
               let offset = function.instructions.firstIndex(where: { $0.address == address }),
               location.function == nil || function.entry == location.function {
                found.line = line + offset
                if found.function == nil { found.function = index }
            }
            line += function.instructions.count
        }
        return found
    }

    /// The function whose name is `text`, or whose entry it spells.
    public func function(named text: String) -> Function? {
        let wanted = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let address = CodeAddress(hex: wanted), let function = functions.first(where: { $0.entry == address }) {
            return function
        }
        return functions.first { $0.name == wanted }
    }

    /// The function an instruction belongs to.
    public func function(containing address: CodeAddress) -> Function? {
        functions.first { $0.instructions.contains { $0.address == address } }
    }
}
