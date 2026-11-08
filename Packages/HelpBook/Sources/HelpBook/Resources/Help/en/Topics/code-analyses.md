# Code Analyses and the Analysis Server

> A code analysis is what Ghidra found in one PEI or DXE module — its functions, instructions and decompiled C, and the names a review gave them. ByteRipper reads analyses from a store: a folder on this Mac, or an analysis server shared by every Mac in a network.

@covers settings.code-analysis
@covers settings.code-analysis.server
@covers agent.review-kit
@covers settings.code-analysis.review-agents

An analysis is made by the Ghidra skill, outside ByteRipper. ByteRipper reads what the skill stored: a module of a UEFI tree with a stored analysis carries a code badge, and **Open with Code** shows its code beside its bytes; the panel is described on [[topic:code-panel|Code Panel]]. While the module's file is collapsed, the badge stands after the file's name, so a list of collapsed files shows which modules have an analysis; expanding the file moves it to the section that holds the module. An analysis is keyed by the module's bytes, not by the dump, so the same module in another dump opens the same analysis.

## Where the analyses are kept

**Settings ▸ Code Analysis** chooses the store.

- **On this Mac** — the analyses are read from this Mac's own folder, `~/Library/Application Support/ByteRipper/Analysis`. The Ghidra skill writes there when it runs on this Mac. This is the setting for a single Mac.
- **On an analysis server** — the analyses are read from `byteripper-server`, a program running on a machine in the network. Every Mac that names the same server reads the same analyses, so a module analysed or reviewed once is available to all of them.

The setting changes only where analyses are read from. Nothing is copied or deleted when it is changed: the folder on this Mac stays as it is, and choosing **On this Mac** again shows its analyses again.

## Connecting to a server

The server is set up once, on the machine that runs it, in Terminal:

1. `byteripper-server token add --name admin --rights admin` makes the server's admin token and prints it once. The server keeps only its hash, and it does not start without one.
2. `byteripper-server token add --name <mac-name> --preset app` makes the token of one Mac: every Mac, and every script that reads the server, has a token of its own. The secret is printed once and kept nowhere.
3. `byteripper-server --listen 127.0.0.1:8765 --listen 100.64.0.7:8765` starts the server on the addresses given: the machine's own loopback address for ByteRipper on the server itself — a Mac does not reach its own address in a private network such as Tailscale — and the private-network address for the other Macs.

Every address the server listens on, its own loopback included, requires a token. The address is usually the server's address in a private network such as Tailscale, which also encrypts the connection.

On each Mac, in **Settings ▸ Code Analysis**:

1. Choose **On an analysis server**.
2. Enter the address as `http://host:port` — on the server itself, `http://localhost:8765` — and the token the server printed for this Mac.
3. Click **Connect**.

The line below the fields says whether the server is reached. A token the server refuses, or no token kept on this Mac, is reported as that, not as an unreachable server; a refusal names the rights the token lacks. The token is kept in a file only the current user may read, `~/Library/Application Support/ByteRipper/Server/token`. When the token field is left empty, the token already kept is used.

## Working with a server

- **New analyses appear by themselves.** The server reports every change as it happens, so an analysis stored or a review published from any machine appears on every Mac within a second or two, and an open Code panel is drawn again from it at the same place.
- **What has been read stays readable.** This Mac keeps a copy of what it has read from the server. A function's code is read when the function is shown; of an earlier revision compared with a function, only that function is read. The search, the list of a function's callers and the list of a name's uses go through all the code of the module, so they read the remaining functions first. When the server cannot be reached, the line in the settings says so. What has been read is still shown; a function not yet read is listed by name, and the panel states that its code cannot be obtained. The search and the lists of uses then cover only the functions already read. The connection is retried by itself.
- **Projects stay on this Mac.** When a project is opened, the analyses it carries are added to the copy this Mac keeps of what it has read from the server, so its Code panels show them as the project saved them (see [[topic:projects|Projects]]). Nothing is sent to the server: its store holds what is published through it.

## A review by an agent

When the analysis server also hosts Ghidra, an agent connected to ByteRipper (see [[topic:agent|Working with an Agent]]) can review a module there: it opens the module from a PE32 or TE image node of the UEFI tree, names functions, variables and types, writes comments, and publishes the result. Each publication is a new revision of the module's analysis, and every Mac that reads the server shows it. The project in Ghidra stays on the server, so a review can be continued later, by the agent or by a person. An agent running on the server's own computer connects to `byteripper-server` directly, through the server's local connection, not through ByteRipper.

The server also gives an agent its roles and the rules of a review. ByteRipper connected to such a server offers its agents two prompts — in Claude Code, the commands `/mcp__byteripper__reviewer` and `/mcp__byteripper__verifier` — and the review rules as MCP resources. A session started with the first reviews modules and publishes them; a session started with the second checks the first one's results and changes nothing. While ByteRipper is connected to such a server with a token that may use Ghidra, **Settings ▸ Code Analysis** shows the two commands that start these sessions in Terminal. The roles put this Mac's name into the session's name, so the server's console tells the sessions of different Macs apart. The roles and the rules are the server's own, of the same version as its tools, and nothing has to be installed on this Mac for them. ByteRipper keeps the last copy it received and offers it while the server cannot be reached. With the analyses on this Mac, the prompts and the rules are not offered. A tree of EDK2 sources, which a review cites, is not part of them: the reviewing session asks for it to be cloned once.

When one of the server's tools answers wrong or fails, the agent reports it to the server: the call, what came back and what was expected. The server keeps these reports, and its administrator reads them in the server's console, on the **Server Issues** page, and resolves each with an answer: what was fixed and in which version, or why nothing changes. The agents of the Mac that sent a report read the answers and act on them. A report changes nothing in any module.

When reviews are checked, the server keeps a review board. A verifying agent writes what it finds wrong in a module's review as a remark on the module's ticket — each module has one ticket — with its severity and the place in the code. The agent that reviews the module reads the remarks, answers or fixes them, and says so in the remark's thread. Another verifying agent, not the one that took the module into work, marks each remark verified and closes the ticket. While a remark is open, the module's review is not closed, and a new remark opens a closed module again. The administrator reads the tickets with their threads in the server's console, on the **Review Tickets** page, and may set any status there.

The types a review defines are shared with the modules reviewed after it. A publish whose type differs from the shared one in more than an addition — a new enum member, a comment, a real name where the shared one had a placeholder — is refused, and nothing is written. Which definition is right is not the agent's decision. In the server's console, on the **Activity** page, each module in **Modules in work** has a button that shows the shared types its publish would replace: the module's definition beside the shared one, and the module that wrote the shared one. **Publish, replacing them** publishes the module on behalf of the agent that holds it and makes its definitions the shared ones, as the next version of the shared types. The programs of other modules do not change.

## What the server does not do

- It is meant for one person's network: each client has its own token, and the rights in it decide what that client may do — a `reader` token reads, an `app` token also publishes reviews through the server. Writing into the store in any other way needs an `admin` token. There is no user model of its own.
- It does not take analyses from a Mac. Its store holds only what is published through it.
- It does not delete anything over the network. Analyses no longer needed are removed on the server itself, with `byteripper-cas gc`.
- It does not hold the dumps. An analysis records which module it describes, never the firmware it came from.
