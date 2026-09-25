# Fragment Panels: A Part of a Dump

> Pull one piece out of an image, work on it as its own file, and put it back.

@covers window.fragments

When a [[topic:tools-overview|firmware panel]] hands you a part of the image — a region, a volume, one module, the decompressed body of a section — it opens as a **fragment panel**: a panel that rises from the bottom of the window, over the dump it came out of.

The parent stays visible above it. Folded down, the fragment becomes a pill in the dock along the window's bottom edge, so the pills in that dock are the parts you have pulled out of *this* image.

## What you can do with a part

- Read it and search it as an ordinary file, with its own addresses starting at zero — which is much easier than counting offsets inside the parent.
- Edit it.
- **File ▸ Update in Parent** writes the edited bytes back into the range they came from, as a single undo step in the parent document. Fold the panel down and the change is right there in the dump behind it.
- Save it to disk as a file of its own, if what you need is the extracted part rather than a patched parent.

## When putting it back is refused

Update in Parent checks before it writes, and says why when it will not:

- **The parent is closed**, or that pane holds another file now. The link is to the open document, not to a path on disk, and it is never written down.
- **The parent is read-only.**
- **The length changed.** A plain copied part goes back at exactly its own length: the bytes after it in the image are not the part's to move. If your edit changed the size, you are no longer patching that part — you are rebuilding the image around it.
- **The source changed under you** since the part was opened. That one is a confirmation, not a refusal: it asks before overwriting.

## Decompressed parts

A compressed UEFI section can be opened *decompressed*. What you then see is not the bytes of the file — it is what those bytes expand to. Edited and put back, it is compressed again and the image is laid out around the new size. Expect the result not to be byte-identical to the vendor's original even if you change nothing: a different compressor makes different output from the same input.

See also: [[topic:saving|Saving]], [[topic:bench-safety|Bench rules]].
