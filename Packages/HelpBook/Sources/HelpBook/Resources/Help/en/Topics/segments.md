# Segments: Cutting a Dump into Pieces

> Marking the internal boundaries of an image, and saving each piece as a separate file.

@covers menu.edit.add-cut
@covers menu.edit.merge
@covers menu.edit.segments
@covers window.segments-form

A segmentation splits the pane's file into **pieces**: contiguous, never overlapping, always covering the whole file. Every open file starts as one piece — itself.

Nothing about a segment changes the bytes. It is a way of *reading* a file; the only thing that writes is the explicit save.

## Making a cut

- Right-click in the dump and choose **Split Here at «address»**, which cuts at the caret.
- **Edit ▸ Add Cut…** takes the address as a number instead.
- **Edit ▸ Merge** removes the cut before the piece the caret is in, joining it to its neighbour.
- **Edit ▸ Segments…** (⌥⌘S) opens the list: every piece, its range, its name, and the buttons that act on all of them.

Pieces are labelled **S0, S1, S2 …** in file order and are renumbered automatically when a cut is added or removed. A name given to a piece stays with that piece regardless of its number.

## Saving the pieces

The Segments form holds **Save All as Separate Files…**, which writes every piece at once. Together with [[topic:join-duplicate|Append File…]] this covers a board whose firmware is held in two SPI chips:

1. The two chips are read, producing two files.
2. One is opened and the other appended to it, so that the whole of the firmware is one image.
3. The image is compared, searched, edited and decoded as a single file by the [[topic:tool-uefi|UEFI panel]], which expects one contiguous image.
4. The boundary at which the two files met is already a cut, so **Save All as Separate Files** returns the two halves at exactly that boundary.

! A cut travels with the bytes: data inserted before it moves it. A [[topic:bookmarks|bookmark]] behaves in the opposite way and stays at its address. A cut denotes the boundary of an area; a bookmark denotes an address.

Segments live as long as the file is open.
