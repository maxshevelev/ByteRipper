import Cocoa
import AgentKit
import ByteRipperCore

/// Work across many dumps (`Design/AGENT_PLAN.md`, "Background documents and
/// surveys"): opening a file by path with no window, asking one question of a
/// folder of them, putting one on screen, and leaving findings the person can
/// check by clicking.
@MainActor
final class AgentDumpTools {
    let desk: AgentDesk
    /// The server's tools by name, for `survey` to call. Set by the service
    /// once the list is built.
    var toolNamed: (String) -> AgentTool? = { _ in nil }
    /// Opens a file in a tab of its own. The app's is the key tab's "open in
    /// new tab"; a test hands its own.
    var openInNewTab: (URL) -> Void
    /// Told when the findings change, for the Agent window.
    var onChange: () -> Void = {}

    private(set) var findings: [AgentFinding] = []
    private var nextFinding = 1

    nonisolated static let maxSurveyFiles = 200
    nonisolated static let dumpExtensions: Set<String> = ["bin", "rom", "fd", "cap", "dump", "img", "scap"]

    init(desk: AgentDesk) {
        self.desk = desk
        openInNewTab = { [weak desk] url in
            guard let controller = desk?.keyTab() else { return }
            controller.openFilesInNewTab([url])
        }
    }

    nonisolated func tools() -> [AgentTool] {
        [openDumpTool, closeDumpTool, showTool, surveyTool, findingTool, findingsTool]
    }

    // MARK: - open_dump / close_dump

    private nonisolated var openDumpTool: AgentTool {
        AgentTool(
            name: "open_dump",
            title: "Open a dump in the background",
            description: """
                Opens a file by path without putting it on screen, read-only, and returns its document id — \
                for the tools that take `document` (`read`, `uefi_tree`, `uefi_find`…), but not for the ones \
                that show things (`reveal`, `mark`, panels); `show` puts it on screen. A file already open in a \
                tab answers with that tab's id. The last eight are kept parsed; older ones are closed and opened \
                again when asked for. A file changed on disk is read again and keeps its id.
                """,
            inputSchema: AgentSchema.object([
                "path": AgentSchema.string("An absolute path, or one starting with ~/.")
            ], required: ["path"]),
            annotations: AgentTool.Annotations(readOnly: true, idempotent: true)
        ) { call in
            try await self.openDump(call.arguments)
        }
    }

    private func openDump(_ arguments: AgentArguments) async throws -> AgentAnswer {
        let url = try Self.fileURL(try arguments.string("path"))
        try await Self.probe(url)
        if let place = desk.onScreenPlace(of: url) {
            return .json(["document": .string(place.id), "on_screen": true, "size": AgentHostTools.hex(place.pane.fileSize)])
        }
        let entry = try openBackground(url)
        return .json(["document": .string(desk.id(of: entry)), "on_screen": false,
                      "size": AgentHostTools.hex(entry.pane.fileSize)])
    }

    private func openBackground(_ url: URL) throws -> AgentBackgroundDocuments.Entry {
        do {
            return try desk.background.open(url)
        } catch {
            throw AgentToolError("Could not open \(url.path): \(error.localizedDescription)")
        }
    }

    private nonisolated var closeDumpTool: AgentTool {
        AgentTool(
            name: "close_dump",
            title: "Close a background dump",
            description: "Closes a document `open_dump` opened. Files open in a tab are the person's and are not closed.",
            inputSchema: AgentSchema.object([
                "document": AgentSchema.string("The background document's id.")
            ], required: ["document"]),
            annotations: AgentTool.Annotations(readOnly: false, idempotent: true)
        ) { call in
            try await self.closeDump(call.arguments)
        }
    }

    private func closeDump(_ arguments: AgentArguments) async throws -> AgentAnswer {
        let place = try resolve(arguments.string("document"))
        guard !place.isOnScreen else {
            throw AgentToolError("\(place.id) is open in a tab; only the person closes it.")
        }
        desk.background.close(place.pane)
        return .json(["closed": .string(place.id)])
    }

    // MARK: - show

    private nonisolated var showTool: AgentTool {
        AgentTool(
            name: "show",
            title: "Put a dump on screen",
            description: """
                Opens a background document in a new tab — or brings forward the tab that already has the \
                file — and shows `offset` there, selecting `length` bytes when given. Returns the on-screen \
                document's id, which replaces the background one. Never opens into a pane that holds a file.
                """,
            inputSchema: AgentSchema.object([
                "document": AgentSchema.string("The document's id."),
                "offset": AgentSchema.offset("Where to show. Default: the start."),
                "length": AgentSchema.offset("How many bytes to select. Default 0.")
            ], required: ["document"]),
            annotations: .view
        ) { call in
            try await self.show(call.arguments)
        }
    }

    private func show(_ arguments: AgentArguments) async throws -> AgentAnswer {
        let place = try resolve(arguments.string("document"))
        let offset = try arguments.optionalOffset("offset") ?? 0
        let length = try arguments.optionalOffset("length") ?? 0
        let onScreen: AgentDesk.Place
        var replaced: String?
        if place.isOnScreen {
            onScreen = place
        } else {
            guard let url = place.pane.document?.url else { throw AgentToolError("\(place.id) has no file.") }
            if let existing = desk.onScreenPlace(of: url) {
                onScreen = existing
            } else {
                openInNewTab(url)
                guard let opened = desk.onScreenPlace(of: url) else {
                    throw AgentToolError("ByteRipper could not open \(url.lastPathComponent) in a tab.")
                }
                onScreen = opened
            }
            replaced = place.id
            desk.background.close(place.pane)
        }
        let size = onScreen.pane.fileSize
        guard offset <= size else {
            throw AgentToolError("Offset \(AgentHostTools.hexText(offset)) is past the end of \(onScreen.id).")
        }
        let end = min(offset + length, size)
        let controller = try onScreen.onScreen()
        desk.bringForward(onScreen)
        controller.recordJump(in: onScreen.pane)
        controller.revealForTool(offset..<end, in: onScreen.pane, select: end > offset)
        var answer: [String: JSONValue] = ["document": .string(onScreen.id), "shown": AgentHostTools.range(offset..<end)]
        if let replaced { answer["replaces"] = .string(replaced) }
        return .json(.object(answer))
    }

    // MARK: - survey

    private nonisolated var surveyTool: AgentTool {
        AgentTool(
            name: "survey",
            title: "Ask one question of many dumps",
            description: """
                Runs one tool that takes `document` (`uefi_find`, `uefi_node`, `uefi_at`, `read`…) on every \
                file in `folder` (or in `paths`), opening each in the background, and returns the answers \
                grouped by the value at `group_by` — a dotted path into the tool's answer, e.g. "total", \
                "matches.0.start", "values.0", "chain.-1.name" (a negative index counts from the end). Each \
                group: the value, how many files gave it, and up to ten of their names. Files a tool refused \
                are listed under `failed`. Takes a while on many large images; reports progress. At most \
                \(Self.maxSurveyFiles) files.
                """,
            inputSchema: AgentSchema.object([
                "folder": AgentSchema.string("A folder of dumps: files ending in .bin, .rom, .fd, .cap, .dump, .img, .scap."),
                "recursive": AgentSchema.boolean("Look in subfolders too. Default false."),
                "paths": AgentSchema.strings("Files to survey, instead of a folder."),
                "tool": AgentSchema.string("The tool to run on each file."),
                "arguments": ["type": "object", "description": "The tool's arguments, without `document`."],
                "group_by": AgentSchema.string("Where in the answer the value to group by is. Default: the whole answer."),
                "limit": AgentSchema.limit(default: 20, maximum: 100)
            ], required: ["tool"]),
            annotations: .readOnly
        ) { call in
            try await self.survey(call)
        }
    }

    private func survey(_ call: AgentCall) async throws -> AgentAnswer {
        let arguments = call.arguments
        let toolName = try arguments.string("tool")
        guard let tool = toolNamed(toolName),
              tool.inputSchema["properties"]?["document"] != nil, toolName != "survey" else {
            throw AgentToolError("`\(toolName)` is not a tool that answers about one document.")
        }
        var toolArguments = arguments["arguments"]?.objectValue ?? [:]
        if arguments["arguments"] != nil, arguments["arguments"]?.objectValue == nil {
            throw AgentToolError("Argument `arguments` must be an object.")
        }
        let path = try arguments.optionalString("group_by").map(Self.parsePath)
        let limit = try arguments.limit(default: 20, maximum: 100)
        let files = try await surveyFiles(arguments)
        guard !files.isEmpty else { throw AgentToolError("No dump files to survey there.") }

        var groups: [String: (value: JSONValue, files: [String])] = [:]
        var failed: [JSONValue] = []
        for (index, url) in files.enumerated() {
            try Task.checkCancellation()
            await call.progress(Double(index), Double(files.count), url.lastPathComponent)
            let name = url.lastPathComponent
            do {
                let document: String
                if let place = desk.onScreenPlace(of: url) {
                    document = place.id
                } else {
                    try await Self.probe(url)
                    document = desk.id(of: try openBackground(url))
                }
                toolArguments["document"] = .string(document)
                let answer = try await tool.run(AgentCall(tool: toolName, arguments: AgentArguments(toolArguments)))
                let whole: JSONValue
                switch answer {
                case .json(let value): whole = value
                case .text(let text): whole = .string(text)
                }
                let value = path.map { Self.value(at: $0, in: whole) ?? .null } ?? whole
                let key = value.jsonText
                groups[key, default: (value, [])].files.append(name)
            } catch let error as AgentToolError {
                if failed.count < 20 { failed.append(["file": .string(name), "error": .string(error.message)]) }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if failed.count < 20 { failed.append(["file": .string(name), "error": .string("\(error)")]) }
            }
        }
        await call.progress(Double(files.count), Double(files.count), nil)

        let sorted = groups.values.sorted { $0.files.count > $1.files.count }
        var answer: [String: JSONValue] = [
            "files": .count(files.count),
            "groups": .array(sorted.prefix(limit).map { group in
                ["value": group.value, "count": .count(group.files.count),
                 "files": .array(group.files.prefix(10).map { .string($0) })]
            })
        ]
        if sorted.count > limit { answer["more_groups"] = .count(sorted.count - limit) }
        if !failed.isEmpty { answer["failed"] = .array(failed) }
        return .json(.object(answer))
    }

    private func surveyFiles(_ arguments: AgentArguments) async throws -> [URL] {
        var urls: [URL] = []
        let paths = try arguments.strings("paths")
        if !paths.isEmpty {
            urls = try paths.map(Self.fileURL)
        } else if let folder = try arguments.optionalString("folder") {
            let root = try Self.fileURL(folder)
            let recursive = try arguments.bool("recursive", default: false)
            // Off the main actor: the first listing of a folder macOS guards
            // (Desktop, Documents, Downloads) waits in the kernel until the
            // person answers the system's question about access — and on the
            // main thread that wait is the whole app frozen.
            urls = await Task.detached(priority: .userInitiated) {
                Self.dumpFiles(in: root, recursive: recursive)
            }.value
        } else {
            throw AgentToolError("Give a `folder` or a list of `paths`.")
        }
        guard urls.count <= Self.maxSurveyFiles else {
            throw AgentToolError("\(urls.count) files; at most \(Self.maxSurveyFiles) in one survey. Narrow it with `paths`.")
        }
        return urls
    }

    // MARK: - Findings

    private nonisolated var findingTool: AgentTool {
        AgentTool(
            name: "finding",
            title: "Record a finding",
            description: """
                Records one finding for the person to check: a sentence, and where it is — a document, or a \
                file `path`, with an `offset` and `length` or a UEFI `node`. The Agent window lists findings; a \
                double-click opens the file at that place. Use it for each claim a survey supports, so seven \
                files out of fifty become seven lines the person can click.
                """,
            inputSchema: AgentSchema.object([
                "text": AgentSchema.string("What was found, in a sentence."),
                "document": AgentSchema.string("The document it is in."),
                "path": AgentSchema.string("Or the file it is in, by path."),
                "offset": AgentSchema.offset("Where in the file."),
                "length": AgentSchema.offset("How many bytes. Default 0."),
                "node": AgentSchema.string("Or the UEFI node it is about, e.g. \"0.2.5\".")
            ], required: ["text"]),
            annotations: AgentTool.Annotations(readOnly: false, idempotent: false)
        ) { call in
            try await self.recordFinding(call.arguments)
        }
    }

    private func recordFinding(_ arguments: AgentArguments) async throws -> AgentAnswer {
        let text = try arguments.string("text").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw AgentToolError("Argument `text` must say something.") }
        let url: URL
        if let path = try arguments.optionalString("path") {
            url = try Self.fileURL(path)
        } else {
            let place = try resolve(try arguments.optionalString("document"))
            guard !place.pane.isUntitled, let document = place.pane.document else {
                throw AgentToolError("\(place.id) is not a file on disk, so a finding could not lead back to it.")
            }
            url = document.url
        }
        let offset = try arguments.optionalOffset("offset")
        let length = try arguments.optionalOffset("length") ?? 0
        let finding = AgentFinding(
            id: "f\(nextFinding)", url: url, range: offset.map { $0..<($0 + length) },
            node: try arguments.optionalString("node"), text: text)
        nextFinding += 1
        findings.append(finding)
        onChange()
        return .json(finding.json)
    }

    private nonisolated var findingsTool: AgentTool {
        AgentTool(
            name: "findings",
            title: "List findings",
            description: "The findings recorded so far, oldest first."
        ) { _ in
            await MainActor.run { .json(["findings": .array(self.findings.map(\.json))]) }
        }
    }

    func clearFindings() {
        findings.removeAll()
        onChange()
    }

    /// Opens the finding's file — the tab that has it, or a new one — and
    /// shows its place. What a double-click on its row does.
    func show(_ finding: AgentFinding) {
        let place = desk.onScreenPlace(of: finding.url) ?? {
            openInNewTab(finding.url)
            return desk.onScreenPlace(of: finding.url)
        }()
        guard let place, let controller = place.controller else { return }
        desk.bringForward(place)
        controller.view.window?.makeKeyAndOrderFront(nil)
        guard let range = finding.range, range.lowerBound <= place.pane.fileSize else { return }
        controller.recordJump(in: place.pane)
        let end = min(range.upperBound, place.pane.fileSize)
        controller.revealForTool(range.lowerBound..<end, in: place.pane, select: end > range.lowerBound)
    }

    // MARK: - Helpers

    /// The dump files in `root`, sorted as Finder sorts them.
    nonisolated static func dumpFiles(in root: URL, recursive: Bool) -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey]
        let found: [URL]
        if recursive {
            let walk = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                      options: [.skipsHiddenFiles])
            found = walk?.compactMap { $0 as? URL } ?? []
        } else {
            found = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: keys,
                                                                   options: [.skipsHiddenFiles])) ?? []
        }
        return found.filter { url in
            dumpExtensions.contains(url.pathExtension.lowercased())
                && (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    /// Opens and closes `url` off the main actor before the document reads it
    /// on it, for the same reason the folder is listed off it: a file in a
    /// folder macOS guards waits for the person's answer the first time.
    nonisolated static func probe(_ url: URL) async throws {
        try await Task.detached(priority: .userInitiated) {
            do {
                let handle = try FileHandle(forReadingFrom: url)
                try handle.close()
            } catch {
                throw AgentToolError("Could not read \(url.path): \(error.localizedDescription)")
            }
        }.value
    }

    private func resolve(_ id: String?) throws -> AgentDesk.Place {
        do {
            return try desk.place(named: id)
        } catch let error as AgentDeskError {
            throw AgentToolError(error.description)
        }
    }

    static func fileURL(_ path: String) throws -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { throw AgentToolError("`\(path)` is not an absolute path.") }
        return URL(fileURLWithPath: expanded).standardizedFileURL
    }

    /// `"matches.0.start"` → the steps into an answer; a number is an index,
    /// negative from the end.
    static func parsePath(_ text: String) -> [String] {
        text.split(separator: ".").map(String.init)
    }

    static func value(at path: [String], in value: JSONValue) -> JSONValue? {
        var current = value
        for step in path {
            if let index = Int(step), let items = current.arrayValue {
                let resolved = index < 0 ? items.count + index : index
                guard items.indices.contains(resolved) else { return nil }
                current = items[resolved]
            } else if let next = current[step] {
                current = next
            } else {
                return nil
            }
        }
        return current
    }
}

/// One thing an agent found, and where, for the person to check
/// (`Design/AGENT_PLAN.md`, "findings").
struct AgentFinding: Equatable {
    let id: String
    let url: URL
    let range: Range<UInt64>?
    let node: String?
    let text: String

    var json: JSONValue {
        var entry: [String: JSONValue] = ["id": .string(id), "path": .string(url.path), "text": .string(text)]
        if let range { entry["range"] = AgentHostTools.range(range) }
        if let node { entry["node"] = .string(node) }
        return .object(entry)
    }
}
