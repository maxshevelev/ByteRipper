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
@covers editing.address-arithmetic
@covers menu.view.back
@covers menu.view.forward
@covers toolbar.history

## Between differences

- **⌥⌘→** — next difference, **⌥⌘←** — previous difference.
- **⇧⌥⌘→ / ⇧⌥⌘←** — next / previous *matching* block: the start of the next stretch over which the two files agree. This is the complementary movement for an image in which most addresses differ.

For the purpose of this movement a difference is a whole run of differing bytes rather than each byte in it: a differing block of 4 KB is one stop, not four thousand.

## To an address

**⌘L** opens Go To. Type an address and press Return:

- `0x1FE00` — hex, with the `0x` prefix (already in the field).
- `130560` — decimal, without a prefix.

The field retains the last ten entries, sums included (see below). Below it is the [[topic:bookmarks|bookmark list]]: Tab moves the keyboard there, and Return jumps to the selected bookmark.

In comparison mode the jump moves **both** panes, which are locked to the same address.

## A sum in place of a number

Every field that takes an address or a length also takes a sum — numbers joined by `+` and `-`, in either base. This applies to Go To, **Edit ▸ Select Block…**, **Edit ▸ Add Cut…** and the address of a bookmark.

- `0x1FE000 + 4096` — an address in hex plus a length in decimal.
- `0x2C0000 - 0x400 - 16` — any number of terms, taken from left to right.

The sum remains in the field as it was typed. Its result is shown at the right edge of the field in heavier type, and the command acts on that result. Go To and Select Block also repeat the sum below the field, with every term in hex and the result in both bases: `0x1FE000 + 0x1000 = 0x1FF000 (2093056)`.

! A term without the `0x` prefix that consists of decimal digits only is decimal: `0x1FE000 + 40` adds forty, not `0x40`. The line below the field shows how each term was read. For the same reason a single number typed without the prefix shows its hex value at the right edge.

Brackets and multiplication are not supported. A sum whose result is negative, or does not fit in 64 bits, is refused.

A sum that ends in `+` or `-` is not marked as an error while it is being typed. When the command is confirmed with it, the field reports that the sum is not finished. A cut or bookmark panel clicked away from with such a sum does not close: the field turns red, and the sum stays to be completed or the panel to be closed with Esc.

The arrow button at the right edge of the field, or **↓**, lists the last ten entries. The list is shared by all of these fields: it holds the addresses Go To has jumped to and every sum a command was carried out with, each sum with its result. Choosing an entry places it in the field, where it can be checked and corrected; nothing happens until the command is confirmed.

## Back to where you were

Every jump records the place it leaves: Go To, a bookmark, the next or previous difference, a search result, a click on the minimap, a click on a row of a tool panel. **View ▸ Back** (**⌘[**) returns there — the same selection, the same rows on screen, and the same row chosen in the tool panel with its zones — and **View ▸ Forward** (**⌘]**) goes the other way. The same two commands are the **‹ ›** buttons in the toolbar, to the right of the Tools menu.

Scrolling, Page Up/Down and Home/End are recorded once they take the caret off the screen: Back returns to the caret and the rows that were on screen with it. Scrolling on while the caret is off screen is the same step. Moving the caret with the arrow keys or the mouse is not a jump and is not recorded. Nor is moving through a tool panel's rows with the arrow keys: only a click on a row is. Back and Forward to a step made by a click in a tool panel's table give the keyboard to that table, so the arrow keys go on from the row they returned to.

The history belongs to the tab and holds the last fifty places. In comparison mode a place covers both panes. With the tool panel closed, Back and Forward return the dump alone; once the same tool is open again, its rows are chosen again as well. A place in a file that has since been closed, or replaced by another file, is skipped.

## Selecting a block

**Edit ▸ Select Block…** selects a range by number rather than by dragging: start and end, or start and length. Each field accepts hex with the `0x` prefix, plain decimal, or a sum of both. The command is for selecting by hand, where the start, the end or the length of a range is known or has been worked out.

! **End** is the address of the last byte of the selection, not of the first byte after it. A start of `0x1000` with an end of `0x1FFF` therefore selects exactly `0x1000` bytes.

## Following the other pane

The two panes are locked together in scroll position, caret and selection. **View ▸ Swap Panels** exchanges the files between the panes.

See also: [[topic:minimap|The Minimap]], for moving by pointing rather than by address.
