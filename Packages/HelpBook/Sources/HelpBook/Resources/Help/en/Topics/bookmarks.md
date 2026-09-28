# Bookmarks

> Marked addresses to return to quickly: shown on the row and shared by both panes.

@covers menu.edit.bookmark-toggle
@covers menu.edit.bookmark-edit

**⌘D** sets a bookmark on the row the caret is on, or removes the one that is there. The address of that row is then drawn on a coloured arrow, and the row is marked in the margin of the [[topic:minimap|minimap]] by a coloured pointer.

- **⇧⌘D** gives the bookmark a name, or edits the name it has. A bookmark with no name displays its address.
- **⌘L** opens Go To, and the lower half of that window is the bookmark list: Tab moves the keyboard into it, Return jumps to the selected bookmark.

## What a bookmark is

A bookmark marks a **row**, not a byte: the address is rounded down to a multiple of 16, a row being the unit on which the mark is visible.

A bookmark is an **absolute address**, and it belongs to the window rather than to a file. In a comparison both panes display the same bookmark at the same height, so that `0x1FE000` refers to the same place in both dumps.

Because the address is absolute, inserting or deleting bytes moves the content but not the bookmark. A mark that travels with the bytes is a [[topic:segments|segment]] cut instead.

Bookmarks last as long as the window, not as long as the file: closing a file and reopening it retains them.

The addresses to bookmark are reported by the tool panels: selecting a node in a panel gives its address in the detail list ([[topic:tools-overview|The Tool Panels]]).
