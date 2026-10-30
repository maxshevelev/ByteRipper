# ByteRipper

A macOS hex editor and binary-file comparator, written in Swift/AppKit for macOS 14+. Compare two files byte by byte — by absolute offset, no alignment tricks — and edit either one in place. No third-party dependencies.

ByteRipper grew out of bench work on BIOS and EC dumps, so the comparison model stays deliberately simple: a byte at offset N is compared to the byte at offset N, nothing more. That is exactly the question a repair bench asks — *is this chip's content the same as the one that works?* — and the app is built around answering it fast, on files of the size a programmer clip actually pulls off a board.

Beside the dump there is a **tool panel**: the same image read as the structure it is — the UEFI tree, the FIT table, the Intel ME region — so the other half of a bench's questions can be answered without leaving the editor. See [The tool panel](#the-tool-panel).

And an **agent** — Claude Code, Claude Desktop, Cursor or any other program that speaks MCP — can be let in to work on the same dumps: read the bytes and the structure, compare a folder of them, leave annotations on what it found and show you where. See [Working with an agent](#working-with-an-agent).

<img width="1541" height="799" alt="Screenshot 2026-08-21 at 23 15 39" src="https://github.com/user-attachments/assets/0ff1c54c-78b5-4f7c-94e4-53a005a782ed" />


## Download

[**ByteRipper 0.9.5**](https://github.com/maxshevelev/ByteRipper/releases/latest) — a universal `.dmg` (Apple silicon and Intel), macOS 14 or later.

The build is ad-hoc signed and not notarized, so Gatekeeper stops the first launch: right-click the app and choose **Open**, or clear the quarantine flag once.

```sh
xattr -dr com.apple.quarantine /Applications/ByteRipper.app
```

## On the bench

The workflows the app is shaped around:

- **A dump against a known-good donor.** Differing bytes are filled orange; ⌘⌥→ / ⌘⌥← walk the differing regions and centre each one, so scrolling 16 MB by hand is not part of the job. Select a region and **Edit ▸ Copy to Other Pane** (⌥⌘C) writes it over the same addresses in the other file — one step, no clipboard, one undo.
- **Finding the region that matters.** The overview minimap draws the whole chip in one column, shaded by how much real content each slice holds: erased `0xFF` blocks stay pale, code and tables read dense. A blanked, truncated or corrupted region shows up as the wrong texture at the wrong place — before you know its offset.
- **Keeping your place in it.** ⌘D marks the caret's row and offers it a name; the mark is a purple arrow in the Offset column and in the minimap's margin, so the header, the table and the region under investigation stay findable while you work between them. Every jump — Go To, a difference, a search result, a row of a tool — leaves a place behind, and ⌘[ goes back to it.
- **Patching by hand.** ⌘L to the offset, type the hex digits, the changed bytes turn red until saved. Confirmations guard the operations that shift data.
- **Two chips, one image.** Plenty of boards split the BIOS region across two SPI flashes. Read both, **File ▸ Append File…** to join them in order, work on the whole image as one dump — compare, search, patch — then **Save All as Separate Files…** to split it back at the same seam and flash each half. Each half remembers the file it came from, so a patch in the joined image shows red against that chip's own dump, and **Revert Segment to «file»** puts one half back as it was read.
- **Taking a part out, and putting it back.** A compressed section, a zone, any node of the structure tree opens as a **panel over the dump it came out of** — the parent still showing above it, the panel folded down into a pill along the window's bottom edge when you are done with it. Edit the decompressed body, **Update in Parent**, fold the panel away, and the change is in the dump behind it, as one undo step.
- **More than one comparison at a time.** A board rarely gives you one question. ⌘T opens another tab — its own two panes, its own bookmarks, its own comparison — so the donor pair stays open while you look at the second chip, and ⌃Tab goes back.
- **A job that outlasts the day.** **File ▸ Save as Project…** keeps everything open for one board — the tabs, the dumps, where each pane was, the bookmarks, the cuts, the parts taken out, the unsaved changes and the undo history — in a `.brp` beside the dumps, written as you work. Open it tomorrow, or on another Mac with the job folder copied whole, and ⌘Z still undoes yesterday's patch. See [Workspace and projects](#workspace-and-projects).
- **Chip-sized files, not toy files.** Files are read in chunks and never loaded whole, so a 16 MB SPI dump — or a 1 GB image — opens immediately and stays within a low double-digit megabyte working set.

## The tool panel

Half of what a bench needs to know about a dump is not in the bytes but in the *structure* over them. Which region is this offset in. Whether this volume's checksum still holds after a patch. What microcode the board carries, and whether it is the one the CPU on it wants. Whether the ME region is the firmware that shipped with the board, an update, or something a bad flash left behind. Answered by hand, each of those is counting offsets against a specification with a dump open in one window and a document in another.

The **tool panel** answers them next to the dump. It opens on the left from the **Tools** menu (⌘1 ME Analyzer, ⌘2 FIT Table, ⌘3 UEFI Structure, ⌘0 to close it) or the toolbar's wrench, one tool at a time, bound to the pane it was opened for — so in a comparison the panel reads *one* of the two files. Its header says which, as a dropdown that also **takes the tool to the other pane**; dragging a pane's header onto the panel does the same thing. The name it shows is the file the panel works on and nothing else, so clicking into the other pane to read it does not make the panel claim the tool has moved. A row picked in a tool takes the dump to the bytes behind it and draws that node's extent in the minimap's margin, so the region under investigation stays visible while you work in it. Everything a tool writes goes through the editor's own undo stack: a fix is an edit like any other, and ⌘Z takes it back.

Three tools ship.

### UEFI Structure

The flash image as the tree it actually is: the Intel descriptor and each region it maps, firmware volumes, FFS files and their sections, NVRAM stores with every variable in them, microcode, padding, free space. A node's detail says where it starts, how long its header, body and tail are, what its GUID is — named, when the GUID is a known one — and what its header holds, field by field.

<img width="1418" height="816" alt="Screenshot 2026-09-11 at 06 57 26" src="https://github.com/user-attachments/assets/956b1703-3dfd-41e6-a18c-d8bcb97c99c0" />

- **The tree is read lazily.** Opening the panel on a 32 MB image is instant: the top level is parsed, and a branch is read when it is opened. One tree serves all three tools and survives switching between them, so the FIT table and the ME Analyzer start from what has already been read rather than parsing the image again.
- **Checksums are checked as the tree is built**, and a wrong one is flagged on the node that carries it — a volume header, an FFS file, an NVRAM record. **Fix Checksum** writes the value the format asks for, as one undoable edit.
- **Addresses are the ones the CPU sees.** The image's own reset vector anchors the mapping, so a node's `Address` is where that byte is in the processor's address space, not merely its offset in the file.
- **The ME region is part of the tree.** Opening its node runs the same analysis the ME Analyzer runs and grafts that reading in place — the partitions, their directories, the volumes and the files in them — rather than parsing the region a second way. It is read when the node is opened, with a Loading row while it runs, and a region that cannot be analysed is still the region: the node stays, holding what the descriptor says about it.
- **Any node opens on its own.** *Open “PEI Core”* takes the whole node, *Open Body of…* its payload, and a compressed section offers **Open Decompressed Body** — decoded when the command is chosen, whether or not the node has been expanded; a node inside one says its bytes are decompressed (**Open Decompressed “…”**). What opens is a panel over the dump; **Update in Parent** writes it back. **Save “…” as…**, **Save Body of “…” as…** and **Save Decompressed Body as…** write the same bytes to a file instead. A double click on a row opens what the node holds: a compressed section's decompressed body; a volume, a file or a store whole, so the part's own tree shows it as the structure it is; otherwise the node's body.
- **The board's identity is found, wherever the vendor hid it.** The serial numbers, the UUID, the model and the Windows key live in a different place on every brand: Lenovo's DMI store — a change log and two XOR-encoded LENV blocks — is read decoded, with the block the firmware uses marked and each entry's value beside its name; ASUS's GPNV store, Acer's DMI area in the BIOS region's padding, HP's `HP_MUD` and the variables beside it (what HP's BCU reports), a Mac's SysF store (serial, configuration code, sales order, board serial) and a Panasonic Toughbook's `MEI_` area (asset tag, serial, Windows key, its checksums checked) are read as well. Each value is a row of its own and a link from the store's details. The badge in the panel's title row names whose layout it found — **Lenovo DMI**, **HP DMI**, **Apple DMI** — and goes straight to the store, however deep in the tree it lies; a LENV block opens decoded as a part, to be edited and put back encoded.
- **Every variable store reads as its variables.** VSS and VSS2, AMI's NVAR, Phoenix EVSA, Dell's DVAR, and Insyde's default variables where its flash map puts them; a store's details say how full it is. The tree lists one row per variable — the copy in force — and its details carry the **history** the store still keeps: every earlier copy, when it was replaced, and which bytes changed. A Dell variable is named by the BIOS Setup option it holds, read out of the firmware's own Setup pages, with its value as Setup words it: `SecureBoot = Not ticked (0x0)`.
- **An AMD board's PSP area is read.** The Embedded Firmware Structure, every PSP and BIOS directory — combo, second level, slots A and B — and each piece of firmware they list, named by AMD's type, each a row; a directory lists its entries and leads to them, its checksum is checked and fixed like any other, and a BIOS image the PSP inflates itself opens to its volume. Whether the PSP accepts that image compressed again is not documented, so writing a change back into it asks first and says so, and **Update Anyway** compresses it behind AMD's header.
- **What a vendor keeps outside the volumes is named.** The regions Insyde's flash map lays out — the EC firmware, the BIOS version table with the version, product, build date and compiler it records — listed under Entries, each a link to its bytes — SMBIOS, MSDM, Lenovo's EEPROM and passwords; the FIT, the Startup ACM and the Boot Guard manifests where they sit in padding; and the boot logos and icons, previewed under their details. EC firmware is named by the chip and version it carries and its size in KB, one row per image in a block.
- **The tree can be searched.** The magnifier left of the funnel (or **Edit ▸ Find** in the tree) opens a bar above it: text matched against a row's name, the node's own name or its GUID, plus a Type and a Subtype pop-up. ‹ › — or ⌘G and ⇧⌘G — walk from match to match, opening the way to each and shutting it again on the next; a long search shows its progress and a stop button. The tree and the dump's Find bar share one find string, as Mac apps do: a pattern taken with ⌘E in the dump is what the tree looks for next.
- **…and so can what the tree holds.** **Contents** looks for a text or hex bytes (with `??` for any byte) inside every node — every compressed section in what it decompresses to, a BIOS Guard update in the region it assembles, an encoded LENV block decoded. That is the search a dump cannot do: a string inside an LZMA section is not in the file's bytes. The results list each match under its node, with a badge for each codec the bytes came through; a double click opens the decompressed body as a part with the match selected. The pattern is asked for with the Find bar's own controls, its recent queries and library included.
- **A row's details open large.** Space on a row, or the expand button in the details' corner, lifts the detail list into a card over the window while the arrows keep moving the table beneath it; Space, Esc or a click outside closes it. The details of all three tools select like text — a drag takes a band of rows, a triple click one row — and ⌘C copies them with a tab between name and value, so a spreadsheet takes them as a table. Pictures show larger in the same card.
- **AMI's GPNV store is read** — where ASUS keeps the machine's serial numbers, model and Windows key — as a row with a row per record; an OA30 record shows the product key, and replaced records fold away into the variable's history.
- **A vendor's BIOS Guard (PFAT) update file opens as a tree** — its BIOS region assembled from the signed blocks, entry by entry — and **Compare with PFAT Update File…** on a dump's BIOS region lists each part as identical, different or board data (NVRAM and per-board stores, kept by default); **Write** lands the ticked parts as one undo step, only the bytes that differ.
- **More of what vendors keep in padding is named**: AMD microcode, HP's signature blocks (the digest checked where its span is known), and AMD's Zlib sections open to their volume. Empty padding and free space are drawn grey, and *Show the node under the caret* on padding the tree hides offers to show it.
- **A tool can add commands to the dump's context menu.** A right-click on a byte lists, under the open tool's name, what it offers for that byte; the UEFI Structure panel's **Show in Tree** does for the clicked byte what the title row's reveal button does for the caret.
- **Top Swap is shown for what it is.** The copy of the boot block one block down is named as the copy, and any node in either block steps to its twin — **Go to Top Swap Copy**, **Go to Original** — so which part of the copy stands for which part of the top block can be seen.
- **The descriptor says what it lays out.** The chipset generation, the size of each flash chip and where a second one begins, the SPI clocks, the opcodes the chipset will not send, and each region's base and limit — with a dump whose length is not the chips' total marked as such.

### FIT Table

The Firmware Interface Table the CPU reads before any code runs: every entry with its type, version, size and checksum, and **what it points at** — named from the structure tree, so a table of addresses reads as a table of things rather than a column of numbers.

<img width="1372" height="829" alt="Screenshot 2026-09-11 at 06 58 59" src="https://github.com/user-attachments/assets/3cc9ea74-df66-4104-83e1-62ef91379fe1" />

Microcode is the part a bench changes. **Add**, **Replace** and **Remove** work on the table's microcode entries, with the replacement picked from a catalogue of Intel's published microcodes by CPUID, revision and date; the table's own bookkeeping — the entry count, the header checksum — is rewritten with it, and the whole operation is a single undo. A microcode row names every processor the update serves, its extended signature table's included (`CPUID B06A2 + B06A3, B06A8`), and the table keeps one microcode per processor: an update already in it under another CPUID is refused naming its row, and two rows for one processor are flagged.

Editing the dump makes the table read again, and it comes back **where you left it**: an outline put on the component a row points at stays on that component rather than sliding back to the row and taking the dump with it, two pages up the file from the microcode you were typing into.

### ME Analyzer

What the Intel ME/CSME region in this dump actually is, in the words the field uses — shown as soon as the region is read, with the few values that wait for a database still downloading saying *Loading…* until they are in: family and version, SKU, chipset and stepping, release and revision, the date it was built, and whether it is a stock image, an update, or one extracted from a board. Firmware stitched inside an image is analysed in its own right and gets its own table.

<img width="1238" height="957" alt="Screenshot 2026-09-11 at 06 59 48" src="https://github.com/user-attachments/assets/ab877f72-5520-4392-81b0-138793893835" />

**Full Info** now goes down to the files. The MFS volumes are cut into the records they hold — an EFS volume's files out of its data area, an FTBL volume's out of the integrity table it ends with — and each is named from the firmware's own `FileTable.dat` rather than numbered. The OEM configuration a board's FITC partition carries is decoded record by record, with the file each record points at named beside it, and a UTOK/STKN partition's Unlock Token flags are read out of the block they sit in. Every row reveals its own bytes in the dump, so a field that reads wrong is one click from the bytes behind it.

The health rows are the ones that say whether a region survived what happened to it — RSA signature, partition tables, the EFS volume and its page bookkeeping, the MFS dictionary, the file-system state — each shown as a plain Yes/No or a coloured word rather than as a hex field to interpret. **Full Info** opens the same analysis as the structure behind those answers. **Copy** puts the summary on the clipboard as rich text and **Screenshot** as a picture, which is what a ticket, a forum post or a message to another bench actually needs. Each says so over the window, in the same plate a search reports in and wearing the glyph of the button you pressed, so the evidence that the click did anything is not the paste.

## Working with an agent

The tool panel answers the questions a bench asks of one dump. An agent can ask them of twenty: which of these dumps carry the same NVRAM variables, which ME files changed between the working board and the dead one, where in a folder of images a serial number lives. **Settings ▸ Agent** lets one in — Claude Code, Claude Desktop, Cursor or any client that speaks MCP — and gives the text its configuration needs, ready to copy.

- **It works on what you are looking at.** "This byte" is the caret, "here" is the selection, and a place the agent wants you to see is brought forward — in a comparison, its pane made the active one — scrolled to and selected, a step of the navigation history, so ⌘[ comes back. The UEFI tree, the FIT table and the ME analysis are read as the panels read them, open or not; a node it names is a link that opens it.
- **Across files, not only in them.** Open a folder of dumps by path without putting them on screen, ask the same question of each — every file named by its path from the folder, so one board's `bios.bin` in each of twenty folders stays twenty files — compare them byte by byte with each difference placed in the firmware, compare NVRAM by name and GUID or the ME file systems by file, find a pattern inside compressed sections, find who refers to an address or a GUID.
- **Changes only when you allow it.** **Let agents edit open files** is a second switch, off by default. With it on, an agent can write bytes, copy a range to the other pane, fix checksums and add or replace FIT microcode from the catalogue — each one undo step named after what it did; saving stays yours.
- **The connection is local**: a socket in your Library that only your own user account can reach, no network port. What an agent reads, its program passes to the model behind it — a dump that must not leave the workshop should not be open while one is connected. Every call is listed in **Window ▸ Agent**, and an orange dot blinks on the toolbar's **Agent** button while one is at work.
- **A folder of dumps has its bounds.** How many dumps an agent opened by path stay parsed, and how much memory they may hold between them, are set in **Settings ▸ Agent**; past either, the one not asked about longest is let go, and read again when it is named.

### Annotations

A title and a note on a place in a file — *what these bytes are*, *what was found here* — drawn over the bytes as a dashed outline wherever the file is on screen, the note named the moment the pointer reaches its outline — not over every byte inside it, which stay readable. **Add Annotation…** on a selection or on a node of the UEFI tree makes one by hand, in green; an agent's are violet. A node inside a compressed section or an encoded LENV block is annotated in the bytes it decodes to. An annotation belongs to the file, so it comes back when the file is opened again. **Window ▸ Annotations** (or the toolbar button after **Segments**) lists all of them as cards, open files or not — the newest first, a new one tagged *New*, any card dragged to where you want it, the order kept between launches. A double click goes to the place, decompressing the way to it if it has to, and in a comparison makes the note's own pane the active one, with **UEFI Structure** moved to that file. Right-clicking a byte under annotations offers **Open Annotation “…”** for each; ⌘A selects every card, ⌘Z puts back the ones just removed, and the window's ‹ › return to the place a note was made on.

## The analysis server

A headless copy for the bench and for an agent that works without the app: it holds a dump, the UEFI tree and the code store, hosts the kept Ghidra projects of the modules reviewed in them, and speaks MCP to an agent — the same `uefi_`, `code_` and `ghidra_` tools the app gives one, plus the Ghidra review skill.

- **It is a folder, not an installation.** `Scripts/make-agent-dist.sh` builds `dist/byteripper-analysis-<version>/` and a tarball of it — `dist/byteripper-analysis.tgz` always names the newest: the server and the store's command line, the Ghidra scripts it compiles, the review skill, launchers, and an empty `var/` that holds everything the copy keeps — store, projects, documents, uploads, socket, logs. Unpack it anywhere; nothing in it points at this repository or at the app.
- **It needs Ghidra and a JDK**, nothing else. `GHIDRA_HOME` names the install, or the newest `~/Projects/ghidra/ghidra_*` is used; the EDK2 headers the UEFI pass types a module with are fetched once.
- **Starting it:** `scripts/start-server.sh` (idempotent; makes the console token on the first run), `scripts/stop-server.sh` and `scripts/restart-server.sh`, and `scripts/agent.sh`, which starts it, writes `.mcp.json` and opens a Claude Code session in the folder. The console is at `http://127.0.0.1:<port>/admin`, the port written to `var/port`; `scripts/doctor.sh` says what is missing.
- **The server reads `~/.byteripper-server.json`** when it exists — any of its flags as a key, flags on the line still winning — with `--config` naming another file and `--no-config` reading none. Every path it keeps has its own flag, so one server on a shared bench can serve several Macs.

Its `README.md` is the short card of the folder, and `INSTALL.md` — in the
repository and unpacked with the folder — is the guide for a first install:
what it needs, how it is built and started, an agent session, the configuration
file, and what to do when something is wrong.

## Standing on other people's work

The formats these tools read were not worked out here. The algorithms and the reference data behind the EFI-side tools were **ported from public projects** whose authors did the hard part — years of reading firmware, writing down what is in it, and keeping that current as Intel moved — and what ByteRipper adds is a native Mac interface to their work, beside the dump and inside the editor:

- **[UEFITool](https://github.com/LongSoft/UEFITool)** by **[LongSoft](https://github.com/LongSoft)** — the shape of a UEFI image and how to walk it, the item and section types the tree names, the NVRAM store and variable formats, and the GUID catalogue (`common/guids.csv`) that turns a GUID into the name of a thing.
- **[MEAnalyzer](https://github.com/platomav/MEAnalyzer)** by **[platomav](https://github.com/platomav)** — the reading of Intel ME/CSME firmware end to end: what identifies a family, where each version keeps its version, what makes an image stock or an update, and the databases a dump is checked against (`MEA.dat`, `Huffman.dat`), fetched as the project publishes them.
- **[CPUMicrocodes](https://github.com/platomav/CPUMicrocodes)** by **[platomav](https://github.com/platomav)** — the catalogue of Intel microcodes the FIT tool's picker offers, kept current by hand for years.

These projects are why a repair shop can work on modern firmware at all. Between them they turned formats that ship with no documentation into knowledge anyone can use, gave it away, and have maintained it release after release without being paid for it — and an enormous part of what this trade knows about UEFI images and Intel ME firmware exists because those authors chose to publish rather than to keep. Our deepest thanks to them. If these tools are useful to you, the projects above are where the credit belongs; go and star them, and see the About panel for the same links in the app.

## Features

### Comparison

- Two panes: open one or two files via **File > Open…** (⌘O) or drag-and-drop. One file — single-pane mode; two — comparison.
- Differing bytes get an orange fill, tuned for light and dark mode; the shorter file's EOF tail counts as a difference too. The status bar shows how much of the two files differs, as a percentage of the longer one — `differing 0.4%`, rounded up to a tenth, so a single differing byte in 16 MB still says 0.1% — updating as you edit, and saying nothing at all while the files are identical.
- **Next/Previous Difference** (⌘⌥→ / ⌘⌥←) and **Next/Previous Same Block** (⌘⌥⇧→ / ⌘⌥⇧←) centre each result. Navigation steps between *changes*, not bytes: differing bytes closer together than the grouping distance (64 bytes by default) are one target, so a rewritten NVRAM area is one press instead of hundreds while highlighting stays per byte.
- A selection in one pane is outlined in the other, so the two halves of the same offset read as one. **View > Toggle Pane Layout** (⌘⌥L) switches side-by-side and stacked; **Swap Panels** exchanges the two files without reopening them.

### Tabs and windows

- **⌘T opens a tab**, ⇧⌘N a window. A tab is a whole comparison of its own: two panes, one bookmark list, its own diff index and minimap. ⌃Tab moves between them, and a tab can be dragged out into a window or back in — the tab bar is the system's, so it behaves like every other one on the Mac.
- Each tab is named after what it holds — `dump.bin`, `A.bin ↔ B.bin`, or `Empty` — so the bar and the Window menu are readable.
- **⌘W steps down**: it closes the active pane, then the tab once no pane is left, then the window once no tab is. A tab whose last file is closed goes with it while other tabs are open, unless it holds bookmarks. ⇧⌘W closes the window and every tab in it.
- **A file is open in one place at a time.** Opening one that is already open somewhere asks what you meant: show it where it is, move that pane into this tab, or cancel. The pane *moves* — the unsaved edits, the undo history and the segments come with it, and the file is never open twice.
- **Drag a pane by its header.** Onto the other pane to swap them, onto its top or bottom edge to join it in, onto another tab to move it there (hover the tab and the bar switches), or onto the strip that appears at the top of the window to give it a tab of its own. In single-file mode the free half offers **Duplicate Here** — the dump beside itself, so a patch you make shows every difference it causes.
- **Drop a file on that strip** to open it in a new tab without disturbing the window you dropped it on.
- An empty window is not an empty room: bookmarks belong to the window, so closing the last dump leaves the marks, and the window lists them and counts them in its title — `Empty (3 Bookmarks)`.

### Parts of a dump, opened over it

- **A part of a file is not a comparison, so it does not get a tab.** A zone, a node of the structure tree, a decompressed section — everything that used to open beside the dump now opens *over* it: a panel that rises from the bottom of the window, stands in from the panes over a dimmed scrim and leaves enough of the parent showing to say which file it came out of; a click on the scrim folds it. It is a surface of its own, with one header across it, its own minimap and its own tool panel, so the part can be searched, patched and analysed exactly like a dump.
- **The dock along the bottom is what you have taken out of this image.** Each folded panel is a pill named after what was opened — the node, its body, the zone — and nothing else, with the codec's name beside it when the bytes went through one (`LZMA`, `XOR 77`), a part opened out of a decompressed one included; one panel is up at a time, and clicking another pill folds the open one down and raises that one in a single movement. The panel flies out of its own pill and lands back on it, so which pill a panel belongs to is never in doubt.
- A **⌄ beside the panel's ✕** does the same thing as a button, for the times a gesture is not what you want. **Pull the panel down by its header** to fold it away. Near the top the pull is a *look* at the dump underneath — let go and the panel goes back where it was, unless you flicked it, which is still a way to put it down without carrying it there. Past the halfway line the last movement of the hand is the instruction: nudged up it springs back, nudged down it carries on down, however long you rested before letting go.
- **The way back is in the header.** The link names the parent and jumps to it, and **Update in Parent** writes the part's bytes back where they came from as one undo step. A link that no longer leads anywhere is drawn as a dead one — a red row, not a button — rather than failing when pressed.
- Closing the parent of an open part asks first, and says what the answer costs: *its bytes stay as they are; only the way back goes.* **Quit** asks the same thing for the whole app, and says how much is at stake before it starts working through the windows one by one.
- **A part reads the window's bookmarks at its own offsets.** A row marked in the dump is marked in the part taken out of it, and a mark made in the part lands on the dump's row — a bookmark belongs to the file, and a panel is a window onto it.
- **Every part opens through a codec that reads it and puts it back.** A decompressed section, a LENV block decoded: the header shows a badge for each — `LZMA`, `XOR 77` — so a panel of plain text never reads as the file's own bytes, and Update in Parent encodes it again on the way back.
- **A panel can still become a tab.** Drag it by its header onto the New Tab strip — the same gesture a pane is torn off by — drag its pill out of the dock the same way while it is folded, or choose **Open in New Tab** from the pill's menu. The document goes with it: unsaved edits, undo history, segments, and the link back, so Update in Parent keeps writing into the file the part came out of. A panel let go on a tab's free half becomes its second pane, so two parts can be compared.

### Going somewhere, and coming back

- **Go To Position…** (⌘L) is also the bookmark list, because the two answer one question: the addresses worth returning to are exactly the ones you would otherwise be typing again. It opens with the offset field focused — ⌘L, type, Return — and Tab moves the keyboard to the list, with Return following the focus. The field takes `0x`-hex or decimal, validates as you type, and keeps the last ten addresses it was sent to.
- **⌘D marks the caret's row** and opens a popover on the mark: type a name and Return, or just Return for an unnamed one. ⇧⌘D reopens it — the popover holds the bookmark's *address* as well as its name, so a mark put a row off is corrected by typing the right one, and a **Delete** button for the act Esc cannot mean.
- A marked row's address stands on a **purple arrow** in the Offset column, and a smaller one appears in the minimap's margin in both of its modes — a marked region is findable without opening anything. Hovering a mark on the map names it at once, in a callout wearing the mark's own shape — so does a segment's strip, a zone's bracket and a note's outline; a click near one lands exactly on the bookmark.
- **Drag a mark to another row.** A dump gets read before it is understood, and a mark often belongs a few rows from where it was put; dragging beats remaking it, which would lose the name. One row holds one bookmark, so a mark dragged onto an occupied row jumps past it or stops before it.
- **Back and Forward** (⌘[ / ⌘], or ‹ › in the toolbar): every jump — Go To, a bookmark, a difference, a search result, a minimap click, a click on a tool's row — records the place it leaves, both panes and the tool's chosen row included, and Back puts it back. Scrolling counts once it takes the caret off the screen; the arrow keys do not. Fifty places per tab.
- The list shows every mark by address, and **describes an unnamed one by what is at it** — the row's bytes as the dump writes them, read from the pane you are working in. Return jumps, a double click opens the editor, ⌫ removes.
- Bookmarks are absolute offsets, so one list serves both panes and marks the same height in both. They live as long as the window, not the file: closing a dump and opening it again keeps its marks — and with the [workspace](#workspace-and-projects) kept, they outlast a restart.

### Minimap

- A column beside the dumps, from the toolbar button or **View > Show Minimap** (⇧⌘M), with a **Local ⇄ Overview** switch in its header (⌘⌥M).
- **Local** is a miniature hex dump around the caret, one cell per byte. **Overview** is the whole file at once, one row per device pixel, each cell shaded by how much of its slice is real content rather than fill — which is what makes erased regions, tables and code distinguishable at a glance. The mode is chosen for the file you open, and a file the overview could only magnify greys that half of the switch out.
- Differences and unsaved edits mark the overview the way the dump marks bytes — a difference is an orange ground under the content, a row with an edit is drawn in red — and both are at least two pixels tall, so a single changed byte among millions stays visible and the content is never hidden under the mark. Two maps mirror the pane arrangement and share one scale: the same height is the same absolute offset in both.
- Drag the viewport marker to scroll, click elsewhere to go there, or roll the wheel over the panel. Rebuilds run off the main thread with progress in the status bar, and a resize rescales the picture in hand while the exact pixels are recomputed.

### Hex grid

- 16 bytes per row in two 8-byte groups; **View > Word Size** regroups them into 1/2/4/8-byte words. Three columns — address, hex, decoded text — under a pinned header.
- `0x00`/`0xFF` bytes are muted so significant data reads with more contrast; cells past EOF carry hatching, so the end of a file is readable without colour.
- Navigation like a text editor: arrows, Home/End, Page Up/Down, direct hex typing, and editing in the decoded-text column.
- **Zoom** (⌘= / ⌘−) steps the hex font one point at a time, applied live to every open dump and to an open Search Results panel. It is the same setting **Settings ▸ View** holds — the menu is a fast way to it, not a second preference — and the viewport keeps its place in the file across the change, as it does when the font or the row height changes.

### Editing

- Type hex digits or text — bytes overwrite in place, with per-pane Undo/Redo (⌘Z / ⇧⌘Z). Modified bytes are drawn red until saved.
- **The undo history is not held in memory.** The bytes of each change go to a journal on disk as the edit is made, so overwriting 512 MB does not hold a gigabyte for as long as it can be undone, and a fill keeps its byte sequence rather than the range it wrote. **Settings ▸ General ▸ Editing** bounds each document's history by size and by steps; past either, the oldest go.
- **Insert Mode** (⌥⌘I) switches typing from overwrite to insertion: the byte lands at the caret, the tail shifts right, and Delete/Backspace remove bytes instead of zeroing them. The mode is per pane — one file can be typed into while the other is read — shown as bold `OVR`/`INS` in a box at the end of that pane's status bar — the box in the same grey or red as the word inside it — and by the caret's own shape, and switched by clicking that indicator — it is the only place the mode is shown, and the only control that changes it. It shifts every offset from the caret on, so the first keystroke in each file asks once.
- Undo is segmented for typed input: the first ⌘Z takes back the last byte, a quick second takes back the rest of the run, and after a pause it is one byte per press again.
- **Paste Insert…**, **Delete Bytes…** and **Fill Selection with…** — the fast way to blank a region to `0xFF`. The confirmations for edits that shift the file can be turned off in **Settings ▸ General**.
- **Copy to Other Pane** (⌥⌘C, and in the menu over a selection) writes the selection over the same addresses in the other pane: copy and paste in one step, without the clipboard and without selecting the range twice. It overwrites, is one undo step in the file it wrote into, and refuses a read-only file or a range that runs past the other file's end.
- **File > New File** (⌘N) opens an empty in-memory document — somewhere to paste a block out of a dump; **Revert to Saved** throws away the session's edits.
- **File > Duplicate** copies the open dump — unsaved edits and all — into the second pane as an untitled document, so the file as it stands can be patched beside the original and every difference that appears is one you made. No bytes are copied: the two documents share the content until one of them is written, and on APFS the file behind them is cloned rather than duplicated, so duplicating a 32 MB dump costs neither the pass nor the disk.

### Segments and joining

- A dump is rarely one thing: a flash image is a descriptor, an ME region, a BIOS region. **Segments** name those stretches. A partition is a list of contiguous pieces covering the file — labelled `S0`, `S1`, `S2` in file order, each with an optional name — so a gap or an overlap cannot be expressed at all.
- **Split Here at «address»** in the dump's context menu is the fast path; **Edit ▸ Add Cut…** takes a typed offset and brings the caret to the cut it made, and **Merge** folds a piece into its neighbour. Once a pane is cut, a right-click inside a piece offers that piece's own commands — save, replace, select, edit — the same ones the minimap's strip offers. Every piece gets a tint: a faint wash on the dump's rows, and a colour strip beside the minimap that reads the file's make-up at a glance.
- **A cut travels with the content** — the opposite rule to a bookmark, which is an address you chose and must stay put. Insert bytes before a seam and the seam moves with the bytes it belongs to. Cuts are undoable along with the edits that move them.
- **Segments…** (⌥⌘S) opens the partition's own form: the pieces in a table, a row editor for the name and the boundary, and the operations that write. **Save Segment…** writes one piece to a file, **Save All as Separate Files…** writes the whole partition into a folder, and **Replace Segment from File…** swaps a piece's bytes for a file's contents in a single undo step.
- **A pane can be joined into another pane**, not only a file into a pane: drag one pane's header onto the top or bottom edge of the other and its bytes join there, unsaved edits included. It is the same operation, so it reads the same — *Insert at Start*, *Append at End* — and the pane it came from is left exactly as it was, the way a joined file is left on disk.
- **File ▸ Append File…** and **Insert File at Start…** are the other half of the round trip: a second file's bytes join the pane's content at one end or the other, and the seam they create is a cut — so a joined image splits back at exactly the boundary it was joined at. A join detaches the pane from its file: the result is untitled, so ⌘S cannot write a joined image over the dump it was opened from. ⌘Z reverses the whole join, re-attaching the pane to its original file.
- **A piece remembers the file it came from.** A joined image has no file of its own, yet each piece still has one: modified bytes are measured against it, so a patch reads red in a joined image as it does in a plain dump, and **Revert Segment to «file»** puts a piece back — asking first, and naming both lengths, when putting it back would move every segment after it. **Replace Segment from File…** asks the same question instead of refusing a file of another length.
- Both commands also sit in the pane header's own menu, and both accept a drop: drag a file onto the band at the top or the bottom of a pane to insert or append it.

### Workspace and projects

- **Reopen the workspace at launch** (**Settings ▸ General**, off by default) brings back at launch what was open at quit: the windows and tabs, File A and File B with the caret, the selection and the rows on screen, the bookmarks and cuts, the fragment panels and torn-off parts — decoded again from their parents — the tool panels with the row each had chosen, the Annotations window, the minimap and the Find bar.
- **Nothing unsaved is lost, and nothing is asked at quit.** Untitled documents, parts not yet put back and the unsaved changes of files on disk are written beside the workspace as you work — only the changed bytes, not copies of the files — and come back red, still unsaved; an abnormal termination does not lose them either. So does the **undo history**: after a restart ⌘Z undoes the edits made before it, the cuts move back with them, and undoing a join attaches the document to its file again.
- **A file that changed on disk is caught.** Each file kept changes are laid over is checked by its SHA-256, so a copy or a backup that only moved its date keeps its changes, and different bytes under the same date do not. One sheet after the restore lists the files no longer found and the files changed.
- **A project is a workspace in a file of its own.** **File ▸ Save as Project…** writes what is open into a `.brp` package and records into it from then on; **File ▸ Open Recent Project**, a double click or a drop switches to another, asking nothing about the one being left. Files are found by their path or relative to the project, so a job folder moves whole.
- All of it is written in the background; a gigabyte edit does not stop the window, and quitting waits for the writing without holding the main thread. Closing the last window quits as ⌘Q does, so the workspace keeps it.
- **A workspace or a project outlives the build that wrote it.** A newer ByteRipper opens what an earlier one kept and brings it up to date; an older one leaves a newer one's work untouched and says so, rather than writing over it.

### Search

- **Find** (⌘F): query history, an encoding popup (**Hex bytes**, **ASCII**, **UTF-8**, **UTF-16 LE/BE**), a case toggle, **Smart Search**, and paired ‹ › buttons; **Find Next** (⌘G) and **Find Previous** (⇧⌘G) step without the bar in focus, opening it if it is shut. Searches run in the background, with progress and a cancel in the status bar.
- **Every occurrence at once.** Activating a search greys every match in the dump and marks them on both minimap modes; the one you are standing on is raised on a yellow plate that hops when you step to the next. The bar counts them — `3 of 128`, exact at any size — and ‹ › are then steps through that count rather than fresh scans.
- **The match comes before the count.** The first occurrence is found by a scan from the caret in about a millisecond on a 16 MB dump; the index of every *other* occurrence fills in behind it, so a pattern as common as `FF` never makes you wait for it. Navigation wraps, and a search that came round the end of the file says so.
- **Smart Search** (on by default): you know the string, not how the firmware stored it. A pattern that reads as hex bytes is looked for as bytes first and as text after; anything else is tried as ASCII, UTF-8 and UTF-16 LE/BE in turn until something is found — and the encoding that found it is what the popup then shows. Name an encoding yourself, by choosing it or by picking an earlier search out of the history, and that is where the hunt starts. A pass that finds nothing says which encodings it tried.
- **Patterns you keep.** The pattern field's menu holds two lists: **Recent Queries**, what you searched for lately, and **Favorites**, the ones you named — a favourite *is* a recent with a name, so keeping one asks for the name and nothing else. Choosing one searches with the encoding it was kept under, so `windows` kept as UTF-16 LE comes back as UTF-16 LE. Only searches that found something enter the history, and a hex pattern is shown back the way a dump prints it: `DE AD BE EF`.
- **Use Selection for Find** (⌘E) takes the pattern out of the dump: the selection becomes what the next Find will look for, and nothing else happens — no bar, no search, the caret and the focus left where they are. The column the selection was made in decides what the pattern says: bytes from the hex column, written the way a dump prints them, and the text they read as from the decoded-text column. Bytes that are no text at all — a selection starting mid-character, a run of `FF` fill, a stretch of code — come back as bytes, since a pattern of replacement characters would find nothing that is in the file.
- **Search Results** lists every occurrence in a panel beside the dump — the same set the dump highlights, not a second search — with each offset, a hex excerpt and the decoded text, read from the pane's live bytes so they follow later edits. Past a thousand matches it states the count and refuses to list: a list that long is a sign the pattern needs refining, not a tool.

### The pattern library

- **Settings ▸ Favorites** is where the kept patterns are edited — the name, the pattern, the encoding, the case rule, in the table itself — with the order yours to drag. One search is kept once, whatever it is called, and a pattern the encoding cannot read is refused where it is typed rather than at the next search.
- **The library can live in a folder your Mac syncs.** Point **Move…** at one — iCloud Drive, Google Drive, Dropbox all work the same way, because the app asks for the folder rather than for an entitlement — and the patterns are on your other machines. Choosing a folder that already holds a library is joining it: twelve patterns on one Mac and three on the other make fifteen.
- **One file per machine.** Each Mac writes exactly one file there and reads everyone else's, so no file has two writers and a sync provider never has to choose between two versions of one. What it holds is merged rather than overwritten: entries carry an identity, so a rename is a rename; deletions travel as deletions; a line removed from the file by hand comes back, because absence with nothing to say it was deleted is not evidence.
- **What a rule must not decide is asked.** The same entry changed differently on both machines, one edited here and deleted there, one search kept under two names: the tab says how many questions there are, and a sheet puts them one to a row with both sides in full. Both machines are asked, and an answer on one settles the other. Nothing else makes the library read-only.
- The library is JSON on purpose — `Application Support/ByteRipper/Favorites.json` — so it can be read, diffed and edited; a pattern typed into it with a text editor arrives like one made on another Mac.

### Toolbar

- Icon-only and fixed: the **Tools** pull-down first — the wrench, beside it the name of the tool the tab is on, or "Tools" while it is on none — then **Back / Forward**, **Go To**, **Find**, **Segments** and **Annotations**, then the one control worth seeing rather than clicking: the **word size**, a menu button that says "2 Bytes". On the right: the difference arrows (or the *Files are identical* badge), the **Help** question mark, which drops down the same starting points as the Help menu, the **pane layout** toggle, whose icon shows the arrangement the click will produce, and the **minimap** toggle. File operations are not there on purpose — dumps arrive by drop, and ⌘S saves them.

### Selection, clipboard, menus

- Mouse selection, ⌘A, **Select Block…** (start + end, or start + length, with **To Beginning** and **To End** for the two bounds you would otherwise look up). **Copy** puts both raw bytes and hex text on the clipboard; ⌘V overwrites bytes from it.
- Right-click an address for **Copy offset** (no `0x`, so a prefixed field doesn't double it), **Select block from here** (prefilled), and the bookmark commands for *that* row. Right-click inside a selection for **Copy**, **Copy to Other Pane**, **Fill Selection with…**, **Delete Bytes** — applied to the clicked pane's selection, not the active pane's.
- The file size in the status bar answers the pointer: putting the pointer on it turns it into the exact count in the Details view's form — `0x200000 (2097152 bytes)` — in place, and a right-click then copies the half the pointer was on — **Copy hex size 200000**, **Copy size 2097152** — because `2 MB` is what a glance wants and not what a clipboard wants. The hex half goes over bare: every offset field in the app takes the `0x` itself. The `OVR`/`INS` indicator sits at the bar's other end, and the size stops short of it. The caret's offset answers a right-click the same way, with **Copy offset** and the digits the bar is drawing — zero-padded hex, no `0x` — rather than an offset read again at click time.
- Every offset field accepts `0x`-hex or decimal, puts the caret behind the prefix instead of selecting the whole text, and validates on each keystroke, with the message under the field it belongs to.

### File types

- **Settings ▸ File Types** registers ByteRipper as the app that opens a dump on a double-click. `.bin` and `.rom` are listed to start with — ticked by you, not by the app — and any extension you keep dumps under can be added: macOS confirms the change once and remembers it. Each row names the app that opens that type *now*, read from the system rather than from anything the app stored, so a default changed in Finder shows here too. `.rom`, `.dump` and `.bin` files get a ByteRipper document icon.

### Help, in three languages

- **Help ▸ ByteRipper Help** (⌘?) opens a help book inside the app: the comparison and its colours, the rules editing follows, each tool and what its rows mean, and a glossary of the words a firmware bench meets before the app ever shows them — `$FPT`, a VSS store, `SVN`, Boot Guard. A field nobody has documented is called unknown there too, and a page says where a claim comes from.
- **A ? beside a form or a panel** opens the page about that very thing; in a firmware panel it opens the term for the row in focus.
- **English, Russian and German.** **Settings ▸ View** follows the Mac or keeps the one you pick — a shop may well run its Macs in German and want its firmware tools in English. The help changes language at once; the menus and windows at the next launch, which the pane offers to do. Terms the trade keeps in English — `$FPT`, `MFS`, `FIT` — stay English in every language.

### Large files, and the rest

- Files are read through a bounded chunk cache and never loaded whole; edits are a piece list over the file as opened, so an inserted byte costs nothing measurable on a 32 MB dump. Diff and search index incrementally in the background, with progress and a cancel button in the status bar.
- **⌘,** opens a standard settings window: the workspace switch and the undo history's bounds, the monospaced font, its size and the row density, the theme (follow the system, or force light or dark), the grouping distance for diff navigation, the text decoding table (Windows-1252 by default) with a live grid of all 256 byte values, the file types the app opens, the pattern library, the language, and the agent service.
- **File ▸ Open Recent** lists the last ten files opened, most recent first; a file that is gone is greyed, and **Clear Menu** empties the list. It is kept on this Mac only. The empty screen shows the same list beside the release notes.
- External changes on disk are detected and offer a reload, keeping local edits; closing a dirty file prompts the standard Save / Don't Save / Cancel.
- Light and dark themes, all colours dynamic; state is carried by colour *and* form (EOF hatching, outline contours), so it survives a theme switch and colour blindness. Accessibility labels on the grid and document state, frame autosave, **Window > Zoom** to fit the content exactly.
- **An empty window signs itself** with the app's name and the build it is, and says when a newer one has been published — one question to this repository's latest release, offered as a link under the line. Asked in the background and silent on every failure: a window waiting for a file has no business reporting on an errand of its own.

## Requirements

- macOS 14.0 or later
- Apple silicon or Intel — the `.dmg` is universal

## Contributing

The app is built with XcodeGen, tested with `Scripts/run-tests.sh`, and put
together as described in [CONTRIBUTING.md](CONTRIBUTING.md) — the build, the
tests, the layers and where the behaviour is written down.
