import AgentKit
import Foundation
import ToolModuleKit
import UEFIImage

/// Where the image keeps the board's identity, for an agent: the stores the
/// UEFI Structure's DMI button goes to (`DMIStore`), each with what the
/// panel's detail says about it. The search is the panel's own, so the agent
/// finds a store exactly where the button would.
///
/// The parser knows a few layouts, each by checks of its own. A dump with
/// none of them found can still hold the board's identity — another vendor's
/// layout, or a known one damaged or moved — and every answer says so, so
/// that "none found" is never read as "none there".
@MainActor
public enum UEFIAgentDMI {
    nonisolated public static var all: [ToolAgentQuery] { [stores] }

    /// What an answer says about what the parser can and cannot find.
    nonisolated static let scope = """
        The parser finds a DMI area only by its algorithms for the dump layouts it knows: Lenovo's \
        DMI store (an LDBG change log and two LENV blocks), AMI's GPNV store as ASUS writes it, and \
        Acer's 8 KiB DMI area. An area that is not found is not therefore absent from the dump: it may \
        be in a layout the parser does not know, or a known one that is damaged, wiped or moved so its \
        checks fail.
        """

    nonisolated static let stores = ToolAgentQuery(
        name: "uefi_dmi",
        title: "DMI area",
        description: """
            The image's DMI areas — where the firmware keeps the board's identity: serial numbers, UUID, \
            model — as the UEFI Structure panel's DMI button finds them. It opens every container in the \
            file, but no compressed section. Each area: `layout` ("Lenovo DMI store", "GPNV store" or "Acer \
            DMI" — the Type column calls them all Padding), its node as `uefi_tree` gives it (`id`, `label`, \
            `link`, `start`, `end`, `encoded` for an XORed LENV block), `size`, `path`, and the panel's \
            `fields` and `tables` for it; `uefi_node` on its children reads further, `uefi_node_data` \
            reads the bytes. \(scope) So an empty `areas` means only that the parser recognised none — \
            say so to the person, never that the dump has no DMI; `region_scan` judges the nameless \
            areas by their bytes, which is where to look next. With `survey`, group a folder of dumps by \
            "total" or "areas.0.layout" — the whole answer holds each board's own serials, so no two dumps \
            would share a group.
            """,
        properties: [:]
    ) { host, arguments in
        let tree = try await UEFIAgentQueries.readyTree(host)
        await withCheckedContinuation { continuation in
            tree.resolveDMIStores { continuation.resume() }
        }
        guard let found = tree.dmiStores else {
            throw AgentToolError("The file changed while its DMI areas were being looked for; ask again.")
        }
        let image = tree.image()
        let readers = tree.spaceReaders
        var areas: [JSONValue] = []
        for store in found {
            let chain = await withCheckedContinuation { continuation in
                tree.materialize(containing: store.range.lowerBound) { continuation.resume(returning: $0) }
            }
            guard let node = chain.last(where: { $0.kind == store.kind && $0.range == store.range }) else { continue }
            let detail = UEFIDetail.build(
                for: node, image: image,
                reader: readers.reader(for: node.space) ?? ImageReader([UInt8]()),
                repairs: [],
                catalogue: .empty,
                lenovoDMIReaders: tree.lenovoDMIReadersSearched ? tree.lenovoDMIReaders : nil,
                in: .english)
            areas.append(UEFIAgentQueries.merged(
                UEFIAgentQueries.summary(of: node, in: tree),
                [
                    "layout": .string(layout(of: store.kind)),
                    "size": .string(UEFIAgentQueries.hex(store.range.upperBound - store.range.lowerBound)),
                    "path": .array(UEFIAgentQueries.path(to: node.id, in: tree).map { .string($0) })
                ].merging(UEFIAgentQueries.detailMembers(detail)) { first, _ in first }))
        }
        var answer: [String: JSONValue] = ["areas": .array(areas), "total": .count(areas.count)]
        answer["note"] = .string(areas.isEmpty ? "None found. \(scope)" : scope)
        return .json(.object(answer))
    }

    /// Which of the known layouts a store is, by the name the bench knows it
    /// by: the Type column calls every one of them Padding, as UEFITool does.
    nonisolated static func layout(of kind: UEFINodeKind) -> String {
        switch kind {
        case .lenovoDMIStore: return "Lenovo DMI store"
        case .gpnvStore: return "GPNV store"
        case .acerDMIStore: return "Acer DMI"
        default: return "Unknown"
        }
    }
}
