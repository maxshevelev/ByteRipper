import AgentKit
import FITTool
import Foundation
import Localization
import ToolModuleKit

/// The catalogue half of the agent's microcode tools: what
/// `github.com/platomav/CPUMicrocodes` offers, and the bytes of the file an
/// agent picked, from the panel's own source (`FITToolSession.microcodeSource`,
/// its listing cached on disk). The changes themselves are `FITAgentMicrocode`'s.
@MainActor
enum FITAgentCatalogueTools {
    nonisolated static var queries: [ToolAgentQuery] { [catalogue] }
    nonisolated static var edits: [ToolAgentEdit] { [add, replace, remove] }

    // MARK: - microcode_catalogue

    nonisolated static let catalogue = ToolAgentQuery(
        name: "microcode_catalogue",
        title: "Microcode catalogue",
        description: """
            The Intel microcode the online collection at github.com/platomav/CPUMicrocodes holds — the \
            catalogue the FIT panel's Add Microcode lists — read from the file names, so nothing is \
            downloaded. Each file: `path` (pass it to `fit_add_microcode` or `fit_replace_microcode`), \
            CPUID, platform mask, revision, date, `production` (false for a pre-release), size. One update \
            with an extended signature table is filed once under each processor it serves. With \
            `in_image`, only files for processors the image's FIT microcodes serve — their extended \
            tables' included — and `installed` says each microcode row's processors and platforms, its \
            revision and how it stands against the catalogue (`latest`, `outdated` with the newest \
            revision, `undecided` where a newer file's platform mask only partly meets the installed \
            one's, so the board's own platform decides, `not_rated`); a file then says which rows it \
            `serves_rows` and whether it is `newer_than_installed`. `cpuid` narrows by the CPUID's \
            first digits. Pages: `limit` is a ceiling — a page also stops before the answer passes the \
            size bound and says `truncated: "size"`; pass `next` back as `after` until it is null.
            """,
        properties: [
            "cpuid": AgentSchema.string("Only files whose CPUID starts with this, e.g. \"906E\"."),
            "in_image": AgentSchema.boolean("Only files for processors the image's microcodes serve, and how each row stands. Default false."),
            "production_only": AgentSchema.boolean("Leave out pre-release files. Default false."),
            "latest_only": AgentSchema.boolean("Only the newest revision for each CPUID and platform mask. Default false."),
            "limit": AgentSchema.limit(default: 50, maximum: 300),
            "after": AgentSchema.after
        ]
    ) { host, arguments in
        try await FITAgentMicrocode.catalogue(listing(), for: host, arguments)
    }

    // MARK: - The changes

    nonisolated static let add = ToolAgentEdit(
        name: "fit_add_microcode",
        title: "Add a microcode",
        description: """
            Downloads a catalogue file (`path` from `microcode_catalogue`) and adds it to the FIT, as the \
            panel's Add Microcode does, as one undo step: where a row's update already serves the same \
            processor — its extended signature table counted — the new one takes that row's place \
            (`change`: "replaced", with what it `replaced`), otherwise it gets a row of its own \
            ("added"). Refused, with the reason, when the very same update is already in the table under \
            another of its CPUIDs, when the file is not a microcode or its checksum is wrong, when the \
            table or the run cannot grow, inside a Boot Guard IBB, when a Top Swap backup differs, and \
            without the person's permission to edit. Says where the component went, how many \
            microcodes behind it `moved`, the `top_swap_backup` it was made in too, and what it means \
            for the `protected_ranges`.
            """,
        properties: ["path": AgentSchema.string("A file's `path` from `microcode_catalogue`.")],
        required: ["path"],
        undoName: L("Add Microcode")
    ) { host, arguments in
        let component = try await download(arguments.string("path"))
        return try await FITAgentMicrocode.add(component, to: host)
    }

    nonisolated static let replace = ToolAgentEdit(
        name: "fit_replace_microcode",
        title: "Replace a microcode",
        description: """
            Downloads a catalogue file (`path` from `microcode_catalogue`) and puts it in the place of row \
            `entry`'s microcode, as the panel's Replace Microcode does, as one undo step — whatever the \
            new update's CPUID. Refused when the same update is already in the table, and when the new \
            one serves a processor, on a shared platform, that another row's update already serves — \
            extended signature tables counted — since the table would then hold two microcodes for one \
            processor: that row is the one to replace. Refused too for the reasons `fit_add_microcode` \
            gives. Says as it does what changed.
            """,
        properties: [
            "entry": AgentSchema.integer("The microcode row's place in the table, from `fit_table`."),
            "path": AgentSchema.string("A file's `path` from `microcode_catalogue`.")
        ],
        required: ["entry", "path"],
        undoName: L("Replace Microcode")
    ) { host, arguments in
        let entry = Int(try arguments.integer("entry"))
        let component = try await download(arguments.string("path"))
        return try await FITAgentMicrocode.replace(entry, with: component, in: host)
    }

    nonisolated static let remove = ToolAgentEdit(
        name: "fit_remove_microcode",
        title: "Remove a microcode",
        description: """
            Takes row `entry` and its microcode out of the FIT, as the panel's Remove Microcode does, as \
            one undo step: the components behind it move up into the space and the rows follow them, \
            and the bytes freed at the end of the run are erased. Refused for the table's last \
            microcode, inside a Boot Guard IBB, when a Top Swap backup differs, and without the person's \
            permission to edit. Says how many `moved` and what was `erased`.
            """,
        properties: ["entry": AgentSchema.integer("The microcode row's place in the table, from `fit_table`.")],
        required: ["entry"],
        undoName: L("Remove Microcode")
    ) { host, arguments in
        try await FITAgentMicrocode.remove(Int(try arguments.integer("entry")), from: host)
    }

    // MARK: - The source

    private static func listing() async throws -> [MicrocodeCatalogueEntry] {
        do {
            return try await FITToolSession.microcodeSource.catalogue()
        } catch {
            throw AgentToolError("The catalogue could not be read: \(error.localizedDescription)")
        }
    }

    /// The file's bytes, once the path is one the catalogue lists for Intel —
    /// the only vendor a FIT names.
    private static func download(_ path: String) async throws -> [UInt8] {
        guard let entry = try await listing().first(where: { $0.path == path }) else {
            throw AgentToolError("No file \(path) in the catalogue; `microcode_catalogue` lists them.")
        }
        guard entry.vendor == .intel else {
            throw AgentToolError("\(path) is \(entry.vendor.rawValue) microcode; a FIT names only Intel's.")
        }
        do {
            return try await FITToolSession.microcodeSource.download(entry)
        } catch {
            throw AgentToolError("\(entry.fileName) could not be downloaded: \(error.localizedDescription)")
        }
    }
}
