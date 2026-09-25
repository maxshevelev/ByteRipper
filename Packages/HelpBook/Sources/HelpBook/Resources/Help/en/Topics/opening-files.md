# Opening Files: A and B

> The window has two slots. One file is simply an editor; a second file adds the comparison. Editing works in both panes either way.

@covers menu.file.new
@covers menu.file.new-window
@covers menu.file.new-tab
@covers menu.file.open
@covers menu.file.close
@covers menu.file.close-window

The window holds two file slots, **File A** and **File B**. Which slot a file lands in decides what happens:

- **One file open** — single-file mode. The window is a hex editor for that file, and all the editing, searching and firmware panels work normally.
- **Two files open** — comparison mode. The two dumps sit side by side (or one above the other, see **View ▸ Toggle Pane Layout**) and every differing byte is painted.

File B is optional. Nothing needs a second file except the comparison itself.

## Ways to open a dump

- **File ▸ Open…** (⌘O). If both slots are full, the app asks which one to replace.
- **Drag and drop.** Drag a file onto the window and the drop bands show where it will land — replace this pane, open beside it, or open in a new tab. Dropping two files at once fills both slots.
- **File ▸ Open Recent** — the dumps you had open lately.
- **From Finder**, if ByteRipper is set as the handler for the extension (see [[topic:settings|Settings]]).
- **File ▸ New File** (⌘N) makes an empty untitled file — somewhere to paste bytes into.

## Panes, tabs and windows

Each pane header names its file, its size and whether it has unsaved changes. The ✕ in the header closes that pane and leaves the other one open.

A window can hold several tabs (**File ▸ New Tab**, ⌘T), each with its own pair of slots. That is how several boards are kept apart on one screen: one tab per job.

## If the file is already open

Opening a file that is already in the other slot is allowed — comparing a file with itself is a legitimate thing to do while editing one copy of it. Opening it into the slot it is already in does nothing.

! Replacing a pane that has unsaved edits asks first. There is no undo for a discarded pane.

See also: [[topic:join-duplicate|Joining and duplicating]], [[topic:large-files|Large dumps]].
