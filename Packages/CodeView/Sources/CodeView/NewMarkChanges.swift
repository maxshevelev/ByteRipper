import CodeAnalysis
import Foundation
import Localization

/// What changed in a function between two revisions that the comparison of
/// its C cannot show — what the plate over the code lists for a function
/// marked **New**. A change the C text shows (a rename, in the header; a
/// changed type, in a declaration; a plate or pre comment the decompiler
/// prints) is the comparison's to show and is never listed here.
///
/// The artifact keeps no step comment's text, nor a parameter's or a local's
/// storage: what it does keep is what is compared. An end-of-line or post
/// comment is known only by the review gap it closes or opens (`comments`),
/// so it is said as "added" or "removed", not quoted.
public enum NewMarkChange: Equatable, Sendable {
    /// Neither revision has C for the function: no comparison to draw.
    case noCodeEither
    /// The prototype differs while the C reads the same — or there is no C to
    /// show it.
    case signature(from: String, to: String)
    /// Linked to a library registry entry it was not linked to before.
    case bound(entry: String, name: String)
    /// No longer a link to the registry entry it was.
    case unbound(entry: String, name: String)
    /// Linked to another registry entry than before.
    case rebound(from: String, to: String, name: String)
    /// Linked to another version of the same entry.
    case entryVersion(entry: String, name: String, from: Int, to: Int)
    /// The parameters' storage is set by hand now (`true`) or comes from the
    /// calling convention again (`false`).
    case customStorage(Bool)
    /// Where the name came from: the UEFI pass, the image, a person.
    case nameSource(from: String, to: String)
    /// Why the name was given, in the analysis's words.
    case nameReason(String?)
    /// Why the signature is what it is.
    case signatureReason(String?)
    /// How far the review has got.
    case reviewLevel(from: ReviewLevel?, to: ReviewLevel?)
    /// A step comment (end-of-line or post) the C does not print was added
    /// (`true`) or the last one removed (`false`).
    case stepComments(added: Bool)
    /// A plate comment came or went while the C's comments read the same.
    case plateComment(added: Bool)
    /// A constant of the function was given a name the C does not print.
    case equateAdded(String)
    /// A constant's name the C did not print was taken off.
    case equateRemoved(String)
    /// What a constant's name stands for — its enum or its comment — changed.
    case equateDescribed(String)
    /// A global the body reads has another type.
    case globalType(name: String, from: String, to: String)
    /// Instructions read differently while the C reads the same.
    case listing(Int)
    /// A type the C names has another definition. Module-wide: it does not
    /// put a function up as New by itself.
    case typeDefinition(String)

    /// Whether this change makes the function New by itself. A type's
    /// definition belongs to the module, as the description does: a change
    /// to it would put up every function that names the type.
    /// No C on either side is a fact about both revisions, not a change.
    public var marksNew: Bool {
        switch self {
        case .typeDefinition, .noCodeEither: false
        default: true
        }
    }
}

extension NewMarkChange {
    /// What changed between `old` and `new` that their C does not show.
    /// `equates` and `types` are each revision's module-wide tables, read for
    /// what concerns this function.
    public static func between(old: CodeArtifact.Function, new: CodeArtifact.Function,
                               oldEquates: [CodeArtifact.Equate] = [], newEquates: [CodeArtifact.Equate] = [],
                               oldTypes: [CodeArtifact.TypeDefinition] = [],
                               newTypes: [CodeArtifact.TypeDefinition] = []) -> [NewMarkChange] {
        var changes: [NewMarkChange] = []
        let sameC = old.c == new.c

        // The registry link: never in the C, which reads the entry's text either way.
        // A side read through `LibraryView` names the entry; a raw one only
        // its registry number. The two are compared only like with like.
        let oldEntry = old.libraryEntry?.id ?? old.registryNumber
        let newEntry = new.libraryEntry?.id ?? new.registryNumber
        switch (oldEntry, newEntry) {
        case (nil, let entry?):
            changes.append(.bound(entry: entry, name: new.name))
        case (let entry?, nil):
            changes.append(.unbound(entry: entry, name: old.name))
        case let (from?, to?):
            if let before = old.libraryEntry, let after = new.libraryEntry {
                if before.id != after.id {
                    changes.append(.rebound(from: before.id, to: after.id, name: new.name))
                } else if before.version != after.version {
                    changes.append(.entryVersion(entry: to, name: new.name, from: before.version, to: after.version))
                }
            } else if old.libraryEntry == nil, new.libraryEntry == nil, from != to {
                changes.append(.rebound(from: from, to: to, name: new.name))
            }
        default: break
        }
        // A raw link holds no C of its own: the entry's is read for it.
        if old.c == nil, new.c == nil, oldEntry == nil, newEntry == nil { changes.insert(.noCodeEither, at: 0) }

        // The header shows the prototype; with the same C, or none, it does not.
        if sameC, old.signature != new.signature {
            changes.append(.signature(from: old.signature ?? "", to: new.signature ?? ""))
        }
        if (old.customStorage ?? false) != (new.customStorage ?? false) {
            changes.append(.customStorage(new.customStorage ?? false))
        }

        // A link's name, reason and level are the entry's: the link says them.
        if oldEntry == nil, newEntry == nil {
            if let from = old.nameSource, let to = new.nameSource, from != to {
                changes.append(.nameSource(from: from, to: to))
            }
            if old.nameReason != new.nameReason { changes.append(.nameReason(new.nameReason)) }
            if old.signatureReason != new.signatureReason { changes.append(.signatureReason(new.signatureReason)) }
            if old.reviewLevel != new.reviewLevel {
                changes.append(.reviewLevel(from: old.reviewLevel, to: new.reviewLevel))
            }
            // Comments: the decompiler prints plate and pre comments, not
            // end-of-line or post ones. A gap that closed or opened while the
            // C's own comments read the same is a comment the C does not show.
            let sameComments = comments(in: old.c) == comments(in: new.c)
            let hadSteps = !old.reviewGaps.contains("comments"), hasSteps = !new.reviewGaps.contains("comments")
            if hadSteps != hasSteps, sameComments || old.c == nil || new.c == nil {
                changes.append(.stepComments(added: hasSteps))
            }
            let hadPlate = !old.reviewGaps.contains("plate"), hasPlate = !new.reviewGaps.contains("plate")
            if hadPlate != hasPlate, sameComments {
                changes.append(.plateComment(added: hasPlate))
            }
        }

        // Constants: a name the C prints is the comparison's; what it stands for never is.
        let before = equates(oldEquates, in: old), after = equates(newEquates, in: new)
        for (name, equate) in after.sorted(by: { $0.key < $1.key }) {
            if let previous = before[name] {
                if previous.comment != equate.comment || previous.enumName != equate.enumName {
                    changes.append(.equateDescribed(name))
                }
            } else if !(mentions(new.c, name) && !mentions(old.c, name)) {
                changes.append(.equateAdded(name))
            }
        }
        for name in before.keys.sorted() where after[name] == nil {
            if !(mentions(old.c, name) && !mentions(new.c, name)) { changes.append(.equateRemoved(name)) }
        }

        // The globals the body reads, by offset: their types are not in the C.
        if let oldGlobals = old.globals, let newGlobals = new.globals {
            var byOffset: [String: LibraryGlobal] = [:]
            for global in oldGlobals { byOffset[global.offset] = global }
            for global in newGlobals {
                guard let previous = byOffset[global.offset], previous.type != global.type,
                      let from = previous.type, let to = global.type else { continue }
                changes.append(.globalType(name: global.name ?? global.offset, from: from, to: to))
            }
        }

        // The listing, where the C does not move with it.
        if sameC, !old.codeIsPending, !new.codeIsPending {
            let count = differingInstructions(old.instructions, new.instructions)
            if count > 0 { changes.append(.listing(count)) }
        }

        // The types the C names, by their definitions.
        if let c = new.c {
            var previous: [String: CodeArtifact.TypeDefinition] = [:]
            for type in oldTypes { previous[type.name] = type }
            var said: Set<String> = []
            for type in newTypes where !said.contains(type.name) && mentions(c, type.name) {
                guard let earlier = previous[type.name], mentions(old.c, type.name),
                      earlier.c != type.c || earlier.path != type.path else { continue }
                said.insert(type.name)
                changes.append(.typeDefinition(type.name))
            }
        }
        return changes
    }

    /// The comments the C holds, in order.
    static func comments(in c: String?) -> [String] {
        guard let c else { return [] }
        var found: [String] = []
        var rest = c[...]
        while let open = rest.range(of: "/*") {
            guard let close = rest[open.upperBound...].range(of: "*/") else { break }
            found.append(String(rest[open.lowerBound..<close.upperBound]))
            rest = rest[close.upperBound...]
        }
        for line in c.split(separator: "\n") {
            if let slash = line.range(of: "//") { found.append(String(line[slash.lowerBound...])) }
        }
        return found
    }

    /// Whether `c` holds `name` as a whole word.
    static func mentions(_ c: String?, _ name: String) -> Bool {
        guard let c, !name.isEmpty else { return false }
        var start = c.startIndex
        while let range = c.range(of: name, range: start..<c.endIndex) {
            let before = range.lowerBound == c.startIndex ? nil : c[c.index(before: range.lowerBound)]
            let after = range.upperBound == c.endIndex ? nil : c[range.upperBound]
            func isWord(_ character: Character?) -> Bool {
                guard let character else { return false }
                return character.isLetter || character.isNumber || character == "_"
            }
            if !isWord(before) && !isWord(after) { return true }
            start = range.upperBound
        }
        return false
    }

    /// The equates whose operands lie in the function's instructions, by name.
    private static func equates(_ all: [CodeArtifact.Equate],
                                in function: CodeArtifact.Function) -> [String: CodeArtifact.Equate] {
        let addresses = Set(function.instructions.map(\.address))
        guard !addresses.isEmpty else { return [:] }
        var found: [String: CodeArtifact.Equate] = [:]
        for equate in all where equate.references.contains(where: { addresses.contains($0.address) }) {
            found[equate.name] = equate
        }
        return found
    }

    /// How many instructions one listing has that the other does not have as they are.
    private static func differingInstructions(_ old: [CodeArtifact.Instruction],
                                              _ new: [CodeArtifact.Instruction]) -> Int {
        var before: [CodeAddress: CodeArtifact.Instruction] = [:]
        for instruction in old { before[instruction.address] = instruction }
        var count = 0
        var seen: Set<CodeAddress> = []
        for instruction in new {
            seen.insert(instruction.address)
            if before[instruction.address] != instruction { count += 1 }
        }
        count += old.filter { !seen.contains($0.address) }.count
        return count
    }
}

extension NewMarkChange {
    /// The change in the plate's words.
    // help: panel.code.new
    public var bullet: String {
        switch self {
        case .noCodeEither:
            return L("Neither revision has decompiled code for this function.")
        case let .signature(from, to):
            return L("Signature, which the C does not show: %1$@ → %2$@", from, to)
        case let .bound(entry, name):
            return L("Linked to the library registry entry %1$@ (%2$@).", name, entry)
        case let .unbound(entry, name):
            return L("No longer linked to the library registry entry %1$@ (%2$@).", name, entry)
        case let .rebound(from, to, name):
            return L("Linked to another library registry entry, %1$@: %2$@ → %3$@.", name, from, to)
        case let .entryVersion(entry, name, from, to):
            return L("Linked to another version of the registry entry %1$@ (%2$@): %3$@ → %4$@.",
                     name, entry, String(from), String(to))
        case .customStorage(true):
            return L("Parameter storage is now set by hand, not by the calling convention.")
        case .customStorage(false):
            return L("Parameter storage follows the calling convention again.")
        case let .nameSource(from, to):
            return L("Source of the name: %1$@ → %2$@", Self.sourceName(from), Self.sourceName(to))
        case let .nameReason(reason?):
            return L("Reason for the name: %1$@", reason)
        case .nameReason(nil):
            return L("The reason for the name was removed.")
        case let .signatureReason(reason?):
            return L("Reason for the signature: %1$@", reason)
        case .signatureReason(nil):
            return L("The reason for the signature was removed.")
        case let .reviewLevel(from, to):
            return L("Review: %1$@ → %2$@", Self.levelName(from), Self.levelName(to))
        case .stepComments(added: true):
            return L("Step comments added (end-of-line or post): the C does not print them.")
        case .stepComments(added: false):
            return L("Step comments removed (end-of-line or post): the C does not print them.")
        case .plateComment(added: true):
            return L("A plate comment was added that the C does not print.")
        case .plateComment(added: false):
            return L("A plate comment was removed that the C did not print.")
        case let .equateAdded(name):
            return L("Constant name %1$@ added where the C does not print it.", name)
        case let .equateRemoved(name):
            return L("Constant name %1$@ removed where the C did not print it.", name)
        case let .equateDescribed(name):
            return L("Constant %1$@: its description changed.", name)
        case let .globalType(name, from, to):
            return L("Global %1$@: type %2$@ → %3$@", name, from, to)
        case let .listing(count):
            return L("The listing changed at %1$@ instructions; the C reads the same.", String(count))
        case let .typeDefinition(name):
            return L("Type %1$@: its definition changed.", name)
        }
    }

    static func sourceName(_ source: String) -> String {
        switch source {
        case "DEFAULT": L("placeholder")
        case "ANALYSIS": L("analysis")
        case "IMPORTED": L("the image's symbols")
        case "USER_DEFINED": L("the review")
        default: source
        }
    }

    static func levelName(_ level: ReviewLevel?) -> String {
        switch level {
        case .full: L("fully reviewed")
        case .partial: L("partly reviewed")
        case .decompiled: L("decompiler only")
        case .library: L("library function")
        case .noBody: L("no body")
        case .stub: L("stub")
        case nil: L("review level not recorded")
        }
    }
}
