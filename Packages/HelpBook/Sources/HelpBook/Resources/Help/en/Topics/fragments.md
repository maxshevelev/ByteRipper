# Fragment Panels: A Part of a Dump

> Extracting one part of an image, working on it as a separate file, and writing it back.

@covers window.fragments

A part of an image supplied by a [[topic:tools-overview|tool panel]] — a region, a volume, a module, the decompressed body of a section — opens as a **fragment panel**: a panel that rises from the bottom of the window, over the dump it was taken from.

The parent remains visible above it. Folded down, the fragment becomes a pill in the dock along the bottom edge of the window. One dock serves the tab: it holds the parts extracted from both open images.

## What a fragment supports

- Reading and searching as an ordinary file, with its own addresses beginning at zero rather than at the address it occupies in the parent.
- Editing.
- **File ▸ Update in Parent**, which writes the edited bytes back into the range they came from as a single undo step in the parent document.
- Saving to disk as a file of its own, where the extracted part is what is required rather than an edited parent.

## When putting it back is refused

Update in Parent verifies the following before writing, and states which condition it failed on:

- **The parent is closed**, or that pane now holds another file. The link is to the open document and not to a path on disk, and it is not recorded anywhere.
- **The parent is read-only.**
- **The length changed.** A copied part is written back at exactly its own length; the bytes following it in the image are not the fragment's to move. An edit that changed the length is therefore refused.
- **The source changed** after the part was opened. This is a confirmation rather than a refusal: the program asks before overwriting.

## Decompressed parts

A compressed UEFI section can be opened *decompressed*. What is then displayed is not the bytes held in the file but what those bytes expand to. Once edited and written back it is compressed again and the image is laid out around the resulting size. The result is not byte-identical to the manufacturer's original even when nothing has been changed, a different compressor producing different output from the same input.

See also: [[topic:saving|Saving]], [[topic:bench-safety|Constraints on Editing an Image]].
