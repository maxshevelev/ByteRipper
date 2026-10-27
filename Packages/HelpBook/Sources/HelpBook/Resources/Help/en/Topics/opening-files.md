# Opening Files: One Pane or Two

> A tab holds two file panes. One file is simply an editor; a second file adds the comparison. Editing works in both panes either way.

@covers menu.file.new
@covers menu.file.new-window
@covers menu.file.new-tab
@covers menu.file.open
@covers menu.file.compare-with
@covers menu.file.close
@covers menu.file.close-window

How many of the two panes hold a file decides what the window is:

- **One file open** — single-file mode. The window is a hex editor for that file, and all the editing, searching and tool panels work normally.
- **Two files open** — comparison mode. The two dumps sit side by side (or one above the other, see **View ▸ Toggle Pane Layout**) and every differing byte is painted.

The second pane is optional. Nothing needs a second file except the comparison itself.

## Ways to open a dump

- **File ▸ Open…** (⌘O). The file replaces the **active** pane; it never adds a second pane by itself. Only with both panes empty do the first two files you pick fill them. Anything selected beyond that is not opened.
- **File ▸ Compare with…** (⌥⌘O) opens the file in the other pane: the free one, or otherwise the one that is not active. This is how a second file is added for comparison. In **File ▸ Open Recent**, hold ⌥ and the row becomes the same command.
- **Drag and drop.** Drag a file onto the window and the drop bands show where it can land — replace this pane, join it at either end, open it for comparison, or open it in a new tab. While the file is over the window every band is shown, semi-transparent; the one under the pointer is highlighted, and that is where the file goes when it is released. Drop two files at once and the second opens in the other pane, if that pane is free.
- **File ▸ Open Recent** — the dumps you had open lately.
- **From Finder**, if ByteRipper is set as the handler for the extension (see [[topic:settings|Settings]]).
- **File ▸ New File** (⌘N) makes an empty untitled file — somewhere to paste bytes into.

## Panes, tabs and windows

Each pane header names its file and whether it has unsaved changes; the status bar below it gives the size. The ✕ in the header closes that pane and leaves the other one open. Closing the last file of a tab closes the tab as well, when other tabs are open and the tab holds no [[topic:bookmarks|bookmarks]] and no [[topic:fragments|fragment panels]]; the last tab in the program stays open, empty.

A window can hold several tabs (**File ▸ New Tab**, ⌘T), each with its own pair of panes to compare in. Several unrelated comparisons are therefore held in one window: BIOS dumps in one tab, embedded-controller dumps in the next.

## If the file is already open

A file is open in one place at a time, and the program enforces this:

- **In the other pane of this tab** — it refuses and states the reason. The same file cannot occupy both panes, so a file cannot be compared with itself. Unsaved edits to a file are already distinguished by their red colour; where two copies side by side are required, **File ▸ Duplicate** produces one.
- **In another tab or window** — it offers a choice: show the file where it is open, or move that pane into this tab.
- **In this same pane** — it re-reads the file from disk. Where the pane holds unsaved edits it asks first, because re-reading discards them.

! Replacing the file in a pane that holds unsaved edits asks for confirmation. A discarded pane cannot be restored.

See also: [[topic:join-duplicate|Joining and Duplicating]], [[topic:large-files|Large Dumps]].
