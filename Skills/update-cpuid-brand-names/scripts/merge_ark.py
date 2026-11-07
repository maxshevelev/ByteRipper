#!/usr/bin/env python3
"""Merge what was read from Intel ARK into `ark-sspec.json`.

Each argument is a batch the ARK agents wrote (`SKILL.md`, "Filling the
gaps"): a JSON array of

    {"model": "Intel Core i5-8265U",
     "url": "https://www.intel.com/…/ordering.html" | null,
     "specs": [{"sSpec": "SREJQ", "stepping": "W0", "orderingCode": "…"}, …],
     "note": "…"}                       # optional

A model already in the file is replaced by the batch's record; one an agent
could not find is kept with no specs, so `gaps.py` does not ask for it again.
Codes and steppings are checked for shape — `SRxxx` / `Qxxx`, a letter and a
digit — and a record that fails is refused whole, not half-taken. Ordering
codes are dropped: the table does not use them, and a boxed part repeats its
tray part's S-SPEC under another one.

Usage:
    merge_ark.py batch0.json [batch1.json …] [--retrieved YYYY-MM-DD]

stdlib only; the run is a diff to review.
"""

import argparse
import datetime
import json
import re
import sys
import os

HERE = os.path.dirname(os.path.abspath(__file__))
ARK_FILE = os.path.join(HERE, "ark-sspec.json")
CODE = re.compile(r"^(SR[0-9A-Z]{3}|Q[0-9A-Z]{3})$")
STEP = re.compile(r"^[A-Z][0-9]$")


def records(path):
    with open(path, encoding="utf-8") as f:
        batch = json.load(f)
    for item in batch:
        model = item.get("model")
        if not isinstance(model, str) or not model.startswith("Intel "):
            sys.exit(f"{path}: a record with no model name: {item}")
        specs = {}
        for s in item.get("specs") or []:
            code, stepping = s.get("sSpec"), s.get("stepping")
            if not isinstance(code, str) or not CODE.match(code):
                sys.exit(f"{path}: {model}: not an S-SPEC: {code!r}")
            if stepping is not None and not STEP.match(stepping):
                sys.exit(f"{path}: {model}: not a stepping: {stepping!r}")
            specs.setdefault(code, stepping)
        record = {"model": model, "url": item.get("url"),
                  "specs": [{"sSpec": c, "stepping": s} for c, s in specs.items()]}
        if item.get("note"):
            record["note"] = item["note"]
        yield record


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("batches", nargs="+")
    parser.add_argument("--retrieved", default=datetime.date.today().isoformat())
    args = parser.parse_args()

    with open(ARK_FILE, encoding="utf-8") as f:
        doc = json.load(f)
    by_model = {m["model"]: m for m in doc["models"]}
    added = replaced = 0
    for path in args.batches:
        for record in records(path):
            if record["model"] in by_model:
                replaced += 1
            else:
                added += 1
            by_model[record["model"]] = record
    doc["models"] = sorted(by_model.values(), key=lambda m: m["model"])
    doc["retrieved"] = args.retrieved
    with open(ARK_FILE, "w", encoding="utf-8") as f:
        json.dump(doc, f, ensure_ascii=False, indent=2)
        f.write("\n")
    print(f"{added} models added, {replaced} replaced, {len(doc['models'])} in {os.path.relpath(ARK_FILE)}")


if __name__ == "__main__":
    main()
