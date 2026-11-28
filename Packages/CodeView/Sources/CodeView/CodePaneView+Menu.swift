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

// The Code panel's context menu and what its items may do.


extension CodePaneView: NSMenuItemValidation {
    /// Edit ▸ Copy (⌘C) with the list of functions in focus copies the
    /// selected function's name. The C copies its own selection, and the
    /// header's name is a selectable field.
    @objc public func copy(_ sender: Any?) {
        guard let name = copyableFunctionName else { return }
        Self.copyToPasteboard(name)
    }

    public func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(copy(_:)) { return copyableFunctionName != nil }
        return true
    }

    /// The selected function's name, while the list of functions has the
    /// keyboard.
    var copyableFunctionName: String? {
        guard window?.firstResponder === functionTable, state.list == .functions else { return nil }
        let row = functionTable.selectedRow
        guard row >= 0, let index = state.function(atRow: row) else { return nil }
        return model.functions[index].name
    }

    static func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

extension CodePaneView: NSMenuDelegate {
    /// The right-click menu of the function list and the listing, filled for
    /// the row clicked: Add Annotation…, and Open Annotation for each note
    /// already there.
    func rowMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        return menu
    }

    /// The place the right-click is on, and the notes there.
    func clickedPlace(in tableView: NSTableView) -> (location: CodeLocation, name: String, notes: [CodeNote])? {
        let row = tableView.clickedRow
        guard row >= 0 else { return nil }
        if tableView === functionTable {
            guard state.list == .functions, let index = state.function(atRow: row) else { return nil }
            let function = model.functions[index]
            let onFunction = (notesByFunction[index] ?? []).filter { $0.location.address == nil }
            return (CodeLocation(function: function.entry), function.name, onFunction)
        }
        let lines = state.lines
        guard row < lines.count else { return nil }
        let line = lines[lines.startIndex + row]
        let function = model.functions[line.function]
        return (CodeLocation(function: function.entry, address: line.instruction.address),
                "\(function.name) @ \(model.displayAddress(line.instruction.address))",
                notesByLine[line.global] ?? [])
    }

    public func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let tableView = menu === functionTable.menu ? functionTable : table
        guard let place = clickedPlace(in: tableView) else { return }
        if tableView === functionTable {
            // help: panel.code.copy-name
            let copy = menu.addItem(withTitle: L("Copy Name"), action: #selector(copyNameChosen(_:)),
                                    keyEquivalent: "")
            copy.target = self
            copy.representedObject = place.name
            if state.functionOrder == .calls, state.searchText.isEmpty {
                // help: panel.code.function-view
                let only = state.showsOnlyOpenWay
                let ways = menu.addItem(withTitle: only ? L("Show All Paths") : L("Show Only This Path"),
                                        action: #selector(callWaysChosen(_:)), keyEquivalent: "")
                ways.target = self
                ways.representedObject = NSNumber(value: tableView.clickedRow)
            }
            menu.addItem(.separator())
        }
        for note in place.notes {
            let item = menu.addItem(withTitle: L("Open Annotation “%1$@”", note.title),
                                    action: #selector(openNoteChosen(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = note.id
        }
        guard onAnnotate != nil else { return }
        // help: panel.code.annotate
        let add = menu.addItem(withTitle: L("Add Annotation…"), action: #selector(annotateChosen(_:)),
                               keyEquivalent: "")
        add.target = self
        add.representedObject = CodePlaceBox(location: place.location, name: place.name)
    }

    /// The menu of a function's name — in the header, in the C: Show
    /// Callers, off when nothing calls it.
    /// `call` is the name's range in the C when the name is a call: then
    /// Jump to Definition, what ⌘-click and a double click on it do, comes
    /// first.
    func functionMenu(for index: Int?, call: NSRange? = nil, name: NSRange? = nil) -> NSMenu? {
        guard let index, model.functions.indices.contains(index) else { return nil }
        let menu = NSMenu()
        menu.autoenablesItems = false
        if let call {
            let jump = menu.addItem(withTitle: L("Jump to Definition"), action: #selector(jumpToDefinitionChosen(_:)),
                                    keyEquivalent: "")
            jump.target = self
            jump.representedObject = CodeCallBox(function: index, range: call)
        }
        let item = menu.addItem(withTitle: L("Show Callers…"), action: #selector(showCallersChosen(_:)),
                                keyEquivalent: "")
        item.target = self
        item.representedObject = name.map { CodeCallBox(function: index, range: $0) } ?? NSNumber(value: index)
        item.isEnabled = !callers(of: index).isEmpty
        return menu
    }

    /// The C's right-click menu, the pane's own and never the text view's:
    /// a function's on a function's name; on a global, a string or a GUID
    /// Show in Dump; on any other name or a constant Copy Name or Copy Value;
    /// Copy on a selection. Nil where there is nothing to offer, and then no
    /// menu opens.
    // help: panel.code.c-menu
    func cMenu(at character: Int?) -> NSMenu? {
        let token = character.flatMap { index in
            shownCTokens.filter { $0.start <= index && index < $0.start + $0.length }
                .min { $0.length < $1.length }
        }
        if let token, case .function(let index)? = token.link {
            let range = NSRange(location: token.start, length: token.length)
            return functionMenu(for: index, call: range == signatureName()?.range ? nil : range, name: range)
        }
        let menu = NSMenu()
        menu.autoenablesItems = false
        if let token {
            if case .bytes? = token.link, let link = token.link {
                let show = menu.addItem(withTitle: L("Show in Dump"), action: #selector(showInDumpChosen(_:)),
                                        keyEquivalent: "")
                show.target = self
                show.representedObject = CodeLinkBox(link)
            }
            let text = (cTextView.string as NSString).substring(with: NSRange(location: token.start, length: token.length))
            let named: Set<CodeToken.Kind> = [.global, .label, .parameter, .local, .pcode, .bytes]
            if named.contains(token.kind) || token.link != nil {
                let copy = menu.addItem(withTitle: L("Copy Name"), action: #selector(copyNameChosen(_:)), keyEquivalent: "")
                copy.target = self
                copy.representedObject = text
            } else if token.kind == .constant {
                let copy = menu.addItem(withTitle: L("Copy Value"), action: #selector(copyNameChosen(_:)), keyEquivalent: "")
                copy.target = self
                copy.representedObject = text
            }
        }
        if cTextView.selectedRange().length > 0 {
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            menu.addItem(withTitle: L("Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "")
                .target = cTextView
        }
        return menu.items.isEmpty ? nil : menu
    }

    @objc private func showInDumpChosen(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? CodeLinkBox else { return }
        follow(box.link)
    }

    @objc private func callWaysChosen(_ sender: NSMenuItem) {
        if state.showsOnlyOpenWay {
            setShowsOnlyOpenWay(false)
        } else if let row = (sender.representedObject as? NSNumber)?.intValue {
            showOnlyWay(atRow: row)
        }
    }

    @objc private func jumpToDefinitionChosen(_ sender: NSMenuItem) {
        guard let call = sender.representedObject as? CodeCallBox else { return }
        jumpToDefinition(of: call.function, from: call.range)
    }

    @objc private func showCallersChosen(_ sender: NSMenuItem) {
        if let name = sender.representedObject as? CodeCallBox {
            showCallers(of: name.function, at: name.range)
        } else if let index = (sender.representedObject as? NSNumber)?.intValue {
            showCallers(of: index)
        }
    }

    @objc private func copyNameChosen(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        Self.copyToPasteboard(name)
    }

    @objc private func openNoteChosen(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        onOpenNote?(id)
    }

    @objc private func annotateChosen(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? CodePlaceBox else { return }
        onAnnotate?(box.location, box.name)
    }
}

/// Show in Dump's link: the bytes of the name the menu was opened on.
private final class CodeLinkBox: NSObject {
    let link: CodeLink

    init(_ link: CodeLink) {
        self.link = link
    }
}

/// Jump to Definition's call: the function called, and where in the C.
private final class CodeCallBox: NSObject {
    let function: Int
    let range: NSRange

    init(function: Int, range: NSRange) {
        self.function = function
        self.range = range
    }
}

/// A menu item's place in the code.
private final class CodePlaceBox: NSObject {
    let location: CodeLocation
    let name: String

    init(location: CodeLocation, name: String) {
        self.location = location
        self.name = name
    }
}
