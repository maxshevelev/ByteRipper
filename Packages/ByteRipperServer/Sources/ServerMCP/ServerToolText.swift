import Foundation
import ToolModuleKit

/// What the server's tools say (`Design/SERVER_HEADLESS_PLAN.md` §7). A
/// tool-module's text names the app's panels and the person at them; this host
/// has neither, so the four that do are worded again here — same facts, no
/// panel, no `open_part`, no `survey`, no `_fix_checksum`. The rest keep the
/// module's own words, and `Modules/UEFITool` is not edited.
public enum ServerToolText {
    /// `query` with this host's description, when it has one.
    public static func query(_ query: ToolAgentQuery) -> ToolAgentQuery {
        guard let description = overrides[query.name] else { return query }
        return ToolAgentQuery(name: query.name, title: query.title, description: description,
                              properties: query.properties, required: query.required, run: query.run)
    }

    /// `ghidra_open` by a node, where Ghidra is this server's.
    public static let ghidraOpen = """
        Opens a module for a review in Ghidra and answers its owner's `hello`: program, functions, \
        unpublished changes. Give the PE32/TE image `node` of a dump (`uefi_find` with name "PE32 image" \
        or "TE image" lists them) and its `document`: its bytes go to Ghidra, whose project is made the \
        first time — seconds for a PEIM, a minute for a large DXE driver. A module seen before opens by \
        `module`, the SHA-256 the answer gives. Then read, rename, type and comment with the other \
        `ghidra_` tools and `ghidra_publish`: every publication is a new revision of the module's \
        analysis, and every host that reads the store shows it. A review aims at C that reads like \
        source — enums for constants, structures for pointer walks, comments a source would have; the \
        MCP instructions spell the rules out.
        """

    static let overrides: [String: String] = [
        "uefi_tree": """
            The structure of a firmware image: regions, volumes, files, sections, NVRAM stores and the rest. \
            Without `node`, the top of the tree and a one-line summary of the image; with it, that node and \
            its children. `depth` (1–3) goes further down. Each node: `id` (pass it back as `node` — never \
            show it to the person), `label` (what to call it to the person: its name, with its addresses \
            where the name is only a kind such as Unused), type, subtype, name, GUID, its bytes (`start`, \
            `end`, or `in_compressed: true` when it lives inside a decompressed section and has no file \
            address), `compressed` — a compressed section's own algorithm, or for a node it decompresses to \
            the algorithm it came out of — and `compressed_in`, the innermost section it was decompressed \
            out of, on every node with `in_compressed`; `encoded` ("XOR 77") for a LENV block or entry \
            stored encoded in the file; and `children` — a count, or "unread" for a container not opened \
            yet (asking for it opens it). With `depth` above 1 a child carries the levels under it as \
            `below`. Pages: `limit` is the most children of `node` on one page, a ceiling — a page also \
            stops before the answer passes the size bound and then says `truncated: "size"`; pass `next` \
            back as `after` until it is null. A child whose levels below are too large alone comes without \
            them, marked `truncated: "item"`; ask for it as `node`. Ids belong to the document they were \
            listed on: give the `document` the id came from.
            """,
        "uefi_node": """
            Everything the parser says about one node: its fields (header values, sizes, attributes, \
            checksums — a wrong checksum is marked `problem`), its tables, the path of names down to it, \
            and the parser's diagnostics inside its bytes. NVRAM variables come with their value decoded. \
            A module with a dependency expression adds `dependencies`: the expression in words, the GUIDs \
            it pushes, every opcode with its offset, and what does not parse.
            """,
        "uefi_checksums": """
            Checks every checksum the parser knows — a volume's header checksum, a file's header and data \
            checksums, a microcode's, an AMD PSP or BIOS directory's — in the whole image or under `node`, \
            opening every volume and decompressing every section it can, and lists the nodes whose \
            checksums are wrong: which field, what is stored and what it should be. A node inside a \
            compressed section is checked against what the section decompresses to; it is marked \
            `in_compressed`. `checked` counts the nodes that carry a checksum, `wrong` those listed. \
            Pages: `limit` is a ceiling — a page also stops before the answer passes the size bound and \
            then says `truncated: "size"`; pass `next` back as `after` until it is null.
            """,
        "uefi_dmi": """
            The image's DMI areas — where the firmware keeps the board's identity: serial numbers, UUID, \
            model. It opens every container in the file, but no compressed section. Each area: `layout` \
            ("Lenovo DMI store", "GPNV store", "Acer DMI", "Panasonic DMI" — the Type column calls these \
            Padding — or "HP DMI", a VSS entry that may be one the store marks deleted, as most HP boards \
            keep it, or "Apple DMI", a SysF store), its node as `uefi_tree` gives it (`id`, `label`, \
            `start`, `end`, `encoded` for an XORed LENV block), `size`, `path`, and the parser's `fields` \
            and `tables` for it; `uefi_node` on its children reads further, `uefi_node_data` reads the \
            bytes. The parser finds a DMI area only by its algorithms for the dump layouts it knows: \
            Lenovo's DMI store (an LDBG change log and two LENV blocks), AMI's GPNV store as ASUS writes \
            it, Acer's 8 KiB DMI area, Panasonic's DMI area (a MEI_ header, a directory and records), and \
            HP's HP_MUD variable in the main VSS2 store, with BuildId, FactoryConfig (the feature byte) and \
            HP_TAGS (the asset tracking number) beside it — what HP's BCU reports, and Apple's SysF store \
            of the Mac's serial number (ssn), configuration code (hwc) and sales order number (son), with \
            the board's serial read from the names of its calibration variables. An area that is not found \
            is not therefore absent from the dump: it may be in a layout the parser does not know, or a \
            known one that is damaged, wiped or moved so its checks fail. So an empty `areas` means only \
            that the parser recognised none — say so to the person, never that the dump has no DMI; \
            `region_scan` judges the nameless areas by their bytes, which is where to look next.
            """
    ]
}
