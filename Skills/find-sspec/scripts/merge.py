#!/usr/bin/env python3
"""Merge what the search agents found into the two record files.

Each argument is a `result<N>.json` an agent wrote (`reference/agent-brief.md`):
a JSON array, one object per model of its batch:

    {"model": "Intel Core i5-10500",
     "ark": {"url": "…/ordering.html" | null, "specs": [{"sSpec", "stepping"}], "note": "…"}
            | null,                      # null: ARK was asked before, not again
     "specs": [{
        "sSpec": "SRH3A",
        "stepping": "G1" | null,         # only if a non-photo evidence gives it
        "cpuid": "A0653" | null,         # likewise
        "architecture": "Comet Lake",    # the code name a source gives the model
        "evidence": [
          {"kind": "intel" | "database", "url": "…", "quote": "…",
           "gives": ["sSpec", "stepping", "cpuid"]},
          {"kind": "photo", "url": "<page>", "image": "<image URL>",
           "sha256": "<from index.json>", "reads": "INTEL CORE i5 / i5-10500 / SRH3A 3.10GHZ / X122J379",
           "lot": "X122J379" | null}]}],
     "note": "…"}

The ARK part goes to `ark-sspec.json` (so neither skill asks ARK again); the
rest to `found-sspec.json`, both beside `update-cpuid-brand-names`'s
`enrich.py`, which places the codes. A model searched and nothing found is kept
with no specs, so the next run does not search it again.

What is refused (the whole merge stops, naming each problem — fix the result
file or take the spec out of it, never loosen a rule here):

- a code that is not `SRxxx` or `SAxxx` — sample codes (`Qxxx`) are not sold models;
- a stepping or CPUID no non-photo evidence gives: a marking does not print
  either;
- a photo whose reading lacks the code or the model number;
- a code that rests on photographs alone, unless there are at least two, of
  different files (`sha256`) from different sites, at least two of them with
  a readable lot line and those lots different, and an architecture named. A
  photograph with no readable lot does not count towards the two: shops copy
  one another's pictures, and blur or crop them.

Usage:
    merge.py result0.json [result1.json …] [--searched YYYY-MM-DD]

stdlib only; the run is a diff to review.
"""

import argparse
import datetime
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SIBLING = os.path.join(HERE, "..", "..", "update-cpuid-brand-names", "scripts")
sys.path.insert(0, SIBLING)
import enrich      # noqa: E402
import merge_ark   # noqa: E402

# SRxxx, and SAxxx since Intel ran out of SR (ARK: Atom P6922-3 SA4RS).
CODE = re.compile(r"^S[RA][0-9A-Z]{3}$")
STEP = re.compile(r"^[A-Z][0-9]$")
CPUID = re.compile(r"^[0-9A-F]{5}$")
KINDS = {"intel", "database", "photo"}
GIVES = {"sSpec", "stepping", "cpuid"}


def model_number(model):
    """`Intel Core i5-10500` → `I5-10500`; `Intel Xeon E5-2690 v3` → `E5-2690V3`."""
    words = model.split()
    number = words[-1]
    if re.fullmatch(r"v\d", number) and len(words) > 1:
        number = words[-2] + number
    return number.upper()


def squeeze(text):
    return re.sub(r"\s+", "", text or "").upper()


def check_spec(model, spec, problems):
    where = f"{model} {spec.get('sSpec')!r}"
    code = spec.get("sSpec")
    if not isinstance(code, str) or not CODE.match(code):
        problems.append(f"{where}: not a production S-SPEC (SRxxx, SAxxx)")
        return None
    evidence = spec.get("evidence") or []
    if not evidence:
        problems.append(f"{where}: no evidence")
        return None
    photos, others = [], []
    for ev in evidence:
        kind = ev.get("kind")
        if kind not in KINDS or not ev.get("url"):
            problems.append(f"{where}: evidence of kind {kind!r} without a page URL")
            continue
        if kind == "photo":
            if not ev.get("image") or not ev.get("sha256"):
                problems.append(f"{where}: a photo without its image URL and sha256")
                continue
            reads = squeeze(ev.get("reads"))
            # The number whole: i5-10500 is not i5-10500T, E5-2690 not E5-2690V3.
            number = re.escape(model_number(model))
            if code not in reads or not re.search(number + r"(?![A-Z0-9])", reads):
                problems.append(f"{where}: photo {ev['image']} reads {ev.get('reads')!r} — "
                                f"not both {code} and {model_number(model)}")
                continue
            photos.append(ev)
        else:
            gives = set(ev.get("gives") or [])
            # A page may give only the CPUID — Intel's microcode notes name the
            # models of a CPUID ("Xeon D-17xx, D-27xx"), not their codes — so
            # long as another page gives the code.
            if not gives or not gives <= GIVES or not ev.get("quote"):
                problems.append(f"{where}: {kind} evidence {ev['url']} needs a quote and "
                                f"gives ⊆ {sorted(GIVES)}")
                continue
            others.append(ev)
    stepping, cpuid = spec.get("stepping"), spec.get("cpuid")
    if stepping is not None:
        if not STEP.match(stepping) or not any("stepping" in e["gives"] for e in others):
            problems.append(f"{where}: stepping {stepping!r} with no Intel or database page giving it")
    if cpuid is not None:
        if not CPUID.match(cpuid) or not any("cpuid" in e["gives"] for e in others):
            problems.append(f"{where}: CPUID {cpuid!r} with no Intel or database page giving it")
    if not any("sSpec" in e["gives"] for e in others):
        # No page gives the code: it rests on photographs, whatever else a
        # page says (a CPUID).
        if len({p["sha256"] for p in photos}) < 2:
            problems.append(f"{where}: rests on photographs, and fewer than two different ones")
        elif len({re.sub(r"^www\.", "", (p["url"].split("/") + ["", "", ""])[2]) for p in photos}) < 2:
            problems.append(f"{where}: all its photographs are from one site")
        # Two chips are two lot lines, both read. A picture whose lot is
        # blurred or cut off may be another site's copy of one already
        # counted (seen: the same photo, blurred, on a second shop).
        lots = {squeeze(p.get("lot")) for p in photos} - {""}
        if len(lots) < 2:
            problems.append(f"{where}: its photographs show {len(lots)} readable lot line(s) — "
                            "two different ones are needed")
        if not spec.get("architecture"):
            problems.append(f"{where}: rests on photographs, and names no architecture")
    kept = {"sSpec": code, "stepping": stepping, "cpuid": cpuid,
            "architecture": spec.get("architecture"),
            "evidence": [{k: v for k, v in e.items()
                          if k in ("kind", "url", "image", "sha256", "reads", "lot", "quote", "gives")}
                         for e in others + photos]}
    return kept


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("results", nargs="+")
    parser.add_argument("--searched", default=datetime.date.today().isoformat())
    args = parser.parse_args()

    problems, ark_records, found_records = [], [], []
    for path in args.results:
        with open(path, encoding="utf-8") as f:
            batch = json.load(f)
        for item in batch:
            model = item.get("model")
            if not isinstance(model, str) or not model.startswith("Intel "):
                problems.append(f"{path}: a record with no model name")
                continue
            if item.get("ark") is not None:
                ark_records.append(merge_ark.check({"model": model, **item["ark"]}, path))
            specs = [s for s in (check_spec(model, spec, problems) for spec in item.get("specs") or [])
                     if s]
            record = {"model": model, "searched": args.searched, "specs": specs}
            if item.get("note"):
                record["note"] = item["note"]
            found_records.append(record)
    if problems:
        sys.exit("nothing merged:\n  " + "\n  ".join(problems))

    if ark_records:
        added, replaced, total = merge_ark.write(ark_records, args.searched)
        print(f"ark: {added} models added, {replaced} replaced, {total} in "
              f"{os.path.relpath(merge_ark.ARK_FILE)}")

    if os.path.exists(enrich.FOUND_FILE):
        with open(enrich.FOUND_FILE, encoding="utf-8") as f:
            doc = json.load(f)
    else:
        doc = {"about": "S-SPECs found by Skills/find-sspec beyond ARK and Wikipedia, each with "
                        "its evidence: an Intel document, an S-SPEC database page, or the "
                        "marking on the package read from photographs of different chips. "
                        "A model searched with nothing found is kept with no specs.",
               "models": []}
    by_model = {m["model"]: m for m in doc["models"]}
    for record in found_records:
        by_model[record["model"]] = record
    doc["models"] = sorted(by_model.values(), key=lambda m: m["model"])
    with open(enrich.FOUND_FILE, "w", encoding="utf-8") as f:
        json.dump(doc, f, ensure_ascii=False, indent=2)
        f.write("\n")
    codes = sum(len(r["specs"]) for r in found_records)
    print(f"found: {len(found_records)} models searched, {codes} codes with evidence, "
          f"{len(doc['models'])} in {os.path.relpath(enrich.FOUND_FILE)}")


if __name__ == "__main__":
    main()
