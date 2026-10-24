#!/usr/bin/env python3
"""Ask the running ByteRipper for a UEFI node's bytes and write them to a file.

The UEFI Structure panel has already found the file, parsed its sections and
decompressed what had to be decompressed. This script does not parse any of
that: it speaks MCP over stdio to the relay the app installed beside its
socket — the same server a client is configured with — calls `uefi_node_data`
in 4096-byte pages, and writes the bytes out. A module inside a Tiano or LZMA
section comes out exactly as the tree shows it, which is the whole point.

The result is what `te_to_pe.py` and `ghidra_import.py` take.

    python3 byteripper_extract.py --node 0.5.4.2.0.1.0.2.2 \
        --out AmiUpdateDxePolicyCallback.efi

The document is the focused one unless `--document` names an id or a label
from `documents`. `--part body` (the default) is the image itself; `all`
includes the section header; `decompressed` is a compressed section's contents.

Stdlib only. The relay path is `--relay`, `$BYTERIPPER_RELAY`, or the app's
own location; the socket is wherever the relay expects it, so an app run under
`BYTERIPPER_AGENT_SOCKET` needs the same variable here.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import module_scan

PAGE = 4096
PROTOCOL_VERSION = "2025-06-18"


class RelayError(Exception):
    pass


class Relay:
    """The app's stdio relay, one JSON-RPC line at a time."""

    def __init__(self, command: str):
        self.process = subprocess.Popen(
            [command],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,
        )
        self.next_id = 0
        self.initialize()

    def send(self, message: dict) -> None:
        assert self.process.stdin is not None
        self.process.stdin.write(json.dumps(message) + "\n")
        self.process.stdin.flush()

    def receive(self, wanted: int) -> dict:
        assert self.process.stdout is not None
        while True:
            line = self.process.stdout.readline()
            if not line:
                error = self.process.stderr.read() if self.process.stderr else ""
                raise RelayError(
                    "the relay closed before answering"
                    + (f": {error.strip()}" if error.strip() else ""))
            message = json.loads(line)
            if message.get("id") == wanted:
                return message
            # Notifications and requests from the server are not the answer.

    def request(self, method: str, params: dict) -> dict:
        self.next_id += 1
        self.send({"jsonrpc": "2.0", "id": self.next_id,
                   "method": method, "params": params})
        answer = self.receive(self.next_id)
        if "error" in answer:
            raise RelayError(f"{method}: {answer['error'].get('message', answer['error'])}")
        return answer["result"]

    def initialize(self) -> None:
        self.request("initialize", {
            "protocolVersion": PROTOCOL_VERSION,
            "capabilities": {},
            "clientInfo": {"name": "ghidra-uefi", "version": "1"},
        })
        self.send({"jsonrpc": "2.0", "method": "notifications/initialized"})

    def tool(self, name: str, arguments: dict) -> dict:
        result = self.request("tools/call", {"name": name, "arguments": arguments})
        text = ""
        for item in result.get("content", []):
            if item.get("type") == "text":
                text = item.get("text", "")
                break
        if result.get("isError"):
            raise RelayError(text or f"{name} failed")
        return json.loads(text)

    def close(self) -> None:
        try:
            if self.process.stdin:
                self.process.stdin.close()
            self.process.wait(timeout=5)
        except (subprocess.TimeoutExpired, OSError):
            self.process.kill()


def relay_path(explicit: str | None) -> str:
    if explicit:
        return os.path.expanduser(explicit)
    if os.environ.get("BYTERIPPER_RELAY"):
        return os.path.expanduser(os.environ["BYTERIPPER_RELAY"])
    if os.environ.get("BYTERIPPER_AGENT_SOCKET"):
        folder = os.path.dirname(os.path.expanduser(os.environ["BYTERIPPER_AGENT_SOCKET"]))
        return os.path.join(folder, "byteripper-mcp")
    return os.path.expanduser("~/Library/Application Support/ByteRipper/byteripper-mcp")


def find_document(relay: Relay, wanted: str | None) -> tuple[str | None, str]:
    documents = relay.tool("documents", {})["documents"]
    if not documents:
        raise RelayError("no file is open in ByteRipper")
    if wanted is None:
        focused = next((document for document in documents if document.get("focused")), documents[0])
        return focused.get("id"), focused.get("label", focused.get("name", ""))
    for document in documents:
        if document.get("id") == wanted:
            return document["id"], document.get("label", "")
    matches = [document for document in documents if document.get("label") == wanted]
    if len(matches) == 1:
        return matches[0]["id"], wanted
    labels = ", ".join(document.get("label", "?") for document in documents)
    raise RelayError(f"{wanted!r} is not an open document; open: {labels}")


def parse_rows(rows: list[str]) -> bytes:
    """The `hex` rows `uefi_node_data` gives, address column dropped."""
    out = bytearray()
    for row in rows:
        before = row.split("|", 1)[0]
        fields = before.split()
        if not fields:
            continue
        for field in fields[1:]:
            out.append(int(field, 16))
    return bytes(out)


def metadata(blob: bytes, label: str, node: str, part: str, first: dict) -> dict:
    report = {
        "document": label,
        "node": node,
        "part": part,
        "size": len(blob),
        "sha256": hashlib.sha256(blob).hexdigest(),
        "source": first.get("source"),
        "in_compressed": first.get("in_compressed", False),
    }
    if blob[:2] == b"VZ":
        info = module_scan.parse_te(blob, 0, len(blob))
    elif blob[:2] == b"MZ":
        info = module_scan.parse_pe(blob, 0, len(blob))
    else:
        info = None
    if info:
        report["image"] = {
            "kind": info["kind"],
            "machine": info["machine"],
            "machine_id": info["machine_id"],
            "image_base": info["image_base"],
            "entry_point": info["entry_point"],
            "subsystem_name": info["subsystem_name"],
            "sections": info["sections"],
        }
    return report


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        description="Extract a UEFI node's bytes through the running ByteRipper.")
    parser.add_argument("--node", required=True,
                        help="the node id from uefi_tree or uefi_find")
    parser.add_argument("--document", help="the document's id or label; default the focused one")
    parser.add_argument("--part", default="body", choices=["body", "header", "all", "decompressed"])
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--meta", type=Path, help="write the facts as JSON here")
    parser.add_argument("--relay", help="the app's byteripper-mcp helper")
    args = parser.parse_args(argv)

    relay = Relay(relay_path(args.relay))
    try:
        document, label = find_document(relay, args.document)
        arguments = {"node": args.node, "part": args.part,
                     "offset": 0, "length": PAGE, "format": "hex"}
        if document:
            arguments["document"] = document
        first = relay.tool("uefi_node_data", arguments)
        size = int(str(first.get("size", "0")), 0)
        if size <= 0:
            raise RelayError(f"node {args.node} has no bytes in part {args.part!r}")

        blob = bytearray(parse_rows(first.get("rows", [])))
        offset = len(blob)
        while offset < size:
            page = min(PAGE, size - offset)
            arguments = {"node": args.node, "part": args.part,
                         "offset": offset, "length": page, "format": "hex"}
            if document:
                arguments["document"] = document
            answer = relay.tool("uefi_node_data", arguments)
            chunk = parse_rows(answer.get("rows", []))
            if len(chunk) != page:
                raise RelayError(f"asked for {page} bytes at {offset:#x}, got {len(chunk)}")
            blob.extend(chunk)
            offset += page
    finally:
        relay.close()

    if len(blob) != size:
        print(f"node {args.node}: expected {size} bytes, got {len(blob)}", file=sys.stderr)
        return 1
    args.out.write_bytes(bytes(blob))
    report = metadata(bytes(blob), label, args.node, args.part, first)
    if args.meta:
        args.meta.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
