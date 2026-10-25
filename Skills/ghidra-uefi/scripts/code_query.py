#!/usr/bin/env python3
"""Read a stored code artifact without Ghidra.

`code_artifact.py` is the one-time pass; this is the reading side. Point it at
the module's bytes or at the SHA-256 the artifact is stored under, then ask for
functions, a function's disassembly or decompiled C, its references, a text in
the code, the strings, or the writes to the POST port.

    python3 code_query.py CpuPei.te functions
    python3 code_query.py CpuPei.te disasm FUN_000004bf
    python3 code_query.py CpuPei.te decompile 0x4BF
    python3 code_query.py CpuPei.te search 0x11004
    python3 code_query.py CpuPei.te post-codes

No Ghidra is run and no program is loaded: the answer comes from `code.json`
under the store, keyed by the module's SHA-256.

Stdlib only.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
from pathlib import Path


def default_store() -> Path:
    return Path.home() / "Library" / "Application Support" / "ByteRipper" / "Analysis"


def normalize_address(text: str) -> int | None:
    digits = text.strip().lower()
    if digits.startswith("0x"):
        digits = digits[2:]
    if not digits or any(c not in "0123456789abcdef" for c in digits):
        return None
    try:
        return int(digits, 16)
    except ValueError:
        return None


class Artifact:
    def __init__(self, folder: Path):
        self.folder = folder
        self.manifest = json.loads((folder / "manifest.json").read_text(encoding="utf-8"))
        self.code = json.loads((folder / "code.json").read_text(encoding="utf-8"))
        self.functions = self.code.get("functions", [])

    def function(self, wanted: str) -> dict:
        address = normalize_address(wanted)
        if address is not None:
            for function in self.functions:
                entry = normalize_address(function.get("entry", ""))
                if entry == address:
                    return function
            for function in self.functions:
                entry = normalize_address(function.get("entry", ""))
                size = int(function.get("size", 0))
                if entry is not None and entry <= address < entry + size:
                    return function
            raise SystemExit(f"no function at {wanted}")
        exact = [f for f in self.functions if f.get("name") == wanted]
        if len(exact) == 1:
            return exact[0]
        partial = [f for f in self.functions if wanted.lower() in f.get("name", "").lower()]
        if len(partial) == 1:
            return partial[0]
        if partial:
            names = ", ".join(f.get("name", "?") for f in partial[:20])
            raise SystemExit(f"{wanted!r} matches {len(partial)} functions: {names}")
        raise SystemExit(f"no function named {wanted!r}")


def summary(artifact: Artifact) -> None:
    manifest = artifact.manifest
    print(f"{manifest.get('name')}  {manifest.get('sha256')}")
    print(f"  {manifest.get('module_kind')}  {manifest.get('language')}  "
          f"base {manifest.get('image_base')}")
    print(f"  Ghidra {manifest.get('ghidra')}  analyzed {manifest.get('analyzed_at')}")
    print(f"  {len(artifact.functions)} functions, "
          f"{sum(len(f.get('instructions', [])) for f in artifact.functions)} instructions, "
          f"{len(artifact.code.get('strings', []))} strings, "
          f"{len(artifact.code.get('post_codes', []))} POST writes, "
          f"{len(artifact.code.get('status_code_calls', []))} status-code candidates")
    if manifest.get("source", {}).get("node"):
        print(f"  from {manifest['source'].get('document') or '?'} node {manifest['source']['node']}")


def function_summary(function: dict) -> None:
    print(f"{function.get('entry')}  {function.get('name')}  "
          f"{function.get('size')} bytes")
    print(f"  {function.get('signature')}")
    print(f"  callers: {', '.join(function.get('callers', [])) or '-'}")
    print(f"  callees: {', '.join(function.get('callees', [])) or '-'}")


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="Read a stored code artifact.")
    parser.add_argument("target", help="the module's bytes, or the artifact's SHA-256")
    parser.add_argument("command", nargs="?", default="summary",
                        choices=["summary", "functions", "function", "disasm", "decompile",
                                 "xrefs", "search", "strings", "post-codes", "status-codes"])
    parser.add_argument("argument", nargs="?", help="a function name or address, or the text to find")
    parser.add_argument("--store", type=Path, default=default_store())
    parser.add_argument("--limit", type=int, default=40)
    parser.add_argument("--json", action="store_true", help="print the answer as JSON")
    args = parser.parse_args(argv)

    target = args.target
    if Path(target).expanduser().is_file():
        digest = hashlib.sha256(Path(target).expanduser().read_bytes()).hexdigest()
    elif len(target) == 64 and all(c in "0123456789abcdefABCDEF" for c in target):
        digest = target.lower()
    else:
        print(f"{target}: not a module file and not a SHA-256", file=sys.stderr)
        return 2
    folder = args.store.expanduser() / digest
    if not (folder / "code.json").exists():
        print(f"no artifact for {digest} in {folder}; run code_artifact.py first", file=sys.stderr)
        return 1
    artifact = Artifact(folder)

    if args.command == "summary":
        if args.json:
            print(json.dumps(artifact.manifest, indent=2))
        else:
            summary(artifact)
        return 0

    if args.command == "functions":
        rows = [{"entry": f.get("entry"), "name": f.get("name"), "size": f.get("size"),
                 "signature": f.get("signature")}
                for f in artifact.functions[:(args.limit or None)]]
        if args.json:
            print(json.dumps(rows, indent=2))
        else:
            for row in rows:
                print(f"{row['entry']:>10}  {row['size']:>5}  {row['name']:<24} {row['signature']}")
        return 0

    if args.command in ("function", "disasm", "decompile", "xrefs"):
        if not args.argument:
            print(f"{args.command}: give a function name or address", file=sys.stderr)
            return 2
        function = artifact.function(args.argument)
        if args.command == "function":
            if args.json:
                print(json.dumps(function, indent=2))
            else:
                function_summary(function)
            return 0
        if args.command == "decompile":
            text = function.get("c")
            if args.json:
                print(json.dumps({"entry": function.get("entry"), "name": function.get("name"),
                                  "c": text}, indent=2))
            else:
                print(text if text else "(no decompiled C: external or thunk)")
            return 0
        if args.command == "disasm":
            instructions = function.get("instructions", [])
            if args.limit:
                instructions = instructions[:args.limit]
            if args.json:
                print(json.dumps(instructions, indent=2))
            else:
                for instruction in instructions:
                    print(f"{instruction.get('address'):>10}  "
                          f"{instruction.get('bytes'):<24}  {instruction.get('text')}")
            return 0
        if args.command == "xrefs":
            refs = []
            for instruction in function.get("instructions", []):
                for reference in instruction.get("references", []):
                    refs.append({"from": instruction.get("address"),
                                 "to": reference.get("to"),
                                 "type": reference.get("type"),
                                 "instruction": instruction.get("text")})
            answer = {"function": function.get("entry"), "callers": function.get("callers", []),
                      "callees": function.get("callees", []), "references": refs}
            if args.json:
                print(json.dumps(answer, indent=2))
            else:
                function_summary(function)
                for reference in refs:
                    print(f"  {reference['from']} -> {reference['to']}  "
                          f"{reference['type']}  {reference['instruction']}")
            return 0

    if args.command == "search":
        if not args.argument:
            print("search: give the text to find", file=sys.stderr)
            return 2
        needle = args.argument.lower()
        matches = []
        for function in artifact.functions:
            if needle in function.get("name", "").lower():
                matches.append({"kind": "function", "address": function.get("entry"),
                                "function": function.get("entry"),
                                "text": function.get("name")})
            if needle in (function.get("c") or "").lower():
                matches.append({"kind": "decompiled", "address": function.get("entry"),
                                "function": function.get("entry"), "text": function.get("name")})
            for instruction in function.get("instructions", []):
                if needle in instruction.get("text", "").lower():
                    matches.append({"kind": "instruction",
                                    "address": instruction.get("address"),
                                    "function": function.get("entry"),
                                    "text": instruction.get("text")})
        for string in artifact.code.get("strings", []):
            if needle in string.get("value", "").lower():
                matches.append({"kind": "string", "address": string.get("address"),
                                "function": None, "text": string.get("value")})
        if args.json:
            print(json.dumps(matches[:args.limit or None], indent=2))
        else:
            for match in matches[:args.limit or None]:
                print(f"{match['kind']:<12} {match['address']:>10}  {match['text']}")
            if len(matches) > (args.limit or 0):
                print(f"... {len(matches) - args.limit} more")
        return 0

    if args.command == "strings":
        needle = (args.argument or "").lower()
        strings = [s for s in artifact.code.get("strings", [])
                   if needle in s.get("value", "").lower()]
        if args.json:
            print(json.dumps(strings[:args.limit or None], indent=2))
        else:
            for string in strings[:args.limit or None]:
                print(f"{string.get('address'):>10}  {string.get('type'):<12}  {string.get('value')}")
        return 0

    if args.command == "status-codes":
        calls = artifact.code.get("status_code_calls", [])
        if args.argument:
            needle = args.argument.lower()
            calls = [c for c in calls
                     if needle in c.get("function", "").lower()
                     or needle in c.get("address", "").lower()]
        if args.json:
            print(json.dumps(calls, indent=2))
        else:
            for call in calls:
                print(f"{call.get('address'):>10}  {call.get('function')}  {call.get('text')}")
                for line in call.get("context", []):
                    print(f"              {line}")
            if not calls:
                print("no call through a table entry at +0x58")
        return 0

    if args.command == "post-codes":
        port = args.argument
        writes = [w for w in artifact.code.get("post_codes", [])
                  if port is None or w.get("port", "").lower() == port.lower()]
        if args.json:
            print(json.dumps(writes, indent=2))
        else:
            for write in writes:
                print(f"{write.get('address'):>10}  {write.get('port'):>8}  "
                      f"{write.get('function')}  {write.get('text')}")
            if not writes:
                print("no OUT instruction in the analyzed code")
        return 0

    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
