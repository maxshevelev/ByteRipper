import Cocoa
import AgentKit
import ByteRipperCore
import ToolModuleKit

/// Two documents compared byte by byte (`Design/AGENT_PLAN.md`, stage 8):
/// `diff`, the runs where they differ, read without touching the screen; then
/// `compare` and `reveal_diff`, the same two shown to the person as a pair and
/// walked through difference by difference.
///
/// The comparison is the window's own: `DiffEngine` at the same absolute
/// offsets — never aligned, so data that moved is one long run — and runs
/// merged across matching bytes the way the window's hunks are. Where a run
/// is comes from the tool-modules (`ToolAgentLocator`), the finest one that
/// can say.
@MainActor
final class AgentDiffTools {
    let desk: AgentDesk
    private let modules: () -> [any ToolModule.Type]
    /// Where a snapshot of a document with unsaved edits keeps its copy.
    private let scratch = TemporaryFileStore()
    /// Opens two files as a pair in a new tab. A test opens them in its own
    /// window instead.
    var openPairInNewTab: (URL, URL) -> Void

    nonisolated static let defaultMergeGap: UInt64 = 0x10

    init(desk: AgentDesk, modules: @escaping () -> [any ToolModule.Type]) {
        self.desk = desk
        self.modules = modules
        openPairInNewTab = { [weak desk] first, second in
            desk?.keyTab()?.openFilesInNewTab([first, second])
        }
    }

    nonisolated func tools() -> [AgentTool] { [diffTool, compareTool, revealDiffTool] }

    // MARK: - diff

    private nonisolated var diffTool: AgentTool {
        AgentTool(
            name: "diff",
            title: "Byte differences",
            description: """
                The runs of bytes where `document` and `against` differ, in address order — compared at the \
                same absolute offsets, unsaved edits included, as the window's A/B comparison compares. Never \
                aligned: data that moved shows as one long run, not as a move. Runs closer than `merge_gap` \
                matching bytes are one run; each has `start`, `end` (half-open), `length` and \
                `differing_bytes`, which is less than `length` where matching bytes were merged in. `totals` \
                count the whole range, whatever the page. Only bytes both files hold are compared: when the \
                sizes differ, `tail` says where the longer file's extra bytes are, and they are not counted. \
                With `structure` "auto" each run says `where` it is in `document`: the top-level area \
                (region, volume, ME partition) and the deepest node that covers the run whole — a run across \
                a boundary is placed at the node holding both sides, never split. Ids are those `uefi_node` \
                and `me_tree` take; `where` is empty when nothing covers it. `summary: true` answers the \
                areas instead, those with no differences too. Pages: pass `next` back as `after`; a page \
                asked for after either document changed is refused. Reads only; nothing on screen moves.
                """,
            inputSchema: AgentSchema.object([
                "document": AgentSchema.string("The first document's id from `documents`. Default: the focused one."),
                "against": AgentSchema.string("The id of the document to compare it with, from `documents` or `open_dump`."),
                "offset": AgentSchema.offset("Where the compared range starts, the same in both. Default 0x0."),
                "end": AgentSchema.offset("The first byte after the range. Default: the end of the shorter file."),
                "merge_gap": AgentSchema.integer("At most this many matching bytes between two runs make them one. Default 16; 0 merges nothing."),
                "structure": AgentSchema.choice(["auto", "none"], "Place each run in the firmware's structure, or not. Default auto."),
                "summary": AgentSchema.boolean("Answer the areas of the image with their differences instead of the runs. Default false."),
                "limit": AgentSchema.limit(default: 100, maximum: 1000),
                "after": AgentSchema.string("The `next` of the page before.")
            ], required: ["against"])
        ) { call in
            try await self.diff(call.arguments)
        }
    }

    /// One run of differences: its span after merging and the bytes in it
    /// that differ.
    struct Run: Equatable {
        var range: Range<UInt64>
        var differing: UInt64
    }

    private func diff(_ arguments: AgentArguments) async throws -> AgentAnswer {
        let place = try resolve(arguments.optionalString("document"))
        let other = try resolve(arguments.string("against"))
        guard other.pane !== place.pane else {
            throw AgentToolError("`document` and `against` are the same document, \(place.id).")
        }
        let sizes = (place.pane.fileSize, other.pane.fileSize)
        let common = min(sizes.0, sizes.1)
        let start = try arguments.optionalOffset("offset") ?? 0
        let end = try arguments.optionalOffset("end") ?? common
        guard end <= common else {
            throw AgentToolError("`end` \(hex(end)) is past the end of the shorter document, which is \(hex(common)) bytes long.")
        }
        guard start < end else {
            throw AgentToolError(common == 0 ? "One of the documents is empty; there is nothing to compare."
                                             : "`offset` \(hex(start)) is not below `end` \(hex(end)).")
        }
        let mergeGap = arguments.has("merge_gap") ? UInt64(max(0, min(0x10_0000, try arguments.integer("merge_gap"))))
                                                  : Self.defaultMergeGap
        let structure = try arguments.has("structure") ? arguments.choice("structure", from: ["auto", "none"]) : "auto"
        let summary = try arguments.bool("summary", default: false)
        let limit = try arguments.limit(default: 100, maximum: 1000)

        let host = PaneToolHost(pane: place.pane, owner: place.controller, tools: nil)
        let otherHost = PaneToolHost(pane: other.pane, owner: other.controller, tools: nil)
        var hasher = Hasher()
        hasher.combine(host.contentVersion)
        hasher.combine(otherHost.contentVersion)
        hasher.combine(start)
        hasher.combine(end)
        hasher.combine(mergeGap)
        let fingerprint = String(UInt(bitPattern: hasher.finalize()), radix: 16)
        var first = 0
        if let after = try arguments.optionalString("after") {
            let parts = after.split(separator: ":")
            guard parts.count == 2, let index = Int(parts[0]) else {
                throw AgentToolError("`after` is not a `next` this tool gave.")
            }
            guard parts[1] == Substring(fingerprint) else {
                throw AgentToolError("A document changed since that page, or the range or `merge_gap` did; ask again without `after`.")
            }
            first = index
        }

        let left = try snapshot(place)
        let right = try snapshot(other)
        let blocks = try await Task.detached(priority: .userInitiated) {
            try DiffEngine.blocks(left: left, right: right, in: start..<end)
        }.value
        let runs = Self.runs(blocks.filter { $0.kind == .different }.map(\.range), mergeGap: mergeGap)
        let differing = runs.reduce(0) { $0 + $1.differing }

        var answer: [String: JSONValue] = [
            "range": AgentHostTools.range(start..<end),
            "sizes": ["document": AgentHostTools.hex(sizes.0), "against": AgentHostTools.hex(sizes.1)],
            "totals": ["runs": .count(runs.count), "differing_bytes": .count(Int(differing))]
        ]
        if sizes.0 != sizes.1 {
            let longer = sizes.0 > sizes.1 ? "document" : "against"
            answer["tail"] = ["in": .string(longer), "start": AgentHostTools.hex(common),
                              "end": AgentHostTools.hex(max(sizes.0, sizes.1))]
            answer["truncated_at"] = AgentHostTools.hex(common)
        }

        if summary {
            answer["areas"] = .array(await areas(host, start..<end, runs: runs, blocks: blocks))
        } else {
            let page = Array(runs.dropFirst(first).prefix(limit))
            let places = structure == "auto" ? await locate(host, page.map(\.range)) : page.map { _ in [] }
            answer["runs"] = .array(zip(page, places).map { run, places in
                var members: [String: JSONValue] = [
                    "start": AgentHostTools.hex(run.range.lowerBound),
                    "end": AgentHostTools.hex(run.range.upperBound),
                    "length": AgentHostTools.hex(UInt64(run.range.count)),
                    "differing_bytes": .count(Int(run.differing))
                ]
                if structure == "auto" { members["where"] = .array(places.map(Self.placeJSON)) }
                return .object(members)
            })
            let following = first + page.count
            answer["next"] = following < runs.count ? .string("\(following):\(fingerprint)") : .null
        }
        answer["document"] = .string(place.id)
        answer["against"] = .string(other.id)
        return .json(.object(answer))
    }

    /// The runs of differing ranges in order, merged across at most
    /// `mergeGap` matching bytes, each with the bytes in it that differ.
    nonisolated static func runs(_ differing: [Range<UInt64>], mergeGap: UInt64) -> [Run] {
        var runs: [Run] = []
        for range in differing {
            if var last = runs.last, range.lowerBound - last.range.upperBound <= mergeGap {
                last.range = last.range.lowerBound..<range.upperBound
                last.differing += UInt64(range.count)
                runs[runs.count - 1] = last
            } else {
                runs.append(Run(range: range, differing: UInt64(range.count)))
            }
        }
        return runs
    }

    // MARK: - Structure

    /// The locators, finest first.
    private var locators: [ToolAgentLocator] {
        modules().compactMap { $0.agentLocator }.sorted { $0.precedence > $1.precedence }
    }

    /// Each range placed by the finest locator that can say.
    private func locate(_ host: PaneToolHost, _ ranges: [Range<UInt64>]) async -> [[ToolAgentPlace]] {
        var result = ranges.map { _ -> [ToolAgentPlace] in [] }
        guard !ranges.isEmpty else { return result }
        for locator in locators {
            let open = result.indices.filter { result[$0].isEmpty }
            guard !open.isEmpty else { break }
            let answers = await locator.locate(host, open.map { ranges[$0] })
            for (index, places) in zip(open, answers) { result[index] = places }
        }
        return result
    }

    /// The areas of the image that overlap `range`, each with the bytes and
    /// runs of differences in it — the coarsest locator's areas, with any that
    /// a finer one divides replaced by the finer ones. One area for the whole
    /// range when no locator knows the file.
    private func areas(_ host: PaneToolHost, _ range: Range<UInt64>, runs: [Run], blocks: [DiffBlock]) async -> [JSONValue] {
        var areas: [ToolAgentPlace] = []
        for locator in locators.reversed() {
            let finer = await locator.areas(host).filter { $0.range != nil }
            guard !finer.isEmpty else { continue }
            if areas.isEmpty {
                areas = finer
                continue
            }
            areas = areas.flatMap { area in Self.divided(area, by: finer) }
        }
        if areas.isEmpty {
            areas = [ToolAgentPlace(kind: "file", id: "", name: host.fileName, range: range)]
        }
        let differing = blocks.filter { $0.kind == .different }.map(\.range)
        var attributed: UInt64 = 0
        var result: [JSONValue] = []
        for area in areas {
            guard let bounds = area.range?.clamped(to: range), !bounds.isEmpty else { continue }
            let bytes = differing.reduce(UInt64(0)) { $0 + UInt64($1.clamped(to: bounds).count) }
            attributed += bytes
            var members = Self.placeJSON(area)
            if case .object(var fields) = members {
                fields["start"] = AgentHostTools.hex(bounds.lowerBound)
                fields["end"] = AgentHostTools.hex(bounds.upperBound)
                fields["differing_bytes"] = .count(Int(bytes))
                fields["runs"] = .count(runs.filter { $0.range.overlaps(bounds) }.count)
                members = .object(fields)
            }
            result.append(members)
        }
        let total = differing.reduce(UInt64(0)) { $0 + UInt64($1.count) }
        if total > attributed {
            result.append(["kind": "outside", "name": "Bytes in no area",
                           "differing_bytes": .count(Int(total - attributed))])
        }
        return result
    }

    /// `area` replaced by the finer areas inside it, the stretches between
    /// them kept under `area`'s own name — so a region a finer module divides
    /// still accounts for every byte of it. `area` itself when none is inside.
    nonisolated static func divided(_ area: ToolAgentPlace, by finer: [ToolAgentPlace]) -> [ToolAgentPlace] {
        guard let bounds = area.range else { return [area] }
        let inside = finer.filter { bounds.lowerBound <= $0.range!.lowerBound && $0.range!.upperBound <= bounds.upperBound }
            .sorted { $0.range!.lowerBound < $1.range!.lowerBound }
        guard !inside.isEmpty else { return [area] }
        var result: [ToolAgentPlace] = []
        var cursor = bounds.lowerBound
        for piece in inside where piece.range!.lowerBound >= cursor {
            if piece.range!.lowerBound > cursor {
                var gap = area
                gap.range = cursor..<piece.range!.lowerBound
                result.append(gap)
            }
            result.append(piece)
            cursor = piece.range!.upperBound
        }
        if cursor < bounds.upperBound {
            var gap = area
            gap.range = cursor..<bounds.upperBound
            result.append(gap)
        }
        return result
    }

    nonisolated static func placeJSON(_ place: ToolAgentPlace) -> JSONValue {
        var members: [String: JSONValue] = ["kind": .string(place.kind), "name": .string(place.name)]
        if !place.id.isEmpty { members["id"] = .string(place.id) }
        return .object(members)
    }

    // MARK: - compare

    private nonisolated var compareTool: AgentTool {
        AgentTool(
            name: "compare",
            title: "Show two documents side by side",
            description: """
                Shows `document` and `against` to the person as a pair — A and B side by side, their \
                differences coloured — in the window's own comparison. A pair already on screen is brought \
                forward; a document alone in its tab gets the other beside it; otherwise the two open in a new \
                tab, leaving the person's tabs as they are. Answers the ids of A and B as they are on screen \
                (a background document gets a new one). Then `reveal_diff` walks the differences.
                """,
            inputSchema: AgentSchema.object([
                "document": AgentSchema.string("The document to show as A. Default: the focused one."),
                "against": AgentSchema.string("The document to show beside it, as B.")
            ], required: ["against"]),
            annotations: .view
        ) { call in
            try await self.compare(call.arguments)
        }
    }

    private func compare(_ arguments: AgentArguments) async throws -> AgentAnswer {
        let place = try resolve(arguments.optionalString("document"))
        let other = try resolve(arguments.string("against"))
        guard other.pane !== place.pane else {
            throw AgentToolError("`document` and `against` are the same document, \(place.id).")
        }
        if let pair = pair(of: place.pane, other.pane) {
            return .json(shown(pair, was: true))
        }
        let firstURL = try url(of: place)
        let secondURL = try url(of: other)
        if let controller = place.controller, place.slot == "A", !controller.windowModel.pane2.isOpen {
            try reopenable(other)
            desk.bringForward(place)
            controller.openFiles([secondURL], placement: .otherPane)
            controller.apply(mode: .comparison)
        } else {
            try reopenable(place)
            try reopenable(other)
            openPairInNewTab(firstURL, secondURL)
        }
        guard let pair = pair(of: firstURL, secondURL) else {
            throw AgentToolError("ByteRipper could not put \(firstURL.lastPathComponent) and "
                + "\(secondURL.lastPathComponent) side by side.")
        }
        desk.bringForward(pair.a)
        // A background copy gives way to the tab, as with `show`.
        for shownNow in [place, other] where !shownNow.isOnScreen {
            desk.background.close(shownNow.pane)
        }
        return .json(shown(pair, was: false))
    }

    private struct Pair {
        var a: AgentDesk.Place
        var b: AgentDesk.Place
    }

    private func shown(_ pair: Pair, was: Bool) -> JSONValue {
        ["a": .string(pair.a.id), "b": .string(pair.b.id), "was_shown": .bool(was),
         "names": [.string(pair.a.pane.status.fileName), .string(pair.b.pane.status.fileName)]]
    }

    /// The tab showing these two panes as its A and B, either way round.
    private func pair(of first: PaneViewModel, _ second: PaneViewModel) -> Pair? {
        let places = desk.places().filter { $0.slot == "A" || $0.slot == "B" }
        for a in places where a.slot == "A" {
            guard let b = places.first(where: { $0.slot == "B" && $0.controller === a.controller }),
                  a.controller?.mode == .comparison else { continue }
            if (a.pane === first && b.pane === second) || (a.pane === second && b.pane === first) {
                return Pair(a: a, b: b)
            }
        }
        return nil
    }

    /// The tab showing these two files as its A and B, in this order.
    private func pair(of first: URL, _ second: URL) -> Pair? {
        let one = FileIdentity(url: first), two = FileIdentity(url: second)
        let places = desk.places()
        for a in places where a.slot == "A" && a.pane.document?.identity == one {
            if let b = places.first(where: { $0.slot == "B" && $0.controller === a.controller
                                             && $0.pane.document?.identity == two }) {
                return Pair(a: a, b: b)
            }
        }
        return nil
    }

    private func url(of place: AgentDesk.Place) throws -> URL {
        guard !place.pane.isUntitled, let url = place.pane.document?.url else {
            throw AgentToolError("\(place.id) has never been saved; only a file on disk can be opened beside another.")
        }
        return url
    }

    /// A document opened again from disk shows the saved bytes: refused for
    /// one whose tab holds unsaved edits.
    private func reopenable(_ place: AgentDesk.Place) throws {
        guard place.isOnScreen, place.pane.status.isDirty else { return }
        throw AgentToolError("\(place.id) has unsaved edits, which a second copy opened from disk would not show. "
            + "Ask the person to save it, or to put the other file beside it.")
    }

    // MARK: - reveal_diff

    private nonisolated var revealDiffTool: AgentTool {
        AgentTool(
            name: "reveal_diff",
            title: "Show the next difference",
            description: """
                Moves both panes of a pair `compare` showed to the next or previous difference — the step \
                the window's own difference arrows take, with the person's grouping of nearby differences — \
                from `from`, or from the caret. A step of the navigation history, so the person's Back \
                returns. Answers the difference, or `found: false` at the end. `document` is either side of \
                the pair.
                """,
            inputSchema: AgentSchema.object([
                "document": AgentSchema.string("A or B of the pair. Default: the focused one."),
                "direction": AgentSchema.choice(["next", "previous"], "Which way. Default next."),
                "from": AgentSchema.offset("Where to look from. Default: the caret.")
            ]),
            annotations: .view
        ) { call in
            try await self.revealDiff(call.arguments)
        }
    }

    private func revealDiff(_ arguments: AgentArguments) async throws -> AgentAnswer {
        let place = try resolve(arguments.optionalString("document"))
        let direction = try arguments.has("direction") ? arguments.choice("direction", from: ["next", "previous"]) : "next"
        let from = try arguments.optionalOffset("from")
        let controller = try place.onScreen()
        guard place.slot == "A" || place.slot == "B", controller.mode == .comparison,
              controller.windowModel.pane1.isOpen, controller.windowModel.pane2.isOpen else {
            throw AgentToolError("\(place.id) is not one of a pair shown side by side. `compare` shows it beside another.")
        }
        desk.bringForward(place)
        guard let range = await controller.revealDifferenceForAgent(
            direction: direction == "next" ? .forward : .backward, from: from)
        else {
            return .json(["document": .string(place.id), "found": false])
        }
        var answer = AgentHostTools.range(range)
        if case .object(var members) = answer {
            members["document"] = .string(place.id)
            members["found"] = true
            answer = .object(members)
        }
        return .json(answer)
    }

    // MARK: - Helpers

    /// The document's bytes as they are now, frozen, to compare off the main
    /// actor.
    private func snapshot(_ place: AgentDesk.Place) throws -> any ByteStorage {
        guard let overlay = place.pane.document?.storage as? EditOverlayStorage else {
            throw AgentToolError("\(place.id) could not be read.")
        }
        return try overlay.contentSnapshot(scratch: scratch)
    }

    private func resolve(_ id: String?) throws -> AgentDesk.Place {
        do {
            return try desk.place(named: id)
        } catch let error as AgentDeskError {
            throw AgentToolError(error.description)
        }
    }

    private nonisolated func hex(_ value: UInt64) -> String { AgentHostTools.hexText(value) }
}
