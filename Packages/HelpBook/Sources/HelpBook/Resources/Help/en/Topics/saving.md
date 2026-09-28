# Saving

> Red marks a byte that differs from the file on disk. Saving writes those bytes to the file, and the red is removed.

@covers menu.file.save
@covers menu.file.save-as
@covers menu.file.revert
@covers menu.file.update-in-parent

- **⌘S — Save.** Writes the pane's document back to its file. An untitled document opens a save panel instead, so that a name can be chosen.
- **⇧⌘S — Save As…** Writes it somewhere new, and the pane follows the new file.
- **File ▸ Revert to Saved** discards the edits and re-reads the file from disk.
- **File ▸ Update in Parent** is the third destination: for a [[topic:fragments|fragment panel]], it writes the part back into the image it came out of instead of to a file.

## What is unsaved

Edited bytes are drawn in **red** until they are saved, and the pane header reports the document as modified. Both indications are cleared by saving.

## When the file changes underneath you

ByteRipper watches the file it has opened. Where another program rewrites it — programmer software re-reading a chip into the same path, for example — this is detected and reported, rather than the new content being overwritten silently by a later save.

## Documents with no file

Some documents have neither a name nor a path by design, and ⌘S therefore asks where to write them:

- **File ▸ New File** (⌘N).
- The result of a [[topic:join-duplicate|join]]: joining two dumps produces a *new* image, which ⌘S must not write over either half.
- The result of **Duplicate**.
- A part extracted from an image.

! **Save As…** writes the edited image to a new file and leaves the file it was read from unchanged. The original dump is not recoverable from the program once it has been overwritten.
