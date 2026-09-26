# Moving Around

> Jump between differences, jump to an address, or stand on a byte and read where you are.

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
- **⇧⌥⌘→ / ⇧⌥⌘←** — next / previous *same* block: the start of the next stretch where the files agree. Useful when most of the image differs and what you want is the islands that match.

A "difference" for navigation is a whole run of differing bytes, not each byte in it: a 4 KB block that differs is one stop, not four thousand.

## To an address

**⌘L** opens Go To. Type an address and press Return:

- `0x1FE00` — hex, with the `0x` prefix (already in the field).
- `130560` — decimal, without a prefix.

The field remembers the last ten addresses you jumped to. Below it is the [[topic:bookmarks|bookmark list]] — Tab moves the keyboard there, and Return jumps to the selected mark. Both halves are one window because they answer one question.

In comparison mode the jump moves **both** panes: they are locked to the same address, which is what makes the side-by-side view mean anything.

## Selecting a block

**Edit ▸ Select Block…** selects a range by numbers rather than by dragging: start and end, or start and length. Both accept hex with `0x` and plain decimal. This is the reliable way to select a region whose boundaries you read off a tool panel.

! Ranges inside the app are half-open — the end address is the first byte *not* in the range. Dialogs may offer an inclusive end; they convert it for you.

## Following the other pane

The two panes stay locked: scroll position, caret and selection. That is what makes a comparison readable. **View ▸ Swap Panels** exchanges A and B if you opened them the wrong way round.

See also: [[topic:minimap|The minimap]] for moving by pointing rather than by address.
