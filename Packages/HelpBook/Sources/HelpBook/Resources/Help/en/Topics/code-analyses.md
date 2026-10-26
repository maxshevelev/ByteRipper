# Code Analyses and the Analysis Server

> A code analysis is what Ghidra found in one PEI or DXE module — its functions, instructions and decompiled C, and the names a review gave them. ByteRipper reads analyses from a store: a folder on this Mac, or an analysis server shared by every Mac in a network.

@covers settings.code-analysis
@covers settings.code-analysis.server
@covers settings.code-analysis.send

An analysis is made by the Ghidra skill, outside ByteRipper. ByteRipper reads what the skill stored: a module of a UEFI tree with a stored analysis carries a code badge, and **Open with Code** shows its code beside its bytes. An analysis is keyed by the module's bytes, not by the dump, so the same module in another dump opens the same analysis.

## Where the analyses are kept

**Settings ▸ Code Analysis** chooses the store.

- **On this Mac** — the analyses are read from this Mac's own folder, `~/Library/Application Support/ByteRipper/Analysis`. The Ghidra skill writes there when it runs on this Mac. This is the setting for a single Mac.
- **On an analysis server** — the analyses are read from `byteripper-server`, a program running on a machine in the network. Every Mac that names the same server reads the same analyses, so a module analysed or reviewed once is available to all of them.

The setting changes only where analyses are read from. Nothing is copied or deleted when it is changed: the folder on this Mac stays as it is, and choosing **On this Mac** again shows its analyses again.

## Connecting to a server

The server is set up once, on the machine that runs it, in Terminal:

1. `byteripper-server token` makes the token and prints it.
2. `byteripper-server --listen 100.64.0.7:8765` starts the server on the address given.

Off the machine's own loopback address the server refuses to start without a token. The address is usually the server's address in a private network such as Tailscale, which also encrypts the connection.

On each Mac, in **Settings ▸ Code Analysis**:

1. Choose **On an analysis server**.
2. Enter the address as `http://host:port`, and the token the server printed.
3. Click **Connect**.

The line below the fields says whether the server is reached. The token is kept in a file only the current user may read, `~/Library/Application Support/ByteRipper/Server/token`; the Ghidra skill's scripts on this Mac read the same file. When the token field is left empty, the token already kept is used.

## Working with a server

- **New analyses appear by themselves.** The server reports every change as it happens, so an analysis stored or a review published from any machine appears on every Mac within a second or two, and an open Code panel is drawn again from it at the same place.
- **What has been read stays readable.** This Mac keeps a copy of what it has read from the server. When the server cannot be reached, the line in the settings says so, and the analyses already read are still shown; the ones not yet read are not. The connection is retried by itself.
- **Projects use the server.** When a project is opened, the analyses it carries are sent to the server, which takes them by the usual rules (see [[topic:projects|Projects]]); the notice after opening reports the server's answer.

## Sending this Mac's analyses

**Send This Mac's Analyses to the Server** copies every analysis kept in this Mac's folder to the server. It is meant for the first connection, when this Mac holds analyses the server does not. The server takes each analysis by the same rules as a project's: a later revision of a review replaces an earlier one, another project's review of a module is kept aside rather than replacing the one there, and an analysis already on the server is left as it is. The line below the button gives the counts.

## What the server does not do

- It is meant for one person's network: there is one token, and whoever holds it may read and write every analysis.
- It does not delete anything over the network. Analyses no longer needed are removed on the server itself, with `byteripper-cas gc`.
- It does not hold the dumps. An analysis records which module it describes, never the firmware it came from.
