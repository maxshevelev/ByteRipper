# Working with an Agent

> An agent — Claude Code, Claude Desktop or another program that speaks MCP — can be connected to ByteRipper. It then sees the files open in the program, reads their bytes and shows places in them, while the conversation with it goes on in its own window.

@covers settings.agent
@covers window.agent
@covers menu.window.agent
@covers menubar.agent

The agent works on the same windows as the person at the bench. When it is asked about "this" byte, it reads the position of the caret and the selection; when it refers to a place in the dump, it moves the view there and selects it. The two therefore point at the same bytes rather than describing addresses to each other in words.

## Switching the service on

The service is off after installation. It is switched on in **Settings ▸ Agent** with **Let agents connect to ByteRipper**. While it is on, a mark is shown in the menu bar at the top of the screen; the mark is filled while an agent is connected.

The connection is local. ByteRipper opens a file in the user's Library through which only programs of the same user account can reach it; there is no network port.

The bytes an agent reads are, however, passed by the agent's own program to the model behind it. For Claude that is Anthropic's service. A dump that must not leave the workshop is not to be opened while an agent is connected.

## Connecting a program

**Settings ▸ Agent** offers two buttons, each of which copies a ready text to the clipboard:

- **Copy Command for Claude Code** — a command for Terminal. Run once, it registers ByteRipper with Claude Code for every folder.
- **Copy Configuration for Claude Desktop** — a block for Claude Desktop's configuration file, `claude_desktop_config.json`.

Both name the helper program inside this copy of ByteRipper. If ByteRipper is moved to another folder, the text is copied again.

If ByteRipper is not running when the agent's program starts, the helper starts it. If the service is switched off, the agent's program reports that ByteRipper's agent service is not running.

## What an agent can do

At present an agent can:

- list the open files, with their names, sizes and whether they have unsaved edits;
- read the position of the caret, the selection and the rows on screen;
- read bytes — as hex rows, as text, or as 16-, 32- and 64-bit numbers — including unsaved edits;
- show a place: bring its tab forward, scroll to it and select it.

Each place an agent shows is a step of the navigation history: **View ▸ Back** (**⌘[**) returns to the place the view was at before ([[topic:navigation|Moving Around]]).

An agent cannot save a file and cannot change one. Addresses in its answers are given in hex, as in the dump.

## The Agent window

**Window ▸ Agent** shows whether the service is running and lists every request the agent has made: the time, the tool, the arguments as the agent wrote them, how long the answer took, its size and the result. A refused request is shown in red, with the reason the agent was given. **Clear Log** empties the list; the list is not kept after the program quits.

## When the service does not start

The status line in **Settings ▸ Agent** gives the reason. The usual one is a second copy of ByteRipper already running with the service switched on: only one copy can serve agents at a time, and the second leaves the first one's connection alone.
