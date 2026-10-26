import CodeAnalysis
import Foundation

/// What the code screen is showing, apart from how it is drawn: the list in
/// the navigator, the search over it, the selected function and instruction.
///
/// The presentation layer of the Code panel. `CodePaneView` draws this state
/// and turns clicks into its calls; the rules — a function the search hides is
/// brought back before it is selected, an instruction selects its function —
/// live here, where a test reaches them without a window.
public struct CodeReaderState: Sendable {
    /// What the left navigator lists. One at a time, so every function stays
    /// visible when Functions is chosen; the other lists are a click away.
    public enum List: Int, CaseIterable, Sendable {
        case functions, strings, postCodes, statusCodes
    }

    public let model: CodeModel
    public private(set) var list: List = .functions
    public private(set) var searchText = ""
    /// The selected function by its place in the artifact, not by a row: the
    /// navigator may be showing strings at the time.
    public private(set) var function: Int?
    /// The selected instruction by its place in the whole listing.
    public private(set) var line: Int?

    /// The navigator's rows for each list after the search, as indices into
    /// the artifact's functions, strings, POST writes and status-code calls.
    public private(set) var listedFunctions: [Int] = []
    public private(set) var listedStrings: [Int] = []
    public private(set) var listedPostCodes: [Int] = []
    public private(set) var listedStatusCodes: [Int] = []

    public init(model: CodeModel) {
        self.model = model
        refilter()
        selectFunction(0)
    }

    private var artifact: CodeArtifact { model.artifact }

    // MARK: - The navigator

    /// The number of rows the list in front has.
    public var rowCount: Int {
        switch list {
        case .functions: listedFunctions.count
        case .strings: listedStrings.count
        case .postCodes: listedPostCodes.count
        case .statusCodes: listedStatusCodes.count
        }
    }

    /// Switches the navigator. Returns whether anything changed.
    @discardableResult
    public mutating func show(_ list: List) -> Bool {
        guard self.list != list else { return false }
        self.list = list
        return true
    }

    /// Filters every list. Functions match their name, signature, address or
    /// instruction text; strings and the two call lists match what they say.
    public mutating func search(_ text: String) {
        searchText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        refilter()
    }

    private mutating func refilter() {
        let needle = searchText.lowercased()
        func matches(_ fields: String...) -> Bool {
            needle.isEmpty || fields.contains { $0.lowercased().contains(needle) }
        }
        listedFunctions = model.functions(matching: needle)
        listedStrings = artifact.strings.indices.filter { index in
            let entry = artifact.strings[index]
            return matches(entry.value, entry.type, entry.address.description)
        }
        listedPostCodes = artifact.postCodes.indices.filter { index in
            let entry = artifact.postCodes[index]
            return matches(entry.text, entry.port, entry.address.description)
        }
        listedStatusCodes = artifact.statusCodeCalls.indices.filter { index in
            let entry = artifact.statusCodeCalls[index]
            return matches(entry.text, entry.address.description)
                || entry.context.contains { matches($0) }
        }
    }

    /// The navigator row of a function, when Functions lists it.
    public func row(ofFunction index: Int) -> Int? {
        // The listed indices ascend, so the row is found by halves.
        var low = 0
        var high = listedFunctions.count
        while low < high {
            let middle = (low + high) / 2
            if listedFunctions[middle] < index { low = middle + 1 } else { high = middle }
        }
        return low < listedFunctions.count && listedFunctions[low] == index ? low : nil
    }

    /// Makes Functions the list in front, with the search cleared when it hides
    /// `index`. Returns whether the navigator changed.
    @discardableResult
    public mutating func reveal(function index: Int) -> Bool {
        guard model.functions.indices.contains(index) else { return false }
        var changed = show(.functions)
        if row(ofFunction: index) == nil, !searchText.isEmpty {
            search("")
            changed = true
        }
        return changed
    }

    // MARK: - Selection

    public var selectedFunction: CodeArtifact.Function? {
        guard let function, model.functions.indices.contains(function) else { return nil }
        return model.functions[function]
    }

    /// The selected function's instructions — the listing shows one function,
    /// the way C does.
    public var lines: ArraySlice<CodeModel.Line> {
        guard let function else { return [] }
        return model.lines(ofFunction: function)
    }

    /// The listing row of an instruction, when it is in the selected function.
    public func row(ofLine line: Int) -> Int? {
        let lines = lines
        guard lines.indices.contains(line) else { return nil }
        return line - lines.startIndex
    }

    public var selectedRow: Int? { line.flatMap(row(ofLine:)) }

    /// Selects a function and its first instruction.
    public mutating func selectFunction(_ index: Int) {
        guard model.functions.indices.contains(index) else { return }
        function = index
        line = model.lines(ofFunction: index).first?.global
    }

    /// Selects an instruction, and the function that holds it.
    public mutating func selectLine(_ global: Int) {
        guard model.lines.indices.contains(global) else { return }
        function = model.lines[global].function
        line = global
    }

    /// The selected instruction, when there is one.
    public var selectedLine: CodeModel.Line? {
        guard let line, model.lines.indices.contains(line) else { return nil }
        return model.lines[line]
    }
}
