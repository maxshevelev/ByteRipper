# Projects

> A project is a workspace kept in a file of its own: everything open for one job, opened again as one thing and switched between.

@covers menu.file.save-as-project
@covers menu.file.open-recent-project
@covers menu.file.close-project
@covers code.project-analyses

A project holds what the [[topic:workspace|workspace]] holds — the windows and tabs, the files in them, where each pane was, the bookmarks, the segments, the fragment panels, the tool panels and the Annotations window — every change not yet saved included: untitled documents, changes in parts not yet put back, and the changed bytes of files on disk, which come back red as they were — and the undo history of each document. Unlike the workspace, a project is kept whatever the setting **Reopen the workspace at launch** says.

## Making a project

**File ▸ Save as Project…** writes what is open now into a project file with the extension `.brp` and makes it the open project. From then on the project is written continuously, every few seconds and on every switch: there is no separate command to save it. The name of the project follows each window's title.

The files themselves stay where they are; the project refers to them. It records each path as it is and also relative to the folder the project is in, so a job folder holding the project and its dumps can be moved or copied whole, to another disk or another Mac, and the files are found again.

## Opening and switching

- **File ▸ Open…**, a double-click in the Finder or a drop opens a `.brp` file as a project, not as a dump.
- **File ▸ Open Recent Project** lists the projects opened lately.
- Opening a project replaces everything open. The project being left is kept as it is, unsaved changes included, and nothing is asked.
- When no project is open and something is, opening a project first offers to save the current session as a project. **Don't Save** closes it the ordinary way, asking about unsaved changes.
- **File ▸ Close Project** leaves the project as it is and returns to an empty window.
- Closing the last window of a project — its close button, **File ▸ Close Window** — quits ByteRipper exactly as **⌘Q** does: the project keeps its windows and nothing is asked.

With [[topic:workspace|Reopen the workspace at launch]] on, the project open when ByteRipper was quit is opened again at the next launch.

## What a project file is

A `.brp` file is a package: a folder that the Finder shows and copies as one file. It holds `Project.json` — a few kilobytes describing the windows — and, only while there are any, the bytes nothing else on disk has: untitled documents and unsaved changes. A project without unsaved work stays small. To send a project by mail or message, compress it first with **Compress** in the Finder.

A version of ByteRipper opens the projects that earlier versions saved. A project saved by a newer version is not opened: a message names the reason, and the project stays as it is for that version.

## Files that changed or are missing

A file not found at its path or relative to the project is not opened. A file that changed on disk while the project was closed opens without the project's unsaved changes to it, since those changes were made on other bytes. One message after opening lists both, as it does for the workspace.

## Code analyses in a project

A project also keeps the code analyses its Code panels show, inside the `.brp` package, so they open on another Mac without Ghidra. While the project is open, a new analysis of a module it shows — the module analyzed again, or its review published again — is written into the project too.

On opening, each analysis is added to the ones stored on this Mac — or, when the analyses are kept on an analysis server, to the server's ([[topic:code-analyses|Code Analyses and the Analysis Server]]). One stored here is replaced only by a later revision of the same review; when this Mac holds the later revision, that one is shown. A notice after opening says when an analysis is shown other than as the project saved it, and how many:

- **Another project's analysis is shown instead** — this Mac holds a review of the module made in another Ghidra project. The project's copy is kept aside, not lost.
- **A different stored analysis is shown instead** — this Mac holds another analysis of the module made the same way.
- **Damaged in the project and not read** — the project's copy cannot be read.
