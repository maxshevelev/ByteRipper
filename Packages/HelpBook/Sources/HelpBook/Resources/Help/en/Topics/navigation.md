# Moving Around

> Moving between differences, moving to an address, and selecting a range by number.

@covers menu.edit.select-block
@covers menu.edit.select-all
@covers menu.edit.go-to
@covers menu.view.next-difference
@covers menu.view.previous-difference
@covers menu.view.next-same
@covers menu.view.previous-same
@covers window.go-to-form

## Between differences

- **⌥⌘→** — next difference, **⌥⌘←** — previous difference.
- **⇧⌥⌘→ / ⇧⌥⌘←** — next / previous *matching* block: the start of the next stretch over which the two files agree. This is the complementary movement for an image in which most addresses differ.

For the purpose of this movement a difference is a whole run of differing bytes rather than each byte in it: a differing block of 4 KB is one stop, not four thousand.

## To an address

**⌘L** opens Go To. Type an address and press Return:

- `0x1FE00` — hex, with the `0x` prefix (already in the field).
- `130560` — decimal, without a prefix.

The field retains the last ten addresses entered. Below it is the [[topic:bookmarks|bookmark list]]: Tab moves the keyboard there, and Return jumps to the selected bookmark.

In comparison mode the jump moves **both** panes, which are locked to the same address.

## Selecting a block

**Edit ▸ Select Block…** selects a range by number rather than by dragging: start and end, or start and length. Both fields accept hex with the `0x` prefix and plain decimal. This is how a range whose boundaries were read from a tool panel is selected exactly.

! Ranges inside the program are half-open: the end address is the first byte *not* included in the range. A dialog may accept an inclusive end, and converts it.

## Following the other pane

The two panes are locked together in scroll position, caret and selection. **View ▸ Swap Panels** exchanges the files between the panes.

See also: [[topic:minimap|The Minimap]], for moving by pointing rather than by address.
