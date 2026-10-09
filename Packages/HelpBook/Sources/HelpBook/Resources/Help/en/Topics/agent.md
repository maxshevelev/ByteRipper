# Working with an Agent

> An agent — Claude Code, Claude Desktop or another program that speaks MCP — can be connected to ByteRipper. It then sees the files open in the program, reads their bytes and shows places in them, while the conversation with it goes on in its own window.

@covers settings.agent
@covers window.agent
@covers window.agent.details
@covers toolbar.agent
@covers menu.window.agent
@covers menubar.agent
@covers settings.agent.edits

The agent works on the same windows as the person at the bench. When it is asked about "this" byte, it reads the position of the caret and the selection; when it refers to a place in the dump, it moves the view there and selects it. The two therefore point at the same bytes rather than describing addresses to each other in words.

## Switching the service on

The service is off after installation. It is switched on in **Settings ▸ Agent** with **Let agents connect to ByteRipper**. While it is on, a mark is shown in the menu bar at the top of the screen; the mark is filled while an agent is connected.

The connection is local. ByteRipper opens a file in the user's Library through which only programs of the same user account can reach it; there is no network port.

The bytes an agent reads are, however, passed by the agent's own program to the model behind it. For Claude that is Anthropic's service. A dump that must not leave the workshop is not to be opened while an agent is connected.

## Connecting a program

In **Settings ▸ Agent** the menu **Configuration for:** chooses the program the agent runs in. The text that program needs is shown in full below the menu, with a line saying where it goes, and **Copy** puts it on the clipboard:

- **Claude Code** — a command for Terminal. Run once, it registers ByteRipper with Claude Code for every folder.
- **Claude Desktop** — a JSON block for Claude Desktop's configuration file, `~/Library/Application Support/Claude/claude_desktop_config.json`. Claude Desktop reads it when it starts.
- **Cursor** — the same JSON block, for `~/.cursor/mcp.json` (every project) or `.cursor/mcp.json` inside one project.
- **Other Client** — the parameters one by one: the name `byteripper`, the transport `stdio`, the command, and no arguments or environment variables. This is what a client asks for in a form of its own.

A configuration file that already lists other servers takes the `byteripper` entry beside them, inside the same `mcpServers`.

Every form names the helper program inside this copy of ByteRipper. If ByteRipper is moved to another folder, the text is copied again.

If ByteRipper is not running when the agent's program starts, the helper starts it. If the service is switched off, the agent's program reports that ByteRipper's agent service is not running.

## What an agent can do

At present an agent can:

- list the open files, with their names, sizes and whether they have unsaved edits;
- read the position of the caret, the selection and the rows on screen;
- read bytes — as hex rows, as text, or as 16-, 32- and 64-bit numbers — including unsaved edits;
- show a place: bring its tab forward, scroll to it and select it;
- read the structure of a firmware image as **UEFI Structure** shows it — the tree, the fields of a node, the nodes holding an address — and search it by name, GUID or type. This works whether or not the panel is open;
- read the FIT table as **FIT Table** shows it — its rows, what each points at, the rules it breaks — and the Intel ME firmware as **ME Analyzer** shows it: the summary and the decoded structure. This too works with the panels closed;
- list the NVRAM variables of a dump with their values, read as their types, and set the variables of two dumps side by side by name and GUID: which only one of them has, which differ and in which bytes. Two dumps of different boards or BIOS versions compare as well as two of one board, and a folder of dumps can be compared with one of them at once;
- set the files of the ME file systems (MFS and EFS) of two dumps side by side by their number in the volume and by content, not by address: which are the same, which differ and in how many bytes, which only one dump has. The volume moves its data to spread the wear on the chip, so in two dumps of one machine the same file can lie at different addresses; a byte comparison of the partition then shows moved data, while this comparison shows which files changed. The Integrity table at the end of a protected file is compared separately: it changes every time the engine writes the file again. A volume one of the dumps cannot be read in is named as not compared, and its files are not counted as missing;
- mark bytes while explaining them: a dashed outline in a colour of its own, with a short label; resting the pointer on the marked bytes shows the agent's note. A mark can name others it is about — a pointer and its target, a checksum and what it covers;
- open a file by its path without putting it on screen, and ask the same question of every dump in a folder at once — how many copies of a variable each holds, which address a structure starts at — getting the answers grouped by value. A file opened this way is only read; the agent puts it in a tab of its own when there is something in it to show;
- record findings: each a sentence and the place it is about, listed in the Agent window;
- compare two files byte by byte, as the comparison of two panes does — at the same addresses, without aligning shifted data. The answer is either a list of the stretches that differ, each with the part of the firmware it lies in (a region, a volume, a variable, an ME partition or file), or a summary over the regions, volumes and ME partitions that names the unchanged ones too. A folder of dumps can be compared with one of them at once;
- show two files side by side as a pair in a new tab — or beside a file that is alone in its tab — and step through their differences as the difference arrows of the window do;
- open a tool panel on a document, as the **Tools** menu does, and choose a node in the open **UEFI Structure** panel. The tree opens down to the node and the dump scrolls to its bytes.

Each place an agent shows, each panel it opens and each node it chooses is a step of the navigation history: **View ▸ Back** (**⌘[**) returns to the place the view was at before ([[topic:navigation|Moving Around]]).

An agent cannot save a file, and changes one only when that is allowed (below). Addresses in its answers are given in hex, as in the dump.

## Letting an agent edit

**Let agents edit open files** in **Settings ▸ Agent** is off after installation, and is separate from the switch that lets agents connect. While it is off, an agent asked to change something says what it would change instead.

While it is on, an agent can:

- overwrite bytes in a file open in a tab. A write replaces as many bytes as it carries and never inserts or deletes; it can be made conditional on the bytes that are there now;
- put a checksum right — a volume's, a file's or a microcode's in **UEFI Structure**, the table's in **FIT Table** — computed by the same code as the panels' **Fix Checksum**.

Each change is one step of the file's undo, named **Agent:** and what the agent said the change is, so **Edit ▸ Undo** (**⌘Z**) takes it back. The changed bytes are red until the file is saved, like an edit made by hand, and the dump scrolls to them as a step of the navigation history. The file is saved only by the person. A file opened read-only, and a file the agent opened by its path without a tab, are never changed.

## The Agent window

**Window ▸ Agent** shows whether the service is running, and has three lists. While the service is switched on, the toolbar has a button for it between **?** and the pane arrangement, with the icon of the Agent tab in Settings; it opens the window, or brings it to the front when it is open already.

**Log** lists every request the agent has made: the time, the tool, the arguments as the agent wrote them, how long the answer took, its size and the result. A refused request is shown in red, with the reason the agent was given. The table shortens long arguments; the list under it shows the selected request whole: the time, the client, how long the answer took, its size in bytes, the full result and, under **Arguments**, the whole JSON the agent sent, one member to a line. Its text can be selected and copied. **Space** on the log, or the button in the list's corner, opens the list large over the window, as a tool panel's details open; **Space** or **Esc** closes it. **Clear Log** empties the list; the list is not kept after the program quits.

**Marks** lists the marks the agent has left in every open file: the label, the file, the bytes, the note, and the marks it is about. A double-click on a row brings its file forward and selects its bytes, as a step of the navigation history. **Remove Mark** removes the selected rows, **Clear Marks** removes them all. A mark also goes when its file is closed or when the agent removes it.

**Findings** lists what the agent found and where: the sentence, the file, the bytes or the node. A double-click opens the file at that place — in the tab that already has it, or in a new one. **Clear Findings** empties the list.

## Files outside the open windows

When the agent first reads a folder that macOS protects — Desktop, Documents, Downloads — macOS asks whether ByteRipper may access it. The agent's request waits for the answer; the rest of the program does not. The answer is remembered for ByteRipper, as for any other access the program asks for.

## When the service does not start

The status line in **Settings ▸ Agent** gives the reason. The usual one is a second copy of ByteRipper already running with the service switched on: only one copy can serve agents at a time, and the second leaves the first one's connection alone.
