# The Online Catalogues

> Three public catalogues that give names to identifiers found in a dump. The program operates without them.

Part of what the tool panels display is not held in the file: it is a name the community has given to an identifier that the file carries. ByteRipper fetches three public catalogues over HTTPS for this purpose and retains each for one day:

- **UEFI GUID names** — from the UEFITool project. They are what allows the [[topic:tool-uefi|UEFI panel]] to display "AmiBoardInfo" or "DxeCore" in place of a bare [[term:guid|GUID]].
- **CPU microcode** — from the CPUMicrocodes collection. It names the microcode updates the [[topic:tool-fit|FIT panel]] lists, by processor signature, revision and date, and it is the source **Add Microcode…** offers.
- **ME firmware database** — from the ME Analyzer project. It is what lets the [[topic:tool-me|ME panel]] say which known firmware release an image corresponds to.

## What is a measurement and what is a name

The tools keep the two apart:

- **The bytes belong to the file.** An address, a size, a version field, a checksum are all read from the image itself.
- **The name belongs to the catalogue.** It is an identification made by the community; it may be absent, and it may be incorrect.

A row reading "AmiBoardInfo · 0x7A0000 · 0x12C0" therefore states that the file holds a module at that address of that size, and that the catalogue records that GUID as being commonly called AmiBoardInfo.

## Offline

No function of the program requires the network. Without a connection, or where the request is blocked, the tools display identifiers in place of names and report nothing further: no dialogs and no repeated attempts. Everything read from the bytes is unaffected.

Nothing about the open file is transmitted. These are reads of public lists, and the dump does not leave the machine.

The program additionally checks once a day whether a newer version of itself has been released. That is the fourth and last request it makes of the network.
