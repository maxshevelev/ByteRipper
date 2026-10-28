# Settings

> ⌘, — the app-wide preferences.

@covers settings.general
@covers settings.view
@covers settings.layout
@covers settings.file-types
@covers settings.language
@covers menu.view.pane-layout
@covers menu.view.swap-panes

- **General** — what the program does rather than how it looks, in three groups separated by rules. The first is **Reopen the workspace at launch**: the tabs and the files in them come back as they were at quit, with the address on screen, the cursor and selection, the bookmarks, the segments and the tool panels ([[topic:workspace|The Workspace]]). It is off after installation. The second is how differences are grouped for **Next / Previous Difference** ([[topic:colors|What the Colours Mean]]). The third is the confirmations raised before edits that change the length of the file ([[topic:editing|Editing Bytes]]); they are enabled by default, and this is the same setting as the "do not ask again" box in the dialogs themselves.
- **View** — how the program looks and which language it speaks, in three groups separated by rules. The first sets the monospaced font, its size and the row height of the hex view, and whether the program follows the system theme or is always light or dark; the font size is also changed with **⌘=** / **⌘−** from the View menu. The font and its size are also those of the C and the ASM listing in the code panel; **Dump Row Height** applies to the hex view alone, and **Code Line Spacing** sets how far apart the lines of the C and the listing are — the same for both. The second sets the arrangement of the panes and the word size a new comparison opens with. The third chooses whether the program follows the language of the Mac or uses one of its own: the help book changes language immediately, menus and windows after a restart. Firmware terms remain in English in every language, those being the names datasheets and tools give them.
- **Text Decoding** — the encoding the text column decodes with.
- **Search Patterns** — the named search patterns, and the folder through which the library can be synchronised between installations ([[topic:search|Finding Bytes and Text]]).
- **File Types** — which extensions open in ByteRipper from the Finder. `.rom` and `.dump` belong to the program; `.bin` and the others are offered here because the system already holds a handler for them.
- **Agent** — whether agents may connect to ByteRipper, and the text a client program is set up with ([[topic:agent|Working with an Agent]]).

Settings apply to the program rather than to a window: a font size chosen here applies to every open dump.
