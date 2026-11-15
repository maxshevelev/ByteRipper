import AgentKit
import Foundation

/// What the tools answer an agent by default: what it has not already got.
/// A review reads thousands of answers, and each repeated what the call
/// named (the module, its project and program), the plate the C already
/// opens with, a `references: []` on every instruction, and every settled
/// proposal with its whole reason. Every tool takes `verbose: true` for the
/// answer as the owner gives it; the owner's own HTTP answers, which the app
/// reads, are not touched.
extension GhidraTools {
    /// The owner's identity on every answer: what the call itself named.
    static let identityKeys = ["module", "project", "program", "language", "image_base"]
    /// The tools whose answer is where a client learns the program's language.
    static let languageTools: Set<String> = ["ghidra_open", "ghidra_create"]
    /// Proposal states nobody votes on any more.
    static let settledProposalStates: Set<String> = ["applied", "withdrawn", "rejected"]

    /// `tool` taking `verbose`, and answering compactly without it.
    static func compacted(_ tool: AgentTool) -> AgentTool {
        guard var schema = tool.inputSchema.objectValue, var properties = schema["properties"]?.objectValue,
              properties["verbose"] == nil else { return tool }
        properties["verbose"] = AgentSchema.boolean(
            "The answer in full, as the server holds it: the identity of the module on every answer, and what "
            + "the compact answer leaves out.")
        schema["properties"] = .object(properties)
        let run = tool.run
        let name = tool.name
        return AgentTool(name: tool.name, title: tool.title,
                         description: tool.description + compactNote(name),
                         inputSchema: .object(schema), annotations: tool.annotations) { call in
            var values = call.arguments.values
            let verbose = values.removeValue(forKey: "verbose")?.boolValue ?? false
            var arguments = call.arguments
            arguments = AgentArguments(values, answerBound: arguments.answerBound)
            let answer = try await run(AgentCall(tool: call.tool, arguments: arguments, progress: call.progress))
            guard !verbose, case .json(let value) = answer else { return answer }
            return .json(compact(value, tool: name, arguments: values))
        }
    }

    /// What a tool's description says of its compact answer.
    static func compactNote(_ tool: String) -> String {
        var note = " Without `verbose`, the answer leaves out the module's identity (module, project, program"
        note += languageTools.contains(tool) ? ")" : ", language, image base)"
        switch tool {
        case "ghidra_type_proposals":
            note += "; without `state` or `id` it lists only the live proposals (open, agreed), and a settled one "
                + "(applied, withdrawn, rejected) comes as `id`, `state`, `names`, `author` and `decided`"
        case "ghidra_function":
            note += "; `comments` lists only those the C does not print: the plate is in `plate`, and a comment "
                + "printed in the C is read there"
        case "ghidra_disassembly":
            note += "; an instruction with no references has no `references`, and a reference gives `to` and "
                + "`type`, with `function` only when it is another function"
        default:
            break
        }
        return note + "."
    }

    /// The compact form of one tool's answer.
    static func compact(_ value: JSONValue, tool: String, arguments: [String: JSONValue]) -> JSONValue {
        var value = value
        switch tool {
        case "ghidra_type_proposals":
            value = compactProposals(value, listAll: arguments["state"] != nil || arguments["id"] != nil)
        case "ghidra_function":
            value = compactFunction(value)
        case "ghidra_disassembly":
            value = compactDisassembly(value)
        default:
            break
        }
        return withoutIdentity(value, keepLanguage: languageTools.contains(tool))
    }

    /// An owner's answer without its identity: only an object that carries
    /// it (`project` and `program` beside each other), so a `module` that
    /// means something else — the module a proposal is from — stays.
    static func withoutIdentity(_ value: JSONValue, keepLanguage: Bool) -> JSONValue {
        guard var object = value.objectValue, object["project"] != nil, object["program"] != nil else { return value }
        for key in identityKeys where !(keepLanguage && key == "language") { object[key] = nil }
        return .object(object)
    }

    /// The live proposals in full; a settled one as what it was and how it
    /// ended. Without a `state` or an `id`, only the live ones.
    static func compactProposals(_ value: JSONValue, listAll: Bool) -> JSONValue {
        func rows(_ list: [JSONValue]) -> [JSONValue] {
            list.compactMap { row -> JSONValue? in
                guard let object = row.objectValue, let state = object["state"]?.stringValue,
                      settledProposalStates.contains(state) else { return row }
                guard listAll else { return nil }
                return .object(object.filter { ["id", "state", "names", "author", "decided"].contains($0.key) })
            }
        }
        if let list = value.arrayValue { return .array(rows(list)) }
        if var object = value.objectValue, let list = object["proposals"]?.arrayValue {
            object["proposals"] = .array(rows(list))
            return .object(object)
        }
        return value
    }

    /// The function without the comments its C already prints.
    static func compactFunction(_ value: JSONValue) -> JSONValue {
        guard var object = value.objectValue, let comments = object["comments"]?.arrayValue else { return value }
        let c = object["c"]?.stringValue.map(squeezed)
        let kept = comments.filter { row in
            guard let comment = row.objectValue else { return true }
            if comment["kind"]?.stringValue == "plate", object["plate"] != nil { return false }
            guard let c, let text = comment["text"]?.stringValue else { return true }
            let words = squeezed(text)
            return words.isEmpty || !c.contains(words)
        }
        object["comments"] = kept.isEmpty ? nil : .array(kept)
        return .object(object)
    }

    /// Text as the C prints a comment, whatever its line breaks: the
    /// decompiler wraps a long comment and indents the rest, so the words are
    /// compared without the spaces and the comment marks.
    static func squeezed(_ text: String) -> String {
        String(text.replacingOccurrences(of: "/*", with: "").replacingOccurrences(of: "*/", with: "")
            .unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }.map(Character.init))
    }

    /// The instructions without what each reference repeats of its row.
    static func compactDisassembly(_ value: JSONValue) -> JSONValue {
        guard var object = value.objectValue, let rows = object["instructions"]?.arrayValue else { return value }
        let function = object["entry"]?.stringValue
        object["instructions"] = .array(rows.map { row in
            guard var instruction = row.objectValue, let references = instruction["references"]?.arrayValue else {
                return row
            }
            if references.isEmpty {
                instruction["references"] = nil
                return .object(instruction)
            }
            let address = instruction["address"]?.stringValue
            instruction["references"] = .array(references.map { reference in
                guard var reference = reference.objectValue else { return reference }
                if let from = reference["from"]?.stringValue, from == address { reference["from"] = nil }
                if let owner = reference["function"]?.stringValue, owner == function { reference["function"] = nil }
                return .object(reference)
            })
            return .object(instruction)
        })
        return .object(object)
    }
}
