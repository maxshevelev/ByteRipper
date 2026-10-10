# Settings

> ⌘, — the app-wide preferences.

@covers settings.view
@covers settings.layout
@covers settings.file-types
@covers settings.language
@covers menu.view.pane-layout
@covers menu.view.swap-panes

- **View** — how the program looks and which language it speaks, in three groups separated by rules. The first sets the monospaced font, its size and the row height of the hex view, and whether the program follows the system theme or is always light or dark; the font size is also changed with **⌘=** / **⌘−** from the View menu. The second sets the arrangement of the panes and the word size a new comparison opens with. The third chooses whether the program follows the language of the Mac or uses one of its own: the help book changes language immediately, menus and windows after a restart. Firmware terms remain in English in every language, those being the names datasheets and tools give them.
- **Comparison** — how differences are shown and counted.
- **Editing** — the confirmations raised before edits that change the length of the file ([[topic:editing|Editing Bytes]]). They are enabled by default, and this is the same setting as the "do not ask again" box in the dialogs themselves.
- **Text Decoding** — the encoding the text column decodes with.
- **Search Patterns** — the named search patterns, and the folder through which the library can be synchronised between installations ([[topic:search|Finding Bytes and Text]]).
- **File Types** — which extensions open in ByteRipper from the Finder. `.rom` and `.dump` belong to the program; `.bin` and the others are offered here because the system already holds a handler for them.
- **Agent** — whether agents may connect to ByteRipper, and the text a client program is set up with ([[topic:agent|Working with an Agent]]).

Settings apply to the program rather than to a window: a font size chosen here applies to every open dump.
