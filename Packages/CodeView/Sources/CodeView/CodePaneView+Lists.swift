import ALSplitView
import AnalysisProfiles
import AppKit
import AppPalette
import CodeAnalysis
import Find
import HelpBook
import HelpUI
import Localization
import ToolModuleKit

// The navigator's lists and the listing as tables: their rows and cells.
extension CodePaneView: NSTableViewDataSource, NSTableViewDelegate {
    public func numberOfRows(in tableView: NSTableView) -> Int {
        tableView === functionTable ? state.rowCount : state.lines.count
    }

    /// A group's node, and a library kind's, is not a function: it opens and
    /// closes its rows and is not selected.
    public func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        !(tableView === functionTable && state.list == .functions
            && state.functionRow(at: row)?.isHeading == true)
    }

    /// The list selects every place of the function in the call tree, which only
    /// the pane does: the reader's click, key or drag still chooses one row, and
    /// a heading none. With this answered the table asks nothing about one row.
    public func tableView(_ tableView: NSTableView,
                          selectionIndexesForProposedSelection proposed: IndexSet) -> IndexSet {
        guard tableView === functionTable else { return proposed }
        let rows = proposed.filteredIndexSet { self.tableView(tableView, shouldSelectRow: $0) }
        return rows.count == 1 ? rows : tableView.selectedRowIndexes
    }

    public func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        if tableView === table {
            let reused = tableView.makeView(withIdentifier: CodeListingRowView.identifier, owner: nil)
            return reused as? CodeListingRowView ?? CodeListingRowView()
        }
        guard tableView === functionTable else { return nil }
        let reused = tableView.makeView(withIdentifier: CodeNavigatorRowView.identifier, owner: nil)
        let rowView = reused as? CodeNavigatorRowView ?? CodeNavigatorRowView()
        rowView.marksNode = state.list == .functions && state.functionOrder == .calls && state.searchText.isEmpty
        rowView.isOpenPlace = state.isOpenPlace(atRow: row)
        return rowView
    }

    public func tableView(_ tableView: NSTableView,
                          viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if tableView === functionTable {
            guard row >= 0, row < state.rowCount else { return nil }
            let functionRow = state.list == .functions ? state.functionRow(at: row) : nil
            if let group = functionRow?.group {
                return groupCell(in: tableView, group: group, row: row)
            }
            if let section = functionRow?.section {
                return sectionCell(in: tableView, section: section, row: row)
            }
            if functionRow == .callsCut {
                let cell = cell(in: tableView, identifier: .init("code-calls-cut"), monospaced: false)
                cell.textField?.font = Self.navigatorFont()
                cell.textField?.textColor = .secondaryLabelColor
                cell.textField?.stringValue = L("Too many ways lead here: the list stops at this point")
                cell.showsDisclosure(false)
                cell.showsIcon(nil)
                cell.showsBadge(false)
                cell.onToggle = nil
                cell.indent = 0
                cell.toolTip = nil
                return cell
            }
            // The by-address table's first column: where the function is.
            if state.list == .functions, tableColumn?.identifier.rawValue == FunctionColumn.address.rawValue,
               let index = functionRow?.function {
                let cell = cell(in: tableView, identifier: .init("code-function-address"), monospaced: true)
                cell.showsDisclosure(false)
                cell.showsIcon(nil)
                cell.showsBadge(false)
                cell.onToggle = nil
                cell.textField?.font = Self.navigatorCodeFont()
                cell.textField?.stringValue = model.displayAddress(model.functions[index].entry)
                cell.textField?.textColor = .secondaryLabelColor
                cell.toolTip = nil
                return cell
            }
            if state.list == .postCodes, let id = tableColumn?.identifier.rawValue,
               let column = PostColumn(rawValue: id) {
                let entry = artifact.postCodes[state.listedPostCodes[row]]
                let cell = cell(in: tableView, identifier: .init("code-post"), monospaced: false)
                cell.textField?.font = postFont(entry, column)
                cell.textField?.stringValue = postCodeCell(entry, column)
                let unknown = entry.value == nil && entry.unresolved != nil
                cell.textField?.textColor = unknown || column == .via || column == .address
                    ? .secondaryLabelColor : .labelColor
                cell.toolTip = postCodeDetail(entry)
                return cell
            }
            if state.list == .strings, let id = tableColumn?.identifier.rawValue,
               let column = StringColumn(rawValue: id) {
                let entry = artifact.strings[state.listedStrings[row]]
                let cell = cell(in: tableView, identifier: .init("code-string"), monospaced: false)
                let text = stringCell(entry, column)
                cell.textField?.font = column == .address ? Self.navigatorCodeFont() : Self.navigatorFont()
                cell.textField?.stringValue = text
                cell.textField?.textColor = column == .address ? .secondaryLabelColor : .labelColor
                // The whole string, which the column may have cut.
                cell.toolTip = column == .text && !text.isEmpty ? text : nil
                return cell
            }
            let cell = cell(in: tableView, identifier: .init("code-navigator"), monospaced: false)
            // A cell from the queue was made at the size before a zoom.
            cell.textField?.font = Self.navigatorFont()
            cell.textField?.stringValue = navigatorText(at: row)
            // The triangle belongs to a function of the call tree; the badge
            // to a function a revision changed. Both are set per row, and a
            // reused cell must not keep either.
            cell.showsDisclosure(false)
            cell.showsIcon(nil)
            cell.onToggle = nil
            cell.showsBadge(false)
            // A name the module's own evidence gave reads as a name; Ghidra's
            // FUN_ placeholder reads quieter. The reason is one hover away.
            var color = NSColor.labelColor
            var reason: String?
            if state.list == .functions, let functionRow, let index = functionRow.function {
                let function = model.functions[index]
                if function.hasPlaceholderName { color = .secondaryLabelColor }
                reason = function.nameReason
                // In the grouped order the hover also says where the review
                // stands: its level, and what still keeps it from full.
                if state.functionOrder == .review {
                    reason = [reason, Self.reviewDetail(function)]
                        .compactMap { $0 }.joined(separator: "\n")
                }
                // help: panel.code.registry
                // A function the library registry matched says so wherever
                // it is listed.
                if let registry = Self.registryDetail(function) {
                    reason = [reason, registry].compactMap { $0 }.joined(separator: "\n")
                }
                // A call tree's rows stand in as deep as they are; a deeper
                // level keeps the last one's inset rather than running the
                // name off the pane. A group's functions start under its
                // name, past its chevron and a step beyond its mark, as a
                // source list nests its items; a library kind's, a step
                // further under the kind.
                if state.functionOrder == .review, state.searchText.isEmpty {
                    cell.indent = CodeNavigatorCell.disclosureRoom
                        + Self.groupMemberIndent * CGFloat(functionRow.level)
                } else {
                    cell.indent = CGFloat(min(functionRow.level, Self.navigatorLevels)) * Self.navigatorIndent
                }
                // The mark says how far the review has got, in every order: a
                // root of the tree and a call under it alike.
                cell.showsIcon(Self.functionMark(state.group(of: index),
                                                 library: state.librarySection(of: index)))
                if unopenedChanges[index] != nil {
                    cell.textField?.font = Self.navigatorBoldFont()
                    cell.badge.text = L("New")
                    cell.showsBadge(true)
                }
                // A search is one alphabetical list of what it found: the
                // calls it would open say nothing about a find.
                if state.functionOrder == .calls, state.searchText.isEmpty,
                   let path = state.callPath(atRow: row) {
                    // The place being read and the way down to it read bold; the
                    // function's other places have only their mark.
                    if state.isOnChosenWay(atRow: row) { cell.textField?.font = Self.navigatorBoldFont() }
                    let expandable = state.hasCalls(path: path)
                    let expanded = state.isExpanded(path: path)
                    cell.showsDisclosure(true)
                    cell.showsCalls(expandable: expandable, expanded: expanded)
                    ControlHelp.describe(cell.disclosure,
                                         expanded ? L("Hide calls") : L("Show calls"))
                    cell.onToggle = { [weak self] in self?.toggleCalls(at: path) }
                    if state.isRecursiveCall(path: path) {
                        cell.textField?.stringValue += "  ↺"
                        reason = [reason, L("Recursive call: this function is already on the way here")]
                            .compactMap { $0 }.joined(separator: "\n")
                    }
                }
            }
            if state.list == .postCodes {
                let entry = artifact.postCodes[state.listedPostCodes[row]]
                if entry.value == nil, entry.unresolved != nil { color = .secondaryLabelColor }
                reason = postCodeDetail(entry)
            }
            cell.textField?.textColor = color
            // help: panel.code.stubs
            // A stub nothing reaches says so after its name, in grey.
            if state.list == .functions, let index = functionRow?.function,
               case let function = model.functions[index], function.reviewLevel == .stub, function.unused == true, let field = cell.textField {
                let text = NSMutableAttributedString(string: field.stringValue,
                                                     attributes: [.font: Self.navigatorFont(), .foregroundColor: color])
                text.append(NSAttributedString(string: "  " + L("unused"),
                                               attributes: [.font: Self.navigatorFont(),
                                                            .foregroundColor: NSColor.tertiaryLabelColor]))
                field.attributedStringValue = text
            }
            cell.toolTip = reason
            if state.list == .functions, let index = functionRow?.function,
               let notes = notesByFunction[index], !notes.isEmpty,
               let field = cell.textField {
                let marked = NSMutableAttributedString(string: field.stringValue, attributes: [
                    .foregroundColor: color, .font: field.font ?? Self.navigatorFont()
                ])
                marked.append(NSAttributedString(string: "  ◆", attributes: [
                    .foregroundColor: CodeColors.color(for: notes[0].kind), .font: field.font ?? Self.navigatorFont()
                ]))
                field.attributedStringValue = marked
                cell.toolTip = ([reason].compactMap { $0 } + notes.map(\.heading)).joined(separator: "\n")
            }
            return cell
        }
        let lines = state.lines
        guard row >= 0, row < lines.count else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("code-line")
        let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? CodeLineCell
            ?? CodeLineCell(identifier: identifier)
        let global = lines[lines.startIndex + row].global
        var shown = model.listingRow(ofLine: global)
        // An annotated instruction carries its note at the end of the row.
        for note in notesByLine[global] ?? [] {
            let mark = "    ◆ \(note.heading)"
            shown.tokens.append(CodeToken(start: shown.text.utf16.count + 4,
                                          length: mark.utf16.count - 4, kind: note.kind))
            shown.text += mark
        }
        cell.line.show(shown.text, tokens: shown.tokens, font: Self.codeFont(),
                       highlighted: highlightedRanges(in: shown.tokens, of: shown.text),
                       explainable: explainableInListing((shown.text, shown.tokens), line: global))
        cell.line.onClick = { [weak self] link, event in
            self?.clickListing(on: link, event: event, line: global) ?? false
        }
        cell.line.onExplain = { [weak self, weak view = cell.line] token, text, rect in
            guard let self, let view else { return }
            self.explainListing(line: global, token: token, text: text, rect: rect, in: view)
        }
        return cell
    }

    // help: panel.code.lists
    /// A click on the function already chosen marks its zone in the dump
    /// again: the reader may have selected other bytes since.
    @objc func functionRowClicked() {
        defer { functionSelectionMoved = false }
        guard !functionSelectionMoved, state.list == .functions,
              NSApp.currentEvent?.modifierFlags.intersection([.command, .shift]).isEmpty ?? true,
              functionTable.clickedRow >= 0
        else { return }
        clickedChosenFunction(row: functionTable.clickedRow)
    }

    /// The row clicked again: when it is the function on screen, its zone.
    func clickedChosenFunction(row: Int) {
        guard let index = state.function(atRow: row), index == state.function else { return }
        focusSelectedFunction()
    }

    public func tableViewSelectionDidChange(_ notification: Notification) {
        guard !syncingSelection, let table = notification.object as? NSTableView else { return }
        if table === functionTable {
            let row = functionTable.selectedRow
            guard row >= 0 else { return }
            opensOnDescription = false
            leaveDescription()
            functionSelectionMoved = true
            selectNavigatorRow(row)
        } else if table === self.table {
            let lines = state.lines
            let row = table.selectedRow
            guard row >= 0, row < lines.count else { return }
            select(line: lines[lines.startIndex + row].global)
            notifyInstruction()
        }
    }

    func navigatorText(at row: Int) -> String {
        switch state.list {
        case .functions:
            guard let index = state.function(atRow: row) else { return "" }
            let function = model.functions[index]
            return function.name.isEmpty ? model.displayAddress(function.entry) : function.name
        case .strings:
            let entry = artifact.strings[state.listedStrings[row]]
            return entry.value.isEmpty
                ? stringCell(entry, .address)
                : "\(stringCell(entry, .address))  \(stringCell(entry, .text))"
        case .postCodes:
            return postCodeText(artifact.postCodes[state.listedPostCodes[row]])
        case .statusCodes:
            let entry = artifact.statusCodeCalls[state.listedStatusCodes[row]]
            return "\(model.displayAddress(entry.address))  \(entry.text)"
        }
    }

    /// What a string's row says in one column. The text is one line: a line
    /// break, a tab or another control character in it is written as C
    /// writes it — the strings are mostly C's own format strings — so a row
    /// never runs onto the next.
    func stringCell(_ entry: CodeArtifact.StringEntry, _ column: StringColumn) -> String {
        switch column {
        case .address: return model.displayAddress(entry.address)
        case .text: return Self.oneLine(entry.value)
        }
    }

    static func oneLine(_ text: String) -> String {
        var line = ""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\n": line += "\\n"
            case "\r": line += "\\r"
            case "\t": line += "\\t"
            case "\0"..<" ", "\u{7F}"..."\u{9F}":
                line += String(format: "\\x%02X", scalar.value)
            case "\u{2028}", "\u{2029}":
                line += String(format: "\\u%04X", scalar.value)
            default: line.unicodeScalars.append(scalar)
            }
        }
        return line
    }

    // help: panel.code.post-codes
    /// A POST code's row: the value, at the width it is written, and the
    /// function that sends it. One the analysis could not tell says what it
    /// lacks. An artifact before v5 lists its OUT instructions as they read.
    private func postCodeText(_ entry: CodeArtifact.PostCode) -> String {
        guard entry.value != nil || entry.unresolved != nil else {
            return "\(model.displayAddress(entry.address))  \(entry.text)"
        }
        let place = postCodeCell(entry, .function)
        return postCodeCell(entry, .code) + "  " + (place.isEmpty ? model.displayAddress(entry.address) : place)
    }

    /// What a POST code's row says on hover: where it is sent, through what,
    /// and why a value is missing.
    private func postCodeDetail(_ entry: CodeArtifact.PostCode) -> String? {
        guard entry.value != nil || entry.unresolved != nil else { return nil }
        var lines = [String(format: L("Sent at %1$@"), model.displayAddress(entry.address))]
        if !entry.via.isEmpty {
            lines.append(String(format: L("Through %1$@"),
                                entry.via.map { $0.name ?? model.displayAddress($0.function) }.joined(separator: " → ")))
        }
        if let width = entry.width {
            lines.append(String(format: L("%1$@-byte write to port %2$@"), "\(width)",
                                entry.portNumber.map { String(format: "0x%llX", $0) } ?? "?"))
        }
        switch entry.unresolved {
        case .portParameter: lines.append(L("The port comes from a caller this module does not show: a service other modules call."))
        case .portComputed: lines.append(L("The port is worked out at run time."))
        case .valueParameter: lines.append(L("The value comes from a caller this module does not show."))
        case .valueComputed: lines.append(L("The value is worked out at run time: from a table, a loop or a read."))
        case nil: break
        }
        return lines.joined(separator: "\n")
    }

    /// A row's cell, reused from the table's queue when it has one: a listing
    /// of a large function scrolls through thousands of rows.
    private func cell(in tableView: NSTableView, identifier: NSUserInterfaceItemIdentifier,
                      monospaced: Bool) -> CodeNavigatorCell {
        if let reused = tableView.makeView(withIdentifier: identifier, owner: nil)
            as? CodeNavigatorCell {
            // A cell from the queue was inset by the row that used it before,
            // and keeps the triangle and the badge of whatever list it was
            // drawn in: both belong to a function row alone.
            reused.indent = 0
            reused.showsDisclosure(false)
            reused.showsIcon(nil)
            reused.showsBadge(false)
            reused.onToggle = nil
            return reused
        }
        let cell = CodeNavigatorCell(identifier: identifier)
        cell.textField?.font = monospaced ? Self.navigatorCodeFont() : Self.navigatorFont()
        return cell
    }

    /// A node of the grouped order: the group's name and how many functions it
    /// holds, in the panel's grey and one weight up from the rows under it,
    /// with the triangle that opens and closes those rows.
    private func groupCell(in tableView: NSTableView, group: FunctionGroup, row: Int) -> NSView {
        let cell = cell(in: tableView, identifier: .init("code-group"), monospaced: false)
        cell.textField?.font = .systemFont(ofSize: Self.navigatorSize, weight: .semibold)
        cell.textField?.textColor = .secondaryLabelColor
        cell.textField?.stringValue = Self.title(of: group)
            + " (\(state.groupCount(at: row) ?? 0))"
        cell.showsIcon("group.\(group)")
        cell.showsBadge(false)
        cell.indent = 0
        cell.showsDisclosure(true)
        let expanded = state.isGroupExpanded(group)
        cell.showsCalls(expandable: true, expanded: expanded)
        ControlHelp.describe(cell.disclosure,
                             expanded ? L("Hide functions") : L("Show functions"))
        cell.toolTip = nil
        cell.onToggle = { [weak self] in self?.toggleGroup(group) }
        return cell
    }

    /// A library kind's node under Library functions: its name and how many
    /// functions it holds, set in under the group with the kind's badge, and
    /// the chevron that opens and closes them.
    private func sectionCell(in tableView: NSTableView, section: LibrarySection, row: Int) -> NSView {
        let cell = cell(in: tableView, identifier: .init("code-section"), monospaced: false)
        cell.textField?.font = .systemFont(ofSize: Self.navigatorSize, weight: .semibold)
        cell.textField?.textColor = .secondaryLabelColor
        let count = state.groupCount(at: row) ?? 0
        cell.textField?.stringValue = Self.title(of: section) + " (\(count))"
        cell.showsIcon("library.\(section).entry")
        cell.showsBadge(false)
        cell.indent = Self.groupMemberIndent
        cell.showsDisclosure(true)
        let expanded = state.isSectionExpanded(section)
        cell.showsCalls(expandable: true, expanded: expanded)
        ControlHelp.describe(cell.disclosure,
                             expanded ? L("Hide functions") : L("Show functions"))
        cell.toolTip = nil
        cell.onToggle = { [weak self] in self?.toggleSection(section) }
        return cell
    }

    /// Opens or closes a library kind's functions.
    private func toggleSection(_ section: LibrarySection) {
        foldRows { $0.toggleSectionExpanded(section) }
        if let row = (0..<state.rowCount).first(where: { state.functionRow(at: $0)?.section == section }) {
            describeDisclosure(at: row, state.isSectionExpanded(section) ? L("Hide functions") : L("Show functions"))
        }
    }

    /// Opens or closes a review group's functions.
    private func toggleGroup(_ group: FunctionGroup) {
        foldRows { $0.toggleGroupExpanded(group) }
        if let row = (0..<state.rowCount).first(where: { state.functionRow(at: $0)?.group == group }) {
            describeDisclosure(at: row, state.isGroupExpanded(group) ? L("Hide functions") : L("Show functions"))
        }
    }

}
