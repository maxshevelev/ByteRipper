# The Workspace

> With the switch on, ByteRipper opens at launch what was open when it was closed.

@covers settings.general.restore-workspace
@covers workspace.restore-warning
@covers workspace.restore-check
@covers workspace.final-write
@covers workspace.newer-version

The switch is **Reopen the workspace at launch** in [[topic:settings|Settings ▸ General]]. It is off after installation: on a repair bench each job is a different board, and dumps from an earlier job opening by themselves would be in the way.

## What is restored

- The windows and their tabs, in their order and at their size and position, with the same tab in front.
- In each tab, File A and File B, the active pane and the position of the divider between them.
- In each pane, the address at the top of the screen, the caret and the selection, the hex or text column, and insert mode.
- The [[topic:bookmarks|bookmarks]] and the [[topic:segments|segments]]: cuts, names, and the links of segments to the files they were joined from.
- The [[topic:fragments|fragment panels]], with the panel that was in front, and parts moved into tabs of their own. A part is not stored as bytes: it is extracted from its file again, so it shows what the file holds now and can still be written back into it, whichever tab or window that file is in.
- **Documents never saved** — New File, a join, a duplicate, including one that has been given a name — with their bytes, still unsaved, and parts with changes not yet put back into their file, with those changes. They are kept beside the workspace while the program runs, so that an abnormal termination does not lose them either, and quitting does not ask about them.
- **Unsaved changes to files on disk**, which come back red as they were, still unsaved. Only the changed bytes are kept beside the workspace, not a copy of the file; like documents never saved, they survive an abnormal termination, and quitting does not ask about them. The changes are laid over the file again only when it is the file they were made on (see below).
- **The undo history** of every document — files on disk, documents never saved, parts — with what can still be redone. After a restart ⌘Z undoes the edits made before it, the cuts of the segments move back with them, undoing a join attaches the document to its file again, and undoing back to the state saved on disk makes a file unmodified. The history keeps to the limits set under [[topic:editing|Editing Bytes]]. The name of a step in the Edit menu stays in the language the program spoke when the edit was made.
- The [[topic:notes|Annotations window]], at its place among the tabs or as a window of its own, with the cards that were selected.
- The [[topic:minimap|minimap]], the Find bar with its pattern, and the tool panel with the node or row selected in it and the open branches of the UEFI tree.

## What is not restored

- The link of a part to its file, when that file is missing or has changed: the part returns with its changes, as a document never saved.
- The Back / Forward history and the results of Search All.
- Settings such as the font, the word size and the pane layout. They are stored separately and apply in any case.

## When the workspace is written

Continuously: every few seconds while the program is in front, when it goes to the background, when a window is closed, and at quit. Closing the last window quits ByteRipper exactly as **⌘Q** does, and the workspace keeps that window. Switching the setting off deletes the stored workspace. The writing goes on in the background and never holds the program up; quitting, and closing or saving a project, go ahead once the workspace is written. Should that take longer than a moment, the window in front shows it meanwhile.

The workspace is stored in `~/Library/Application Support/ByteRipper/Workspace` and does not leave this Mac.

## Files that changed or are missing

At launch, each file is compared with its size and modification date at the time the workspace was written. A file with unsaved changes kept over it is compared by its contents as well (SHA-256): a copy or a backup moves the date of a file without changing a byte, so a file whose date alone has moved keeps its changes, and a file whose bytes differ is a changed file even when its date is the same. Reading a file of several gigabytes takes a few seconds, and so does reading back a long history kept for it; meanwhile its window shows how far the work has got and cannot be edited, since the changes are laid over the file only once it has been checked.

- A file that is no longer at its path is not opened.
- A file that has changed is opened. If it became shorter, the caret and the screen move to its last address, and bookmarks beyond its end are removed. Its unsaved changes, its segments, its parts and the state of its tool panel are not restored: they were made on other bytes and would point to wrong places.

When either happens, one message after the restore lists the files concerned.

The changes ByteRipper keeps beside the workspace are checked the same way. Changes that cannot be read back exactly as they were written — the files beside the workspace were damaged — are not applied: the file opens as it is on disk, a part as its file holds it, and a document with no file is not opened. The message after the restore names them. When the kept history no longer leads back to its beginning, the content comes back as it was but without the steps to undo it, and the message says that too.

## Other versions of ByteRipper

A version of ByteRipper restores the workspace that an earlier version wrote: what is new in it simply starts empty.

A workspace written by a newer version is left untouched — the older version cannot read it, and writing over it would lose that work. At launch a message says so, and until the program is quit it keeps no workspace: it opens with an empty window, and quitting asks about unsaved changes as it does with the switch off. The next launch of the newer version finds its workspace as it was.

## Opening a file from the Finder

When ByteRipper is started by opening a file from the Finder, the workspace is restored first and the file opens in a new tab. A file that is already open in the workspace is not opened a second time: its tab is brought to the front.
