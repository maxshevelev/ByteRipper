# The Online Catalogues

> Three public lists that turn numbers in a dump into names. The app works without them.

Some of what the firmware panels show is not in the file at all — it is a name the community has given to an identifier the file carries. ByteRipper fetches three public catalogues for that, over HTTPS, and keeps each one for a day:

- **UEFI GUID names** — from the UEFITool project. This is what turns a bare [[term:guid|GUID]] in the [[topic:tool-uefi|UEFI panel]] into "AmiBoardInfo" or "DxeCore".
- **CPU microcode** — from the CPUMicrocodes collection. It names the microcode updates the [[topic:tool-fit|FIT panel]] lists: which CPU signature, which revision, which date.
- **ME firmware database** — from the ME Analyzer project. It is what lets the [[topic:tool-me|ME panel]] say which known firmware release an image corresponds to.

## What is a fact and what is a name

This distinction matters on a bench, and the panels keep it:

- **The bytes are the file's.** An offset, a size, a version field, a checksum — all read out of the image in front of you.
- **The name is the catalogue's.** It is a community identification, it can be missing, and it can be wrong.

So a row reading "AmiBoardInfo · 0x7A0000 · 0x12C0" means: *the file really has a module at that address of that size, and the catalogue says that GUID is usually called AmiBoardInfo*.

## Offline

Nothing about the app needs the network. With no connection, or with the fetch blocked, the panels show identifiers instead of names and say nothing more about it — no dialogs, no retries in your way. Everything read out of the bytes is unaffected.

Nothing about your file is ever sent anywhere. These are reads of public lists; the dump never leaves the machine.

The app also checks once a day whether a newer version of itself has been released. That is the fourth and last thing it asks the network for.
