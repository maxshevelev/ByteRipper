# Saving

> Red text means the change exists only here. Save, and it is in the file.

@covers menu.file.save
@covers menu.file.save-as
@covers menu.file.revert
@covers menu.file.update-in-parent

- **⌘S — Save.** Writes the pane's document back to its file. An untitled document opens a save panel instead.
- **⇧⌘S — Save As…** Writes it somewhere new, and the pane follows the new file.
- **File ▸ Revert to Saved** throws your edits away and re-reads the file from disk.
- **File ▸ Update in Parent** is the third destination: for a [[topic:fragments|fragment panel]], it writes the part back into the image it came out of instead of to a file.

## What is unsaved

Bytes you have changed are drawn in **red** until they are saved, and the pane header says the document is modified. That pair is the check to run before handing a file to a programmer: no red left, and the header clean.

## When the file changes underneath you

ByteRipper watches the file it opened. If something else rewrites it — your programmer software re-reading the chip into the same path, for instance — the app notices and tells you, rather than silently saving over the new contents later.

## Documents with no file

Some documents are deliberately untitled and have no path, so ⌘S asks where to put them:

- **File ▸ New File** (⌘N).
- The result of a [[topic:join-duplicate|join]]: joining two dumps makes a *new* image, and an accidental ⌘S must not write it over one of the halves.
- The result of **Duplicate**.
- A part opened out of an image.

! Keep the original dump. Save your patched version under a new name — `board_patched.bin` beside `board_original.bin`. A dump you overwrote is a chip you have to read again, and on a board with a dead power rail that may not be possible twice.
