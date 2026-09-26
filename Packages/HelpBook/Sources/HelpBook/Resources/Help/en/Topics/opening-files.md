# Opening Files: One Pane or Two

> A tab holds two file panes. One file is simply an editor; a second file adds the comparison. Editing works in both panes either way.

@covers menu.file.new
@covers menu.file.new-window
@covers menu.file.new-tab
@covers menu.file.open
@covers menu.file.close
@covers menu.file.close-window

How many of the two panes hold a file decides what the window is:

- **One file open** — single-file mode. The window is a hex editor for that file, and all the editing, searching and tool panels work normally.
- **Two files open** — comparison mode. The two dumps sit side by side (or one above the other, see **View ▸ Toggle Pane Layout**) and every differing byte is painted.

The second pane is optional. Nothing needs a second file except the comparison itself.

## Ways to open a dump

- **File ▸ Open…** (⌘O). If both panes hold a file, the app asks which one to replace.
- **Drag and drop.** Drag a file onto the window and the drop bands show where it will land — replace this pane, open beside it, or open in a new tab. Dropping two files at once fills both panes.
- **File ▸ Open Recent** — the dumps you had open lately.
- **From Finder**, if ByteRipper is set as the handler for the extension (see [[topic:settings|Settings]]).
- **File ▸ New File** (⌘N) makes an empty untitled file — somewhere to paste bytes into.

## Panes, tabs and windows

Each pane header names its file and whether it has unsaved changes; the status bar below it gives the size. The ✕ in the header closes that pane and leaves the other one open.

A window can hold several tabs (**File ▸ New Tab**, ⌘T), each with its own pair of panes. That is how several boards are kept apart on one screen: one tab per job.

## If the file is already open

A file is open in one place at a time, and the app holds to that:

- **In the other pane of this tab** — it refuses and says so. The same dump cannot sit in both panes, so a file cannot be compared with itself.
- **In another tab or window** — it offers a choice: show the file where it is, or move that pane into this tab.
- **In this very pane** — it re-reads the file from disk. With unsaved edits it asks first, because re-reading discards them.

! Replacing a pane that has unsaved edits asks first. There is no undo for a discarded pane.

See also: [[topic:join-duplicate|Joining and duplicating]], [[topic:large-files|Large dumps]].
