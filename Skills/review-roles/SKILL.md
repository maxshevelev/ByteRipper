---
name: review-roles
description: The two roles of a review pair on a Mac that works on a remote analysis server through the ByteRipper app — Reviewer and Verifier. Not run as a skill on this Mac: byteripper-server serves these texts, with ghidra-uefi's rules, as the review kit, and the app's MCP offers them as prompts and resources.
---

# Review roles

A Mac with ByteRipper and no checkout reviews modules on a remote
`byteripper-server` through the app's MCP server `byteripper`. Its pair of
agent sessions gets its roles and its rules from that server, so both are
always of the version the server's tools run:

| file | served as | what it is |
|---|---|---|
| `roles/reviewer.md` | prompt `reviewer` (`/mcp__byteripper__reviewer`) | the session that reviews, takes the module, publishes, reports |
| `roles/verifier.md` | prompt `verifier` (`/mcp__byteripper__verifier`) | the session that checks the reports and keeps the work moving; writes nothing |
| `../ghidra-uefi/SKILL.md`, `../ghidra-uefi/reference/*.md` | resources `byteripper://kit/ghidra-uefi/…` | the review rules both roles read first |

`{{mac}}` in a role is replaced by the Mac's name when the app gives the
prompt, so the sessions are told apart on the server's console
("Reviewer · Bench-Mac").

These roles differ from the ones that work on the server's own Mac
(`analyzis`, `flow-manager` in the install's `.claude/skills`): there is no
Coder beside them, nobody there grants deploy windows, and their token cannot
replace what other reviews share.

The server reads this folder and `ghidra-uefi` from `skills/` beside its
binary (`Scripts/make-agent-dist.sh` puts them there), or from the checkout it
was built from. Only Markdown is served.
