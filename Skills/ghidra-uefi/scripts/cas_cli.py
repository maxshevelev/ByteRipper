#!/usr/bin/env python3
"""Command line for the local code-artifact CAS.

    cas_cli.py list
    cas_cli.py show <module-sha> [--recipe code-v2-ghidra-12.1.2]
    cas_cli.py ref add laptop <module-sha>/<recipe>
    cas_cli.py gc --apply
    cas_cli.py export --all --out analyses.zip
    cas_cli.py import analyses.zip
    cas_cli.py conflicts
    cas_cli.py verify

The store defaults to `~/Library/Application Support/ByteRipper/Analysis`.
`gc` is a dry run unless `--apply`; with `--analyses` it also removes analyses
no reference names, and refuses to do that unless a reference exists (or
`--force` is given, which is meant for a store being thrown away).

The store is `byteripper-cas` underneath (`cas.py`); this is the skill's
spelling of its commands.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import cas


def default_store() -> Path:
    return Path.home() / "Library" / "Application Support" / "ByteRipper" / "Analysis"


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="The local code-artifact CAS.")
    parser.add_argument("--store", type=Path, default=default_store(),
                        help="the store root")
    sub = parser.add_subparsers(dest="command", required=True)

    sub.add_parser("list", help="every analysis in the store").add_argument("--json", action="store_true")
    show = sub.add_parser("show", help="one analysis")
    show.add_argument("module", help="module SHA-256, or <module>/<recipe>")
    show.add_argument("--recipe")
    show.add_argument("--json", action="store_true")

    put = sub.add_parser("put", help="store an object by its hash")
    put.add_argument("file", type=Path)
    get = sub.add_parser("get", help="read an object")
    get.add_argument("digest")
    get.add_argument("--out", type=Path)

    sub.add_parser("verify", help="check hashes, manifests and references").add_argument("--json", action="store_true")

    gc = sub.add_parser("gc", help="remove what nothing reaches")
    gc.add_argument("--apply", action="store_true", help="delete; without it the run is a report")
    gc.add_argument("--analyses", action="store_true", help="also remove analyses no reference names")
    gc.add_argument("--force", action="store_true", help="allow --analyses with no references")
    gc.add_argument("--json", action="store_true")

    ref = sub.add_parser("ref", help="named sets of analyses")
    ref_sub = ref.add_subparsers(dest="ref_command", required=True)
    ref_add = ref_sub.add_parser("add")
    ref_add.add_argument("name")
    ref_add.add_argument("keys", nargs="+")
    ref_sub.add_parser("list").add_argument("--json", action="store_true")
    ref_remove = ref_sub.add_parser("remove")
    ref_remove.add_argument("name")

    export = sub.add_parser("export", help="write analyses and objects as a zip")
    export.add_argument("--out", type=Path, required=True)
    export.add_argument("--key", action="append", default=[])
    export.add_argument("--all", action="store_true")
    import_ = sub.add_parser("import", help="read a zip into the store")
    import_.add_argument("bundle", type=Path)
    import_.add_argument("--json", action="store_true")
    sub.add_parser("conflicts", help="readings an import kept aside").add_argument("--json", action="store_true")
    history = sub.add_parser("history", help="every revision of a module's readings")
    history.add_argument("module")
    history.add_argument("--json", action="store_true")

    args = parser.parse_args(argv)
    store = cas.Store(args.store)
    try:
        return run(args, store)
    except cas.CASError as error:
        print(error, file=sys.stderr)
        return 1


def run(args, store: cas.Store) -> int:

    if args.command == "list":
        rows = []
        for manifest in store.analyses():
            module = manifest.get("module", {})
            rows.append({
                "module": module.get("sha256"),
                "name": module.get("name"),
                "kind": module.get("kind"),
                "recipe": manifest.get("recipe", {}).get("id"),
                "artifact": manifest.get("artifact", {}).get("sha256"),
                "stats": manifest.get("stats", {}),
                "analyzed_at": manifest.get("analyzed_at"),
                "source": manifest.get("source", {}),
            })
        if args.json:
            print(json.dumps(rows, indent=2))
        else:
            for row in rows:
                stats = row["stats"]
                print(f"{row['module'][:16]}  {row['name'] or '?':<20}  {row['kind'] or '?':<5}  "
                      f"{row['recipe']:<28}  {stats.get('functions', 0):>4} funcs  "
                      f"{stats.get('instructions', 0):>6} instr")
            if not rows:
                print("the store is empty")
        return 0

    if args.command == "show":
        if "/" in args.module:
            manifest = store.find_analysis(args.module)
        else:
            manifest = store.analysis(args.module, args.recipe)
        if manifest is None:
            print(f"no analysis for {args.module}", file=sys.stderr)
            return 1
        print(json.dumps(manifest, indent=2))
        return 0

    if args.command == "put":
        data = args.file.read_bytes()
        digest = store.put_object(data)
        print(digest)
        return 0

    if args.command == "get":
        data = store.get_object(args.digest)
        if args.out:
            args.out.write_bytes(data)
            print(f"{args.digest} -> {args.out}")
        else:
            sys.stdout.buffer.write(data)
        return 0

    if args.command == "verify":
        problems = store.verify()
        if args.json:
            print(json.dumps({"problems": problems}, indent=2))
        else:
            for problem in problems:
                print(problem)
            if not problems:
                print("every object, manifest and reference checks out")
        return 1 if problems else 0

    if args.command == "gc":
        if args.analyses and not store.referenced_keys() and not args.force:
            print("refusing to delete every analysis: the store has no references; "
                  "add a ref or pass --force", file=sys.stderr)
            return 2
        report = store.gc(dry_run=not args.apply, delete_unreferenced_analyses=args.analyses)
        if args.json:
            print(json.dumps(report, indent=2))
        else:
            verb = "would remove" if not args.apply else "removed"
            print(f"{verb} {report['analyses']} analyses and {report['objects']} objects; "
                  f"kept {report['kept_analyses']} analyses")
            if not args.apply:
                print("dry run; pass --apply to delete")
        return 0

    if args.command == "ref":
        if args.ref_command == "add":
            record = store.set_ref(args.name, args.keys)
            print(json.dumps(record, indent=2))
            return 0
        if args.ref_command == "list":
            records = store.refs()
            if args.json:
                print(json.dumps(records, indent=2))
            else:
                for record in records:
                    print(f"{record.get('name')}: {len(record.get('analyses', []))} analyses")
                    for key in record.get("analyses", []):
                        print(f"  {key}")
            return 0
        if args.ref_command == "remove":
            removed = store.remove_ref(args.name)
            print("removed" if removed else "no such reference")
            return 0 if removed else 1

    if args.command == "export":
        keys = list(args.key)
        if args.all:
            keys = [store.key(m) for m in store.analyses()]
        if not keys:
            print("export: give --key or --all", file=sys.stderr)
            return 2
        bundle = store.export_bundle(keys, args.out)
        print(f"{len(bundle['analyses'])} analyses -> {args.out}")
        return 0

    if args.command == "import":
        result = store.import_bundle(args.bundle)
        if args.json:
            print(json.dumps(result, indent=2))
        else:
            print(f"{len(result['imported'])} analyses imported, "
                  f"{len(result['unchanged'])} already here")
            for entry in result["skipped"]:
                print(f"skipped {entry['key']}: {entry['reason']}")
            for entry in result["conflicts"]:
                print(f"kept aside {entry['key']}: {entry['reason']}")
        return 0

    if args.command == "conflicts":
        manifests = store.conflicts()
        if args.json:
            print(json.dumps(manifests, indent=2))
        else:
            for manifest in manifests:
                reading = manifest.get("reading") or {}
                print(f"{store.key(manifest)}  project {reading.get('project')} "
                      f"rev {reading.get('rev')}  artifact {manifest['artifact']['sha256'][:16]}")
            if not manifests:
                print("no conflicting readings")
        return 0

    if args.command == "history":
        record = store.review_history(args.module)
        if args.json:
            print(json.dumps(record, indent=2))
        elif not record:
            print("no review history")
        else:
            for revision in record["revisions"]:
                print(f"{revision['project']}  rev {revision['rev']}  {revision['recorded_at']}  "
                      f"{revision.get('by') or '-'}  document {revision['review'][:16]}")
        return 0

    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
