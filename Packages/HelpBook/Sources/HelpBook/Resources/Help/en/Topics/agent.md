# Working with an Agent

> An agent — Claude Code, Claude Desktop or another program that speaks MCP — can be connected to ByteRipper. It then sees the files open in the program, reads their bytes and shows places in them, while the conversation with it goes on in its own window.

@covers settings.agent
@covers window.agent
@covers window.agent.details
@covers toolbar.agent
@covers window.agent.follow
@covers window.agent.tools
@covers agent.node-link
@covers menu.window.agent
@covers menubar.agent
@covers settings.agent.edits
@covers settings.agent.launch

The agent works on the same windows as the user. When it is asked about "this" byte, it reads the position of the caret and the selection; when it refers to a place in the dump, it moves the view there and selects it. The two therefore point at the same bytes rather than describing addresses to each other in words.

## Switching the service on

The service is off after installation. It is switched on in **Settings ▸ Agent** with **Let agents connect to ByteRipper**. While it is on, a mark of three joined points is shown in the menu bar at the top of the screen: dimmed while the service waits, and with the points filled while an agent is connected. The Agent button in the window's toolbar fills its points the same way, which matters on a Mac whose camera notch hides the right-hand part of a crowded menu bar.

The connection is local. ByteRipper opens a file in the user's Library through which only programs of the same user account can reach it; there is no network port.

The bytes an agent reads are, however, passed by the agent's own program to the model behind it. For Claude that is Anthropic's service. A dump that must not leave the workshop is not to be opened while an agent is connected.

## Connecting a program

In **Settings ▸ Agent** the menu **Configuration for:** chooses the program the agent runs in. The text that program needs is shown in full below the menu, with a line saying where it goes, and **Copy** puts it on the clipboard:

- **Claude Code** — a command for Terminal. Run once, it registers ByteRipper with Claude Code for every folder.
- **Claude Desktop** — a JSON block for Claude Desktop's configuration file, `~/Library/Application Support/Claude/claude_desktop_config.json`. Claude Desktop reads it when it starts.
- **Cursor** — the same JSON block, for `~/.cursor/mcp.json` (every project) or `.cursor/mcp.json` inside one project.
- **Other Client** — the parameters one by one: the name `byteripper`, the transport `stdio`, the command, no arguments, and the environment variable `BYTERIPPER_LAUNCH=1` only when ByteRipper is to be started (below). This is what a client asks for in a form of its own.

A configuration file that already lists other servers takes the `byteripper` entry beside them, inside the same `mcpServers`.

Every form names one and the same helper: the copy of it ByteRipper keeps for itself in the user's Library, beside the file the connection runs through, and brings up to date each time it starts. Moving ByteRipper to another folder, or building it again, therefore leaves the configuration alone — it is made once.

The helper does not start ByteRipper by itself: the agent reaches ByteRipper while it is open with the service switched on, and otherwise the agent's request is answered that ByteRipper or its agent service is not running. It outlives ByteRipper: closing and opening the program in the middle of a conversation does not disconnect the agent's program, and the requests go through again once ByteRipper is open — nothing has to be registered a second time. A program that restarts its servers would otherwise open ByteRipper again as soon as it is quit. To have the agent's program start ByteRipper when it is needed, turn on **Start ByteRipper when an agent connects** in **Settings ▸ Agent**: the text below the menu then carries the variable `BYTERIPPER_LAUNCH=1`, and is copied into the program again. Turned off and copied again, it stops starting ByteRipper. If the service is switched off, the agent's program reports that ByteRipper's agent service is not running either way.

## Why not over HTTP

Some programs, Claude Desktop among them, add a server reached over HTTP from their own settings, without a configuration file and without a restart. ByteRipper does not offer such a server, on purpose:

- A server over HTTP listens on a network port, and every program on the computer can reach it — web pages open in a browser included. It would need a password of its own, kept in the agent's configuration, and checks against requests from pages. The file ByteRipper opens in the user's Library can be reached only by programs of the same user account; there is nothing to set up and nothing to leak.
- An agent reads dumps and, when allowed, changes them. Access to it is therefore no wider than access to the dumps themselves.
- The agent's program starts the helper itself. The helper starts ByteRipper when it is not running and says so when the service is switched off; a server over HTTP is simply not there in either case.

The price is the configuration step described above, made once per program, and a connection from the same computer only: an agent running on another computer cannot connect.

## What an agent can do

At present an agent can:

- list the open files, with their names, sizes and whether they have unsaved edits;
- read the position of the caret, the selection and the rows on screen;
- read bytes — as hex rows, as text, or as 16-, 32- and 64-bit numbers — including unsaved edits;
- show a place: bring its tab forward, scroll to it and select it;
- read the structure of a firmware image as **UEFI Structure** shows it — the tree, the fields of a node, the nodes holding an address — and search it by name, GUID or type; the fields of a node are the panel's details, the name the GUID catalogue gives a file included. It can also check every checksum of the image at once — a volume's, a file's, a microcode's, a PSP directory's — and list the wrong ones with the value each should have, as the panel's red marks do. This works whether or not the panel is open;
- read the FIT table as **FIT Table** shows it — its rows, what each points at, the rules it breaks — and the Intel ME firmware as **ME Analyzer** shows it: the summary and the decoded structure. This too works with the panels closed;
- list the NVRAM variables of a dump with their values, read as their types, and set the variables of two dumps side by side by name and GUID: which only one of them has, which differ and in which bytes. Two dumps of different boards or BIOS versions compare as well as two of one board, and a folder of dumps can be compared with one of them at once;
- set the files of the ME file systems (MFS and EFS) of two dumps side by side by their number in the volume and by content, not by address: which are the same, which differ and in how many bytes, which only one dump has. The volume moves its data to spread the wear on the chip, so in two dumps of one machine the same file can lie at different addresses; a byte comparison of the partition then shows moved data, while this comparison shows which files changed. The Integrity table at the end of a protected file is compared separately: it changes every time the engine writes the file again. A volume one of the dumps cannot be read in is named as not compared, and its files are not counted as missing;
- annotate a place in a file: a short title and a note — what the bytes are while it explains them, or what it found there. An annotation is drawn over the bytes whenever its file is on screen, in a tab or in a part that keeps the file's addresses: a dashed outline in a colour of its own, the note when the pointer rests on the bytes. It belongs to the file, not to the window: it is kept when the file closes and drawn again when the file is opened, and the agent can annotate a file that is not open — on each file of a folder that matches what it was asked. A place in bytes that are not the file's own — what a compressed section decompresses to, a LENV block with its encoding removed — is kept in those bytes: it is drawn in the fragment panel that shows them, not over the whole section in the dump. An annotation can name others it is about — a pointer and its target, a checksum and what it covers; those are listed after the note, under **Related Annotations:**, by their number and title. The annotations are listed in the **Annotations** window, beside those made by hand ([[topic:notes|Annotations]]);
- open a file by its path without putting it on screen, and ask the same question of every dump in a folder at once — how many copies of a variable each holds, which address a structure starts at — getting the answers grouped by value. A file opened this way is only read; the agent puts it in a tab of its own when there is something in it to show;
- compare two files byte by byte, as the comparison of two panes does — at the same addresses, without aligning shifted data. The answer is either a list of the stretches that differ, each with the part of the firmware it lies in (a region, a volume, a variable, an ME partition or file), or a summary over the regions, volumes and ME partitions that names the unchanged ones too. A folder of dumps can be compared with one of them at once;
- find a text or bytes in a file — as ASCII or UTF-16, in any case, with `??` for a byte that may be anything — including inside the compressed sections of a firmware image, which the file holds only compressed; each match with the part of the firmware it lies in;
- find who in a firmware image refers to an address or a GUID — the modules whose code holds it, in the file and inside compressed sections — listed by FFS file. An address is looked for as the processor sees the BIOS region below 4 GiB, as a file address and as an offset in the BIOS region; a match of four bytes in code can be chance, so each says which of these forms it is;
- judge the areas the parser cannot name — padding, unused and unknown areas of the flash map, raw files — by their bytes: empty, text, data or code, with a few of the strings in them. An area the flash map names MSDM, Password or Key is judged without its strings, and a search shows no bytes around a match in it;
- read the bytes of a node of **UEFI Structure**, a node inside a compressed section included, and open a stretch of a file or a node as a part over the file, as **Open Zone** does, so two blocks at different addresses are compared from their beginnings;
- show two files side by side as a pair in a new tab — or beside a file that is alone in its tab — and step through their differences as the difference arrows of the window do;
- open a tool panel on a document, as the **Tools** menu does, and choose a node in the open **UEFI Structure** panel. The tree opens down to the node and the dump scrolls to its bytes.

Each place an agent shows, each panel it opens and each node it chooses is a step of the navigation history: **View ▸ Back** (**⌘[**) returns to the place the view was at before ([[topic:navigation|Moving Around]]).

An agent cannot save a file, and changes one only when that is allowed (below). Addresses in its answers are given in hex, as in the dump.

## Letting an agent edit

**Let agents edit open files** in **Settings ▸ Agent** is off after installation, and is separate from the switch that lets agents connect. While it is off, an agent asked to change something says what it would change instead.

While it is on, an agent can:

- overwrite bytes in a file open in a tab. A write replaces as many bytes as it carries and never inserts or deletes; it can be made conditional on the bytes that are there now;
- copy a stretch of one of a tab's two files over the same addresses in the other, as **Edit ▸ Copy to Other Pane** does with the selection. The bytes pass from file to file inside ByteRipper and not through the agent, so a whole region is copied at once; the answer says how many bytes actually changed. A copy past the end of the other file is refused, as is a copy into a file opened read-only;
- put a checksum right — a volume's, a file's, a microcode's or a PSP directory's in **UEFI Structure**, the table's in **FIT Table** — computed by the same code as the panels' **Fix Checksum**. In **UEFI Structure** the agent can put every wrong checksum right at once, as one undo step; a file that holds a volume is put right after the files inside it. A checksum inside a compressed section is not changed: the file holds those bytes compressed;
- add, update, replace and remove microcode in the FIT from the same online catalogue **FIT Table** offers, with the same checks: an update already in the table under another of its CPUIDs is refused, an update whose extended signature table serves a processor a row already serves takes that row's place, and a replacement that would leave two microcodes for one processor is refused naming the row to replace. The agent can also say which of the image's microcodes the catalogue has a newer revision for.

Each change is one step of the file's undo, named **Agent:** and what the agent said the change is, so **Edit ▸ Undo** (**⌘Z**) takes it back. The changed bytes are red until the file is saved, like an edit made by hand, and the dump scrolls to them as a step of the navigation history. The file is saved only by the person. A file opened read-only, and a file the agent opened by its path without a tab, are never changed.

## Links to files and nodes

The agent names a file by its name — with its folder, when two open files have the same name — and writes it as a link that brings the file forward in ByteRipper, or opens it.

When the agent names a node of a firmware image's structure, it calls it as **UEFI Structure** does — by its name, and by its addresses as well where the name only says what kind of area it is, such as **Unused** or **Padding** — and writes it as a link. A click on the link, in a program that opens such links, brings the file forward in ByteRipper or opens it, opens **UEFI Structure** and chooses the node; **View ▸ Back** (**⌘[**) returns. If the file has been moved, deleted or changed since, ByteRipper says so. Whether a link can be clicked depends on the agent's program and, for Claude Code, on the terminal it runs in.

## The Agent window

**Window ▸ Agent** shows whether the service is running, and has two lists. While the service is switched on, the toolbar has a button for it between **?** and the pane arrangement, with the icon of the Agent tab in Settings; it opens the window, or brings it to the front when it is open already. The keyboard is then on the list of the page shown, and the arrow keys move through its rows; choosing another page moves the keyboard to that page's list.

**Log** lists every request the agent has made, a request the tool is still working on included: it appears when it arrives, with **Running…** as its result, and the same row is completed when the answer is ready. For each, the time, the tool, the arguments as the agent wrote them, how long the answer took, its size and the result. A refused request is shown in red, with the reason the agent was given. The table shortens long arguments; the list under it shows the selected request whole: the time, the client, how long the answer took, its size in bytes, the full result and, under **Arguments**, the whole JSON the agent sent, one member to a line. Its text can be selected and copied. **Space** on the log, or the button in the list's corner, opens the list large over the window, as a tool panel's details open; **Space** or **Esc** closes it. **Follow New Requests** below the log scrolls it to each new request as it arrives; while it is off, the log stays where it was left. The selected request stays selected as new ones arrive. **Clear Log** empties the list; the list is not kept after the program quits.

The agent's annotations are not listed in this window: the **Annotations** window lists them, in violet and with the agent's icon, beside the annotations made by hand ([[topic:notes|Annotations]]).

**Tools** lists every tool an agent is offered, in sections headed by where the tools come from — a part of ByteRipper, or a panel such as **UEFI Structure** — with each tool's name and kind: **Read** changes nothing, **On Screen** changes what the window shows (the view, a mark, a finding, a tab), **Edits a File** writes into an open file. Beside each, how it has been used since ByteRipper started: the calls, those **Not Answered**, the average time, the size of its answers and the last call. The list under it shows the selected tool as the agent is told about it: the **Description** and, under **Arguments**, the arguments it takes as a JSON schema, both in English, as the agent reads them. **Reset Statistics** sets the counts back to zero; they are not kept after the program quits.

## Files outside the open windows

When the agent first reads a folder that macOS protects — Desktop, Documents, Downloads — macOS asks whether ByteRipper may access it. The agent's request waits for the answer; the rest of the program does not. The answer is remembered for ByteRipper, as for any other access the program asks for.

## When the service does not start

The status line in **Settings ▸ Agent** gives the reason. The usual one is a second copy of ByteRipper already running with the service switched on: only one copy can serve agents at a time, and the second leaves the first one's connection alone.
