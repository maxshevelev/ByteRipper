import CodeAnalysis
import Foundation
import HelpBook
import Localization
import ToolModuleKit

/// Text a navigator row writes, in parts that each have a tone; the view
/// gives a tone its font and colour (`CodeNavigatorText`), so the words and
/// the order are decided apart from the drawing and read in a test.
struct CodeStyledText: Equatable, Sendable {
    enum Tone: Equatable, Sendable {
        /// The row's own words, in the label colour.
        case plain
        /// What frames them: a label before a value, a format's word, a note.
        case quiet
        /// A place the row opens.
        case link
        /// A GUID or another value read character by character.
        case mono
    }

    var parts: [(text: String, tone: Tone)]

    init(_ parts: [(text: String, tone: Tone)] = []) { self.parts = parts }
    init(_ text: String, _ tone: Tone) { parts = [(text, tone)] }

    /// A label in the quiet tone, then its value.
    static func labelled(_ label: String, _ value: String, _ tone: Tone) -> CodeStyledText {
        CodeStyledText([(label + " ", .quiet), (value, tone)])
    }

    var string: String { parts.map(\.text).joined() }

    static func == (left: CodeStyledText, right: CodeStyledText) -> Bool {
        left.parts.map(\.text) == right.parts.map(\.text) && left.parts.map(\.tone) == right.parts.map(\.tone)
    }
}

/// What the Interfaces tab lists, apart from how it is drawn: the review's
/// three lists — what the module installs, locates and is notified of — with
/// what the review says of each interface, and the dependency expression its
/// firmware file starts it on.
///
/// `CodeInterfacesPanel` draws these rows; the words, their order and where a
/// row leads are decided here.
enum CodeInterfacesOutline {
    /// One of the review's lists, or the dependency expression: a row of the
    /// first level.
    struct Group {
        let title: String
        let symbol: String
        let help: HelpLink
        /// Nil while the review has not answered the list.
        let entries: [Entry]?
        /// The dependency expression's conditions, in place of interfaces.
        let conditions: [Condition]?
    }

    /// One interface of a list.
    struct Entry {
        let interface: ModuleInterfaces.Interface
        /// Grey after the name: reinstalls, handed over, required, optional.
        let marks: [String]
        let details: [Detail]
    }

    /// A condition of the dependency expression — an interface by its name
    /// and GUID — or a group of them, with its conditions a level under it.
    struct Condition {
        let text: CodeStyledText
        var children: [Condition] = []
        /// The GUID of a condition that names an interface.
        var guid: String?
        /// What an interface's row opens to.
        var details: [Detail] = []
    }

    /// What the review says of an interface. A row with an address opens the
    /// code there.
    struct Detail {
        let text: CodeStyledText
        var address: CodeAddress?
    }

    /// The line over the tree.
    static func summary(of interfaces: ModuleInterfaces?) -> String {
        guard let interfaces, interfaces.isComplete else {
            return L("The review has not recorded them all yet")
        }
        let count = [interfaces.installs, interfaces.locates, interfaces.notifies]
            .reduce(0) { $0 + ($1?.count ?? 0) }
        if count == 0 { return L("The module uses no PPI or protocol") }
        return count == 1 ? L("1 interface") : L("%1$@ interfaces", String(count))
    }

    /// The tab's groups. `place` names the code an address is in — the
    /// function, and the offset into it — or nil where the artifact has no
    /// instruction there.
    static func groups(of interfaces: ModuleInterfaces?, dependencies: DependencyOutline? = nil,
                       registry: GuidRegistry = GuidRegistry(),
                       place: (CodeAddress) -> String?) -> [Group] {
        func entries(_ list: [ModuleInterfaces.Interface]?,
                     marks: (ModuleInterfaces.Interface) -> [String]) -> [Entry]? {
            list?.map { Entry(interface: $0, marks: marks($0), details: details(of: $0, place: place)) }
        }
        // The condition the dispatcher starts the module on, from its
        // firmware file: the PPIs or protocols it waits for, by name.
        var depex: [Group] = []
        if let dependencies {
            depex.append(Group(title: L("Dependency expression"), symbol: "flowchart",
                               help: .term(HelpTermID("depex")), entries: nil,
                               conditions: conditions(of: dependencies) { guid in
                                   dependencyDetails(of: guid, registry: registry,
                                                     interfaces: interfaces, place: place)
                               }))
        }
        return depex + [
            Group(title: L("Installs"), symbol: "square.and.arrow.up",
                  help: .term(HelpTermID("module-installs")),
                  entries: entries(interfaces?.installs) { entry in
                      switch entry.method {
                      case .reinstall: [L("reinstalls")]
                      case .handoff: [L("handed over")]
                      default: []
                      }
                  }, conditions: nil),
            Group(title: L("Locates"), symbol: "magnifyingglass",
                  help: .term(HelpTermID("module-locates")),
                  entries: entries(interfaces?.locates) { entry in
                      [entry.required == true ? L("required") : L("optional")]
                  }, conditions: nil),
            Group(title: L("Notified of"), symbol: "bell",
                  help: .term(HelpTermID("module-notified-of")),
                  entries: entries(interfaces?.notifies) { _ in [] }, conditions: nil)
        ]
    }

    /// The rows of a dependency expression: what must all hold, one row
    /// each — the interface's name and its GUID — and a choice as a row of
    /// its own with its alternatives under it.
    static func conditions(of outline: DependencyOutline,
                           details: (String) -> [Detail] = { _ in [] }) -> [Condition] {
        func interface(_ guid: String, _ name: String?, negated: Bool) -> CodeStyledText {
            // NOT and the opcodes are the format's words, as ASM and C are.
            var text = CodeStyledText()
            if negated { text.parts.append(("NOT ", .quiet)) }
            text.parts.append((name ?? guid, .plain))
            return text
        }
        func item(_ condition: DependencyOutline.Condition) -> Condition {
            switch condition {
            case .interface(let guid, let name):
                return Condition(text: interface(guid, name, negated: false), guid: guid, details: details(guid))
            case .not(.interface(let guid, let name)):
                return Condition(text: interface(guid, name, negated: true), guid: guid, details: details(guid))
            case .not(let operand):
                return Condition(text: CodeStyledText("NOT", .quiet), children: [item(operand)])
            case .anyOf(let list):
                return Condition(text: CodeStyledText(L("One of"), .quiet), children: list.map(item))
            case .allOf(let list):
                return Condition(text: CodeStyledText(L("All of"), .quiet), children: list.map(item))
            case .always:
                return Condition(text: CodeStyledText(L("TRUE: the module waits for nothing"), .plain))
            case .never:
                return Condition(text: CodeStyledText(L("FALSE: the module is never started"), .plain))
            }
        }
        var rows: [Condition] = []
        if let prefix = outline.prefix { rows.append(Condition(text: CodeStyledText(prefix, .plain))) }
        if outline.unreadable {
            rows.append(Condition(text: CodeStyledText(L("The expression in the file cannot be read."), .quiet)))
        }
        return rows + outline.conditions.map(item)
    }

    /// The rows under a condition of the dependency expression: what the
    /// GUID is, as the GUID registry holds it, and each place this module's
    /// review recorded it — installed, located or waited for — with its
    /// purpose and the code. One the module never touches is said so: only
    /// the dispatcher reads it.
    static func dependencyDetails(of guid: String, registry: GuidRegistry, interfaces: ModuleInterfaces?,
                                  place: (CodeAddress) -> String?) -> [Detail] {
        let entry = registry.entry(of: guid)
        let kind: String = switch entry?.kind {
        case .ppi: "PPI"
        case .protocol: L("Protocol")
        default: "GUID"
        }
        var rows = [Detail(text: .labelled(kind, guid, .mono))]
        if let note = entry?.note, !note.isEmpty {
            rows.append(Detail(text: CodeStyledText(note, .plain)))
        }
        if let source = entry?.source {
            switch source.kind {
            case .edk2:
                // `MdePkg/MdePkg.dec:512`: the file says where; the line is the registry's.
                let file = source.file.map { $0.replacingOccurrences(of: #":\d+$"#, with: "", options: .regularExpression) }
                if let file { rows.append(Detail(text: .labelled(L("Declared in:"), file, .plain))) }
            case .review:
                rows.append(Detail(text: CodeStyledText(L("Named by a module review"), .quiet)))
            }
        }
        let lists: [(String, [ModuleInterfaces.Interface]?)] = [
            (L("Installs:"), interfaces?.installs), (L("Locates:"), interfaces?.locates),
            (L("Notified of:"), interfaces?.notifies)
        ]
        let canonical = GuidName.canonicalGUID(guid) ?? guid.uppercased()
        var used = false
        for (label, list) in lists {
            for recorded in list ?? [] where (GuidName.canonicalGUID(recorded.guid) ?? recorded.guid.uppercased()) == canonical {
                used = true
                rows.append(Detail(text: .labelled(label, recorded.purpose, .plain)))
                rows.append(Self.place(recorded.address, at: L("At:"), resolve: place))
            }
        }
        if !used {
            let complete = interfaces?.isComplete ?? false
            rows.append(Detail(text: CodeStyledText(
                complete ? L("The module's code does not use it: only the dispatcher checks it.")
                         : L("The review has not recorded whether the module's code uses it."), .quiet)))
        }
        return rows
    }

    /// The rows under an interface: why, when, what it is, and where.
    static func details(of entry: ModuleInterfaces.Interface,
                        place: (CodeAddress) -> String?) -> [Detail] {
        var rows = [Detail(text: CodeStyledText(entry.purpose, .plain))]
        let when = entry.condition == "always" ? L("always") : entry.condition
        rows.append(Detail(text: .labelled(L("When:"), when, .plain)))
        let kind = entry.kind == .ppi ? "PPI" : L("Protocol")
        rows.append(Detail(text: .labelled(kind, entry.guid, .mono)))
        rows.append(Self.place(entry.address, at: L("At:"), resolve: place))
        if let callback = entry.callback {
            rows.append(Self.place(callback, at: L("Callback:"), resolve: place))
        }
        return rows
    }

    /// A row naming an address: the place in the code as a link that opens
    /// it, or the address as the review wrote it where the code has no
    /// instruction there.
    private static func place(_ written: String, at label: String,
                              resolve place: (CodeAddress) -> String?) -> Detail {
        let address = CodeAddress(hex: written)
        guard let address, let name = place(address) else {
            return Detail(text: .labelled(label, written, .plain))
        }
        return Detail(text: .labelled(label, name, .link), address: address)
    }
}
