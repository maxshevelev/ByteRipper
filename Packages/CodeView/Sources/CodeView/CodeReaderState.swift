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
    /// How the Functions list is laid out: as the artifact lists the functions
    /// (by entry address), as a tree of calls under the module's entry, or in
    /// groups by how far the review has got with each function.
    public enum FunctionOrder: Int, CaseIterable, Sendable {
        case address, calls, review
    }

    /// What a heading in the Functions list stands for: how far the review
    /// has got with the functions under it. The words are the view's; the
    /// state names the group, so a test is not tied to a language.
    ///
    /// The declaration order is the order the grouped list shows them in.
    public enum FunctionGroup: Int, CaseIterable, Sendable {
        /// Nothing keeps it from full.
        case full
        /// Some review work is done, but a gap remains.
        case partial
        /// Nothing of the review: a placeholder name, no comments, no names.
        case decompiled
        /// A library routine the module links in, or one tagged `library`.
        case library
        /// An external function or a thunk: the exporter writes no C for it.
        case noBody
        /// An artifact from before the level was recorded, or one whose level
        /// this reader does not know.
        case unknown
    }

    /// Whose library a library function is, as the grouped list sorts the
    /// Library functions group: the three kinds a review names, then a library
    /// whose kind was not recorded (a bare `library` tag, a v7 artifact).
    public enum LibrarySection: Int, CaseIterable, Sendable {
        case edk2, amd, intel, unrecorded
    }

    /// One row of the Functions list: a heading, a library kind's heading
    /// inside the Library functions group, or a function and how deep in the
    /// call tree or the groups it sits.
    public enum FunctionRow: Equatable, Sendable {
        case group(FunctionGroup)
        case section(LibrarySection)
        case function(Int, level: Int)

        /// The function's place in the artifact, nil for a heading.
        public var function: Int? {
            if case let .function(index, _) = self { return index }
            return nil
        }

        /// The heading's group, nil for a function and a library kind.
        public var group: FunctionGroup? {
            if case let .group(group) = self { return group }
            return nil
        }

        /// The library kind's heading, nil for any other row.
        public var section: LibrarySection? {
            if case let .section(section) = self { return section }
            return nil
        }

        /// Whether the row is a heading — a group or a library kind — and not
        /// a function.
        public var isHeading: Bool { function == nil }

        /// How far the row is set in: a group's heading, a library kind's
        /// heading under it, or a function of the tree or the groups.
        public var level: Int {
            switch self {
            case let .function(_, level): level
            case .section: 1
            case .group: 0
            }
        }
    }
    /// What the left navigator lists. One at a time, so every function stays
    /// visible when Functions is chosen; the other lists are a click away.
    public enum List: Int, CaseIterable, Sendable {
        case functions, strings, postCodes, statusCodes
    }

    public private(set) var model: CodeModel
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

    /// How the Functions list is laid out, and its rows in that order: the
    /// search narrows them in every order.
    public private(set) var functionOrder: FunctionOrder = .address
    public private(set) var functionRows: [FunctionRow] = []
    /// A function's row, in the order in front.
    private var functionRowByIndex: [Int: Int] = [:]
    /// A row of the call tree is a place, not a function: the function called
    /// from every caller is a row under each of them, and each opens by itself.
    /// A place is named by its path, the functions from a root down to it. The
    /// paths of the rows, in step with them; the row of a path; and the places
    /// the reader opened — every place starts closed.
    private var callPaths: [[Int]] = []
    private var callRowByPath: [[Int]: Int] = [:]
    private var openCalls: Set<[Int]> = []
    /// The place the reader chose a function at: the function has other rows,
    /// and the list must not move the selection off the one that was clicked.
    private var selectedCallPath: [Int]?
    /// The review groups whose functions are hidden, and how many functions
    /// each group holds whether it is open or closed.
    private var collapsedGroups: Set<FunctionGroup> = []
    private var groupCounts: [FunctionGroup: Int] = [:]
    /// The same for the library kinds inside the Library functions group.
    private var collapsedSections: Set<LibrarySection> = []
    private var sectionCounts: [LibrarySection: Int] = [:]
    /// How many of a kind's functions are the library registry's entries.
    private var sectionEntryCounts: [LibrarySection: Int] = [:]

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
        case .functions: functionRows.count
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

    /// Lays the Functions list out in `order`. Returns whether anything
    /// changed.
    @discardableResult
    public mutating func show(_ order: FunctionOrder) -> Bool {
        guard functionOrder != order else { return false }
        functionOrder = order
        refilter()
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
        layOutFunctions(model.functions(matching: needle), searching: !needle.isEmpty)
        listedStrings = artifact.strings.indices.filter { index in
            let entry = artifact.strings[index]
            return matches(entry.value, entry.type, entry.address.description)
        }
        // POST codes by value, the places that send one together, and what
        // the analysis could not tell after the codes it could.
        listedPostCodes = artifact.postCodes.indices.filter { index in
            let entry = artifact.postCodes[index]
            let function = entry.function.flatMap(model.function(at:)).map { model.functions[$0].name } ?? ""
            return matches(entry.text, entry.port, entry.address.description, function,
                           entry.value.map { String(format: "0x%llX", $0) } ?? "")
                || entry.via.contains { matches($0.name ?? "") }
        }.sorted { left, right in
            let a = artifact.postCodes[left], b = artifact.postCodes[right]
            switch (a.value, b.value) {
            case let (x?, y?) where x != y: return x < y
            case (.some, nil): return true
            case (nil, .some): return false
            default: return left < right
            }
        }
        listedStatusCodes = artifact.statusCodeCalls.indices.filter { index in
            let entry = artifact.statusCodeCalls[index]
            return matches(entry.text, entry.address.description)
                || entry.context.contains { matches($0) }
        }
    }

    /// The navigator row of a function, when Functions lists it.
    public func row(ofFunction index: Int) -> Int? {
        if let path = selectedCallPath, path.last == index, let row = callRowByPath[path] {
            return row
        }
        return functionRowByIndex[index]
    }

    /// The row at `row`, when the navigator has one.
    public func functionRow(at row: Int) -> FunctionRow? {
        functionRows.indices.contains(row) ? functionRows[row] : nil
    }

    /// The function at `row`, nil for a heading and for a row out of reach.
    public func function(atRow row: Int) -> Int? {
        functionRow(at: row)?.function
    }

    // MARK: - Laying the Functions list out

    /// Builds `functionRows` from the functions `matching` the search, in the
    /// order in front, and the indices the view looks rows up by.
    private mutating func layOutFunctions(_ matching: [Int], searching: Bool) {
        groupCounts = [:]
        sectionCounts = [:]
        sectionEntryCounts = [:]
        callPaths = []
        callRowByPath = [:]
        switch functionOrder {
        case .address:
            functionRows = matching.map { .function($0, level: 0) }
        case .calls:
            functionRows = callRows(matching, searching: searching)
        case .review:
            functionRows = reviewRows(matching)
        }
        listedFunctions = functionRows.compactMap(\.function)
        functionRowByIndex = [:]
        for (row, item) in functionRows.enumerated() {
            // The first of a function's places answers for it.
            if let function = item.function, functionRowByIndex[function] == nil {
                functionRowByIndex[function] = row
            }
        }
        for (row, path) in callPaths.enumerated() { callRowByPath[path] = row }
    }

    /// The functions in their review levels, each level's functions in
    /// alphabetical order: a group is a node of its own, and its functions
    /// hang under it while it is open. An empty level is not shown.
    private mutating func reviewRows(_ matching: [Int]) -> [FunctionRow] {
        var rows: [FunctionRow] = []
        for group in FunctionGroup.allCases {
            let members = matching.filter { self.group(of: $0) == group }.sorted(by: byName)
            guard !members.isEmpty else { continue }
            groupCounts[group] = members.count
            rows.append(.group(group))
            guard !collapsedGroups.contains(group) else { continue }
            guard group == .library else {
                rows.append(contentsOf: members.map { FunctionRow.function($0, level: 1) })
                continue
            }
            // The library functions under their kinds, each kind a heading of
            // its own; a kind with none is not shown.
            for section in LibrarySection.allCases {
                let kind = members.filter { librarySection(of: $0) == section }
                guard !kind.isEmpty else { continue }
                sectionCounts[section] = kind.count
                sectionEntryCounts[section] = kind.filter { registryMark(of: $0) == .entry }.count
                rows.append(.section(section))
                guard !collapsedSections.contains(section) else { continue }
                rows.append(contentsOf: kind.map { FunctionRow.function($0, level: 2) })
            }
        }
        return rows
    }

    /// Whose library a library function is; nil for a function at any other
    /// level.
    public func librarySection(of index: Int) -> LibrarySection? {
        let function = model.functions[index]
        guard function.reviewLevel == .library else { return nil }
        switch function.libraryKind {
        case .edk2: return .edk2
        case .amd: return .amd
        case .intel: return .intel
        case nil: return .unrecorded
        }
    }

    /// Whether a library kind shows its functions. Open until the reader
    /// closes it, as a group is.
    public func isSectionExpanded(_ section: LibrarySection) -> Bool {
        !collapsedSections.contains(section)
    }

    /// Opens or closes a library kind's functions.
    public mutating func toggleSectionExpanded(_ section: LibrarySection) {
        if collapsedSections.contains(section) {
            collapsedSections.remove(section)
        } else {
            collapsedSections.insert(section)
        }
        refilter()
    }

    /// Whether the review group shows its functions. True for a group whose
    /// rows are hidden: a group is open until the reader closes it.
    public func isGroupExpanded(_ group: FunctionGroup) -> Bool {
        !collapsedGroups.contains(group)
    }

    /// Opens or closes a review group's functions.
    public mutating func toggleGroupExpanded(_ group: FunctionGroup) {
        if collapsedGroups.contains(group) {
            collapsedGroups.remove(group)
        } else {
            collapsedGroups.insert(group)
        }
        refilter()
    }

    /// The navigator's alphabetical order: by name, case aside; two functions
    /// with one name keep the artifact's order.
    private func byName(_ left: Int, _ right: Int) -> Bool {
        let order = model.functions[left].name.caseInsensitiveCompare(model.functions[right].name)
        return order == .orderedSame ? left < right : order == .orderedAscending
    }

    /// The review level the artifact records for a function; nil — an
    /// artifact from before v7 — is shown as unrecorded rather than guessed.
    /// The review group a function belongs to, in any order of the list.
    public func group(of index: Int) -> FunctionGroup {
        switch model.functions[index].reviewLevel {
        case .full: .full
        case .partial: .partial
        case .decompiled: .decompiled
        case .library: .library
        case .noBody: .noBody
        case nil: .unknown
        }
    }

    /// How a function stands to the library registry, as its badge says:
    /// the entry's, matched but not the entry (edited, differing, in
    /// conflict), or not in the registry.
    public enum RegistryMark: Equatable, Sendable {
        case entry
        case matched
    }

    public func registryMark(of index: Int) -> RegistryMark? {
        guard let entry = model.functions[index].libraryEntry else { return nil }
        return entry.isEntry ? .entry : .matched
    }

    /// How many of the functions under the library kind's heading at `row`
    /// are the registry's entries; nil when the row is not a kind's heading.
    public func registryCount(at row: Int) -> Int? {
        guard case let .section(section)? = functionRow(at: row) else { return nil }
        return sectionEntryCounts[section]
    }

    /// How many functions the heading at `row` covers, open or closed; nil
    /// when the row is not a heading.
    public func groupCount(at row: Int) -> Int? {
        switch functionRow(at: row) {
        case let .group(group)?: groupCounts[group]
        case let .section(section)?: sectionCounts[section]
        default: nil
        }
    }

    /// The functions as a forest of calls, as rows: a function nothing in the
    /// module calls — the image's entry, a notify callback, a slot of a
    /// services table — starts a tree, and what it calls hangs under it. Every
    /// function a function calls is under it, however many others call it too,
    /// so a row's calls are all of its calls; and every place starts closed, so
    /// only the rows the reader opened are ever walked.
    ///
    /// Most functions reach a module through such a root; a function that a
    /// call from outside the module reaches — a protocol's implementation — is
    /// one too. A function called only from inside a circle of calls has no
    /// root, so the first of the circle starts its own tree.
    ///
    /// A search shows what it matches as one alphabetical list, whatever the
    /// trees hold: a find is not a walk down the calls, and a matching
    /// function whose callers do not match would otherwise sit under a row
    /// that is not there.
    private mutating func callRows(_ matching: [Int], searching: Bool) -> [FunctionRow] {
        guard !model.functions.isEmpty else { return [] }
        if searching {
            return matching.sorted(by: byName).map { FunctionRow.function($0, level: 0) }
        }
        var rows: [FunctionRow] = []
        var paths: [[Int]] = []
        func walk(_ path: [Int]) {
            guard let index = path.last else { return }
            rows.append(.function(index, level: path.count - 1))
            paths.append(path)
            guard openCalls.contains(path), hasCalls(path: path) else { return }
            for callee in calls(of: index) { walk(path + [callee]) }
        }
        for root in callRoots() { walk([root]) }
        callPaths = paths
        return rows
    }

    /// The functions a function calls, each once, alphabetically.
    private func calls(of index: Int) -> [Int] {
        Array(Set(model.functions[index].callees.compactMap { model.function(at: $0) })).sorted(by: byName)
    }

    /// The tops of the trees: the image's entry, then the functions nothing
    /// calls, then the first of each circle no root reaches, each set
    /// alphabetically. Built the same way on every look, so opening one row
    /// never moves another.
    private func callRoots() -> [Int] {
        var roots = model.functions.indices.filter { model.functions[$0].callers.isEmpty }
        roots.sort(by: byName)
        // The image's entry first, where the headers or the name place it.
        if let entry = entryFunction() {
            roots.removeAll { $0 == entry }
            roots.insert(entry, at: 0)
        }
        var reached: Set<Int> = []
        func reach(_ start: Int) {
            var waiting = [start]
            while let index = waiting.popLast() {
                guard reached.insert(index).inserted else { continue }
                waiting += model.functions[index].callees.compactMap { model.function(at: $0) }
            }
        }
        roots.forEach(reach)
        for index in model.functions.indices.sorted(by: byName) where !reached.contains(index) {
            roots.append(index)
            reach(index)
        }
        return roots
    }

    /// The place a row of the call tree stands for; nil in any other layout.
    public func callPath(atRow row: Int) -> [Int]? {
        callPaths.indices.contains(row) ? callPaths[row] : nil
    }

    /// The row of a place, when the tree shows it.
    public func row(ofCallPath path: [Int]) -> Int? {
        callRowByPath[path]
    }

    /// Whether this place gives calls to open. A function already on the way
    /// down to it is a recursive call: its row says so and goes no deeper, or
    /// the tree would have no bottom.
    public func hasCalls(path: [Int]) -> Bool {
        guard let index = path.last, !path.dropLast().contains(index) else { return false }
        return !calls(of: index).isEmpty
    }

    /// Whether the tree shows this place's calls.
    public func isExpanded(path: [Int]) -> Bool {
        openCalls.contains(path)
    }

    /// Opens or closes one place's calls. The same function under another
    /// caller stays as it is. A place with no calls has nothing to open.
    public mutating func toggleExpanded(path: [Int]) {
        guard hasCalls(path: path) else { return }
        if openCalls.remove(path) == nil { openCalls.insert(path) }
        refilter()
    }

    /// The reader chose the function at this row: that is the place its
    /// selection stays at.
    public mutating func chooseCallPlace(atRow row: Int) {
        selectedCallPath = callPath(atRow: row)
    }

    /// The places open now by the functions' entries, which outlive a revision:
    /// a function's index does not.
    public var openCallEntries: [[CodeAddress]] {
        openCalls.map { $0.map { model.functions[$0].entry } }
    }

    /// Opens the places a pane before this one had open; a function no longer
    /// here takes its place with it, and a call no longer made is never walked.
    public mutating func openCallPlaces(_ places: [[CodeAddress]]) {
        for place in places {
            let path = place.compactMap { model.function(at: $0) }
            if path.count == place.count { openCalls.insert(path) }
        }
        refilter()
    }

    /// Opens the shortest way down to `index`, so a row of it shows. Returns
    /// whether any place was closed.
    private mutating func expandAncestors(of index: Int) -> Bool {
        var waiting = callRoots().map { [$0] }
        var reached = Set(waiting.compactMap(\.last))
        var next = 0
        while next < waiting.count {
            let path = waiting[next]
            next += 1
            guard let last = path.last else { continue }
            if last == index {
                var changed = false
                for length in path.indices.dropFirst() where openCalls.insert(Array(path[..<length])).inserted {
                    changed = true
                }
                return changed
            }
            for callee in calls(of: last) where reached.insert(callee).inserted {
                waiting.append(path + [callee])
            }
        }
        return false
    }

    /// The module's entry: the function at the image's entry point when the
    /// module's headers are known, or else the one Ghidra named `entry`.
    /// A review renames the entry, so the name alone is not enough.
    private func entryFunction() -> Int? {
        if let layout = model.layout {
            let base = artifact.program?.imageBase?.value ?? layout.imageBase
            var candidates = [base &+ layout.entryPoint]
            // A TE image's entry point is counted from the image base the
            // loader takes the stripped header off.
            if layout.format == .te { candidates.append(base &+ layout.entryPoint &- 40) }
            for address in candidates {
                if let index = model.function(at: CodeAddress(address)) { return index }
            }
        }
        return model.functions.firstIndex {
            $0.name.caseInsensitiveCompare("entry") == .orderedSame
        }
    }

    /// Makes Functions the list in front, with the search cleared and the
    /// calls above it opened when either hides `index`. Returns whether the
    /// navigator changed.
    @discardableResult
    public mutating func reveal(function index: Int) -> Bool {
        guard model.functions.indices.contains(index) else { return false }
        var changed = show(.functions)
        if row(ofFunction: index) == nil {
            if !searchText.isEmpty {
                search("")
                changed = true
            }
            if functionOrder == .calls, expandAncestors(of: index) {
                refilter()
                changed = true
            }
            if functionOrder == .review, collapsedGroups.contains(group(of: index)) {
                collapsedGroups.remove(group(of: index))
                refilter()
                changed = true
            }
            if functionOrder == .review, let section = librarySection(of: index),
               collapsedSections.contains(section) {
                collapsedSections.remove(section)
                refilter()
                changed = true
            }
        }
        return changed
    }

    /// Takes in functions' code read after the model was made.
    public mutating func load(_ functions: [CodeArtifact.Function]) {
        model.load(functions)
        if let function, line == nil { line = model.lines(ofFunction: function).first?.global }
        // A search looks through the instructions, which are here now.
        if !searchText.isEmpty { refilter() }
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
