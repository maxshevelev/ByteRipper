# Finding Bytes and Text

> ⌘F. Hex bytes or text, over the whole dump, in the background.

@covers menu.edit.find
@covers menu.edit.use-selection
@covers window.find-bar
@covers window.search-results
@covers settings.patterns

The find bar searches the **active pane**, over its current contents, unsaved edits included.

## Hex

A byte sequence is entered as `DEADBEEF`, `DE AD BE EF` or `0xDE 0xAD`; spaces are optional. Once the search has been started the field is rewritten in the form the dump itself uses — uppercase pairs separated by single spaces — so that the pattern can be held against the bytes on screen.

A hex search is always exact. Bytes have no case, and the case option is therefore not offered for it.

## Text

An encoding is chosen — ASCII, UTF-8, UTF-16 LE or UTF-16 BE — and the string is entered. It is encoded to bytes and matched exactly on those bytes. Most strings in UEFI firmware are held as UTF-16 LE; most strings in an option ROM or an embedded-controller image are held as ASCII.

Case-insensitive matching is offered for text.

## While a search is running

Every match in the file is filled in grey; the current one is drawn as a raised yellow bubble. **‹ ›** move between them and the bar reports the count. Over a large dump the search runs in the background and can be cancelled, and matches appear as they are found.

**Search All** opens a list of results that can be clicked through, and marks the matches in the [[topic:minimap|minimap]], where their distribution over the image is visible.

## Patterns you use often

**⌘E** loads the current selection as the search pattern without starting a search, which is how a sequence selected in one dump is then looked for in the other.

Patterns can be named and kept in a pattern library (**Settings ▸ Search Patterns**) — for instance the recurring signatures `_FVH`, `$FPT` or `24 00 00 00`. The library can be synchronised through a folder so that it is shared by several installations.

See also: [[topic:bookmarks|Bookmarks]], for marking an address that was found.
