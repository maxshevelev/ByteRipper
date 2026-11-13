"""S-SPECs the article does not give, from Intel ARK, Wikipedia and what
`Skills/find-sspec` found.

An S-SPEC belongs to one stepping, and a stepping to one CPUID — so a code is
only worth adding where it can be put under the right CPUID. The sources:

- Intel ARK, the manufacturer's own list: each code with its stepping. ARK
  cannot be fetched by a script (it answers 403), so what was read from it is
  kept beside this file in `ark-sspec.json`, with the page each code came from.
- Wikipedia's "List of Intel … processors" pages, fetched here at a fixed
  revision. Most of their rows give a code but no stepping.
- `found-sspec.json` beside this file, written by `Skills/find-sspec`: codes
  with their evidence — an Intel document other than ARK's ordering tab
  (`intel`), an S-SPEC database page (`database`), or the marking on the
  package read from photographs of different chips (`marking`). Read before
  Wikipedia, as ARK is: each code there was checked against its page.

A stepping is turned into a CPUID by Intel's own table — the release notes of
`github.com/intel/Intel-Linux-Processor-Microcode-Data-Files`, which list
F-M-S and stepping side by side — together with the steppings the article
writes for its rows.

The rules, in order:

1. The article's own codes stay as they are.
2. A code with a stepping (ARK, or a Wikipedia row that has one) goes under the
   one entry of that model whose CPUID has that stepping — by Intel's current
   naming first, by every name its notes ever used when that finds no one
   entry (`intel_steppings`). None, or more than one: it is left out — unless
   the model is in one entry only and no source names a stepping for that
   entry's CPUID: then it goes there, as rule 3 puts a code with no stepping.
3. A Wikipedia code without a stepping goes in only where the article lists
   the model under one CPUID — there is then nowhere else for it to go. A
   model listed under several CPUIDs gets nothing from such a row. And a page
   about one microarchitecture ("… (Broadwell-based)") gives codes only to an
   entry whose code names are of it: the article repeats Broadwell-DE Xeon D
   parts under Ice Lake D, and their codes do not belong there.
4. A found code (`found-sspec.json`) with a stepping follows rule 2; with a
   CPUID — or a stepping that fits no entry, and a CPUID — it goes under the
   one entry of that model with that CPUID; with
   neither — a marking gives neither — it follows rule 3, and the architecture
   its source names must begin one of the entry's code names ("Comet Lake"
   for "Comet Lake S"; "Broadwell" never for "Ice Lake D").

A code belongs to one model: one that is already some other model's, or that
Wikipedia writes for two models (a copy-paste slip there, as SR3B8 for both
the 8160F and the 8160M), is left out. A code never goes in twice for the
same model, and every added code says where it came from (`sSpecSource`), so the article's data and ours stay apart.
"""

import collections
import html
import json
import os
import re
import urllib.parse
import urllib.request
from html.parser import HTMLParser

HERE = os.path.dirname(os.path.abspath(__file__))
ARK_FILE = os.path.join(HERE, "ark-sspec.json")
FOUND_FILE = os.path.join(HERE, "found-sspec.json")

INTEL_NOTES_COMMIT = "bdc92abe5c499c3fd7988b76a128d05c9120a520"
INTEL_NOTES_URL = ("https://raw.githubusercontent.com/intel/"
                   "Intel-Linux-Processor-Microcode-Data-Files/"
                   f"{INTEL_NOTES_COMMIT}/releasenote.md")

# The pages that list sSpec numbers for the processors the article names, at
# the revision this file was built from.
WIKIPEDIA_PAGES = {
    "List of Intel Atom processors": 1371423471,
    "List of Intel Celeron processors": 1379493616,
    "List of Intel Core desktop processors": 1379967425,
    "List of Intel Pentium processors": 1359301244,
    "List of Intel Xeon processors (Broadwell-based)": 1362915879,
    "List of Intel Xeon processors (Cascade Lake–based)": 1362298362,
    "List of Intel Xeon processors (Coffee Lake-based)": 1339738082,
    "List of Intel Xeon processors (Comet Lake-based)": 1334627889,
    "List of Intel Xeon processors (Haswell-based)": 1344872412,
    "List of Intel Xeon processors (Ice Lake-based)": 1362298361,
    "List of Intel Xeon processors (Kaby Lake-based)": 1362915881,
    "List of Intel Xeon processors (Rocket Lake-based)": 1334626524,
    "List of Intel Xeon processors (Skylake-based)": 1377207682,
}

CODE = re.compile(r"\b(?:SR[0-9A-Z]{3}|Q[0-9A-Z]{3})\b")
USER_AGENT = "ByteRipper update-cpuid-brand-names (https://github.com/maxshevelev/ByteRipper)"


def fetch(url, cache):
    """The body of `url`, from `cache` when it is there."""
    name = os.path.join(cache, re.sub(r"[^\w.-]", "_", url)[-180:]) if cache else None
    if name and os.path.exists(name):
        with open(name, "rb") as f:
            return f.read()
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    body = urllib.request.urlopen(request, timeout=60).read()
    if name:
        os.makedirs(cache, exist_ok=True)
        with open(name, "wb") as f:
            f.write(body)
    return body


# --- Intel: stepping per CPUID ------------------------------------------------

def intel_steppings(cache, current=False):
    """{CPUID: {stepping}} from the rows `| HSX-E/EP | Cx/M1 | 06-3f-02/6f | …`.

    The notes are every release's, newest first, and a later release can
    correct an earlier one: releases up to 2022 called 06-97-05 "C0", later
    ones "H0" — which it is (ARK: the i5-12400's C0 is SRL4V, its H0 SRL5Y,
    two dies). It can also be wrong where the older one was right: since 2023
    SKX-D (06-55-04) is written "H0", where ARK and the older rows say M1. So
    two readings:

    - all (the default): every stepping any release wrote for the CPUID;
    - `current`: each product's row from the newest release that has one —
      product by product, since a release lists only the platforms it updates
      (06-4e-03's SKL-U23e, K1, is in an older release than its SKL-U/Y, D0).
      A row may write a stepping as `Dx` ("a D stepping"): that is the
      D-steppings the product's older rows name (ICX-SP's `Dx/M1`, earlier
      `D0`), or nothing.

    `enrich` places a code by the current reading first and falls back to all.
    """
    text = fetch(INTEL_NOTES_URL, cache).decode("utf-8")
    rows = collections.defaultdict(list)          # (CPUID, product) → [(release, {stepping})]
    release = 0
    for line in text.splitlines():
        if line.startswith("## "):
            release += 1
            continue
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        if len(cells) < 3:
            continue
        m = re.fullmatch(r"([0-9a-fA-F]{2})-([0-9a-fA-F]{2})-([0-9a-fA-F]{2})/[0-9a-fA-F]{2}", cells[2])
        if not m:
            continue
        family, model, stepping = (int(g, 16) for g in m.groups())
        # CPUID leaf 1 EAX: ext. family | ext. model | family | model | stepping.
        ext_family = max(family - 0xF, 0) if family >= 0xF else 0
        base_family = min(family, 0xF)
        cpuid = (ext_family << 20) | ((model >> 4) << 16) | (base_family << 8) | ((model & 0xF) << 4) | stepping
        names = {s.strip() for s in re.split(r"[/,]", cells[1])}
        rows[(f"{cpuid:X}", cells[0])].append((release, {s for s in names if re.fullmatch(r"[A-Z][0-9x]", s)}))
    table = collections.defaultdict(set)
    for (cpuid, _), seen in rows.items():
        if not current:
            table[cpuid] |= {s for _, n in seen for s in n if s[1] != "x"}
            continue
        newest = min(r for r, _ in seen)
        latest = set().union(*(n for r, n in seen if r == newest))
        older = set().union(*(n for r, n in seen if r != newest))
        for s in latest:
            if s[1] != "x":
                table[cpuid].add(s)
            else:
                table[cpuid] |= {o for o in older if o[0] == s[0] and o[1] != "x"}
    return table


# --- Wikipedia: tables with an sSpec column -----------------------------------

class _Tables(HTMLParser):
    def __init__(self):
        super().__init__()
        self.tables, self.stack = [], []

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if tag == "table":
            self.stack.append({"rows": [], "row": None, "cell": None})
        elif not self.stack:
            return
        elif tag == "tr":
            self.stack[-1]["row"] = []
        elif tag in ("td", "th") and self.stack[-1]["row"] is not None:
            span = lambda k: int(re.sub(r"\D", "", attrs.get(k) or "1") or 1)
            self.stack[-1]["cell"] = {"text": "", "rows": span("rowspan"), "cols": span("colspan")}
        elif tag == "br" and self.stack[-1]["cell"] is not None:
            self.stack[-1]["cell"]["text"] += " "

    def handle_endtag(self, tag):
        if not self.stack:
            return
        t = self.stack[-1]
        if tag in ("td", "th") and t["cell"] is not None:
            t["row"].append(t["cell"])
            t["cell"] = None
        elif tag == "tr" and t["row"] is not None:
            t["rows"].append(t["row"])
            t["row"] = None
        elif tag == "table":
            self.tables.append(self.stack.pop()["rows"])

    def handle_data(self, data):
        if self.stack and self.stack[-1]["cell"] is not None:
            self.stack[-1]["cell"]["text"] += data


def _grid(rows):
    """Rows with every rowspan and colspan written out."""
    out, pending = [], {}
    for row in rows:
        line, column, cells = [], 0, list(row)
        while cells or any(k >= column for k in pending):
            if column in pending:
                text, left = pending[column]
                line.append(text)
                if left > 1:
                    pending[column] = (text, left - 1)
                else:
                    del pending[column]
                column += 1
                continue
            if not cells:
                break
            cell = cells.pop(0)
            text = re.sub(r"\[[^\]]*\]", "", re.sub(r"\s+", " ", html.unescape(cell["text"]))).strip()
            for _ in range(cell["cols"]):
                line.append(text)
                if cell["rows"] > 1:
                    pending[column] = (text, cell["rows"] - 1)
                column += 1
        out.append(line)
    return out


def _model_tokens(text):
    """`Xeon E5-2695 v3` → {"E5-2695V3", "XEON"}; compared without spaces."""
    text = re.sub(r"\s+(v\d)\b", r"\1", text)
    return {t.upper() for t in re.findall(r"[A-Za-z0-9][A-Za-z0-9-]*", text)}


def wikipedia_rows(cache):
    """[(page, revid, model cell, [codes], [steppings])]."""
    rows = []
    for title, revid in WIKIPEDIA_PAGES.items():
        url = ("https://en.wikipedia.org/w/api.php?action=parse&prop=text&format=json&oldid="
               + str(revid))
        page = json.loads(fetch(url, cache))["parse"]
        parser = _Tables()
        parser.feed(page["text"]["*"])
        for table in parser.tables:
            grid = _grid(table)
            header = next((k for k, r in enumerate(grid[:4])
                           if any(re.search(r"sSpec", c, re.I) for c in r)), None)
            if header is None:
                continue
            heads = grid[header]
            model = next((j for j, c in enumerate(heads) if re.fullmatch(r"Model( number)?", c)), None)
            spec = [j for j, c in enumerate(heads) if re.search(r"sSpec", c, re.I)]
            step = [j for j, c in enumerate(heads) if re.search(r"stepping", c, re.I)]
            if model is None:
                continue
            for r in grid[header + 1:]:
                if model >= len(r):
                    continue
                codes = [c for j in spec if j < len(r) for c in CODE.findall(r[j])]
                if codes:
                    steppings = [s for j in step if j < len(r) for s in re.findall(r"\b[A-Z]\d\b", r[j])]
                    rows.append((title, revid, r[model], codes, steppings))
    return rows


# --- Putting a code under its entry -------------------------------------------

def _token(name):
    """The part of our name a list writes in its model column."""
    n = re.sub(r"^Intel (Core |Xeon |Celeron |Pentium |Atom |Processor )?"
               r"((Gold|Silver|Platinum|Bronze|Ultra) )?", "", name)
    return re.sub(r"\s+(v\d)$", r"\1", n).upper()


def enrich(entries, cache=None, log=print):
    every = intel_steppings(cache)
    current = intel_steppings(cache, current=True)

    def entry_steppings(entry, table):
        found = set(entry["steppings"])
        for c in entry["cpuids"]:
            found |= table.get(c, set())
        return found

    with open(ARK_FILE, encoding="utf-8") as f:
        ark = json.load(f)
    ark_by_model = {item["model"]: item["specs"] for item in ark["models"]}

    # Rule 6, first half: a model the article lists only under CPUIDs it is
    # not sold on moves to the one entry that fits it — whose stepping ARK
    # gives the model, and which already lists a model of its series (the
    # name up to its first two digits: "Xeon D-15", "Core i7-85"). None, or
    # several: it stays.
    def series(name):
        m = re.match(r"(.*?[- ][A-Za-z]*\d\d)", name)
        return m.group(1) if m else name

    relocated = []
    for e in entries:
        for p in list(e["processors"]):
            name = p["name"]
            steps = {s["stepping"] for s in ark_by_model.get(name, ()) if s.get("stepping")}
            if p.get("series") or p["sSpec"] or not steps or steps & entry_steppings(e, every):
                continue
            if any(steps & entry_steppings(e2, every) for e2 in entries
                   if e2 is not e and any(q["name"] == name for q in e2["processors"])):
                continue                                 # placed elsewhere already: second half
            fits = [e2 for e2 in entries if e2 is not e and steps & entry_steppings(e2, every)
                    and any(series(q["name"]) == series(name) for q in e2["processors"])]
            if len(fits) == 1:
                e["processors"].remove(p)
                fits[0]["processors"].append({"name": name, "sSpec": []})
                relocated.append(f"{name} {'/'.join(e['cpuids'])} → {'/'.join(fits[0]['cpuids'])} "
                                 f"(ARK {'/'.join(sorted(steps))})")
    for r in relocated:
        log(f"  moved: {r}")

    places = collections.defaultdict(list)          # model → [(entry, processor)]
    for e in entries:
        for p in e["processors"]:
            if not p.get("series"):
                places[p["name"]].append((e, p))

    def known(name):
        return {c for _, p in places[name] for c in p["sSpec"]}

    def owner(code):
        return {p["name"] for e in entries for p in e["processors"] if code in p["sSpec"]}

    def add(processor, code, source):
        processor["sSpec"].append(code)
        processor.setdefault("sSpecSource", {})[code] = source

    def by_stepping(name, code, stepping, source):
        """Rule 2. True when the code was added."""
        if code in known(name):
            return False
        if owner(code):
            log(f"  {source}: {name} {code} is already {sorted(owner(code))}'s — left out")
            return False
        # Intel's current reading first: 06-97-05 was "C0" until 2022 and is
        # H0, so a C0 code fits 90672 alone. All its readings when that finds
        # no one place: SKX-D is "H0" now, its Xeon D-21xx codes ARK's M1.
        for table in (current, every):
            fits = [(e, p) for e, p in places[name] if stepping in entry_steppings(e, table)]
            if len(fits) == 1:
                break
        if not fits and len(places[name]) == 1 and not entry_steppings(places[name][0][0], every):
            # The model's one entry, whose CPUID no source gives a stepping:
            # nowhere else for the code to go, and nothing it contradicts
            # (Grand Ridge, B0664 — ARK says B0, nothing ties B0 to ID 4).
            fits = places[name]
        if len(fits) == 1:
            add(fits[0][1], code, source)
            return True
        log(f"  {source}: {name} {code} ({stepping}) fits {len(fits)} entries — left out")
        return False

    counts = collections.Counter()

    # ARK.
    for item in ark["models"]:
        if item["model"] not in places:
            log(f"  ark: {item['model']} is not in the table")
            continue
        for s in item["specs"]:
            if s.get("stepping") and by_stepping(item["model"], s["sSpec"], s["stepping"], "ark"):
                counts["ark"] += 1

    # Found by Skills/find-sspec: rule 4.
    found = {"models": []}
    if os.path.exists(FOUND_FILE):
        with open(FOUND_FILE, encoding="utf-8") as f:
            found = json.load(f)
    # A code ARK gives with a stepping is placed by that stepping, also when
    # another page repeats it without one: PCN 117408 lists the i3-8100H's
    # SR3Z7 with none, ARK says U0 — 906EA, not the 906EB the article
    # lists the model under, where rule 3 would otherwise put it.
    ark_stepping = {(item["model"], s["sSpec"]): s["stepping"]
                    for item in ark["models"] for s in item["specs"] if s.get("stepping")}
    for item in found["models"]:
        name = item["model"]
        if item["specs"] and name not in places:
            log(f"  found: {name} is not in the table")
            continue
        for s in item["specs"]:
            kinds = {e["kind"] for e in s["evidence"]}
            source = "intel" if "intel" in kinds else "database" if "database" in kinds else "marking"
            code = s["sSpec"]
            if not s.get("stepping") and not s.get("cpuid") and (name, code) in ark_stepping:
                if by_stepping(name, code, ark_stepping[(name, code)], source):
                    counts[source] += 1
                continue
            if s.get("stepping"):
                if by_stepping(name, code, s["stepping"], source):
                    counts[source] += 1
                    continue
                # A stepping Intel's notes do not name (Ice Lake D's package
                # steppings Z1/Z2, U1/U2, where the notes say B0): the CPUID
                # its source gives decides, where it gives one.
                if not s.get("cpuid"):
                    continue
            if code in known(name):
                continue
            if owner(code):
                log(f"  {source}: {name} {code} is already {sorted(owner(code))}'s — left out")
                continue
            if s.get("cpuid"):
                fits = [(e, p) for e, p in places[name]
                        if any(len(c) == len(s["cpuid"]) and
                               all(x in ("X", y) for x, y in zip(c, s["cpuid"]))
                               for c in e["cpuids"])]
                if len(fits) == 1:
                    add(fits[0][1], code, source)
                    counts[source] += 1
                else:
                    log(f"  {source}: {name} {code} ({s['cpuid']}) fits {len(fits)} entries — left out")
                continue
            where = places[name]
            arch = (s.get("architecture") or "").lower()
            if len({tuple(e["cpuids"]) for e, _ in where}) != 1:
                log(f"  {source}: {name} {code} has no stepping, and the model is under "
                    "several CPUIDs — left out")
            elif not arch or not all(any(c.lower().startswith(arch) for c in e["codeNames"])
                                     for e, _ in where):
                log(f"  {source}: {name} {code} is {s.get('architecture')!r}, the entry is "
                    f"{where[0][0]['codeNames']} — left out")
            else:
                for _, p in where:
                    if not [c for c in p["sSpec"] if c not in p.get("sSpecSource", {})]:
                        add(p, code, source)
                counts[source] += 1

    # Wikipedia.
    by_token = collections.defaultdict(list)
    models_of = collections.defaultdict(set)
    rows = wikipedia_rows(cache)
    for row in rows:
        for code in row[3]:
            # The model number alone: one page writes "Celeron G5900" or
            # "Xeon W-1250", another "G5900" or "1250" under a brand heading.
            last = re.sub(r"\s+(v\d)\b", r"\1", row[2]).split()[-1].upper()
            models_of[code].add(re.sub(r"^[A-Z]-", "", last))
    ambiguous = {c for c, m in models_of.items() if len(m) > 1}
    for c in sorted(ambiguous):
        log(f"  wikipedia: {c} is written for {sorted(models_of[c])} — left out")
    for row in rows:
        for t in _model_tokens(row[2]):
            by_token[t].append(row)
    for name, where in places.items():
        rows = by_token.get(_token(name), [])
        if not rows:
            continue
        cpuid_sets = {tuple(e["cpuids"]) for e, _ in where}
        for title, revid, _, codes, steps in rows:
            arch = re.search(r"\((.+?)[-–]based\)", title)
            if arch and not all(any(arch.group(1).lower() in c.lower() for c in e["codeNames"])
                                for e, _ in where):
                if len(cpuid_sets) == 1:
                    log(f"  wikipedia: {name} {codes} is from {title}, the entry is "
                        f"{where[0][0]['codeNames']} — left out")
                continue
            for code in codes:
                if code in known(name) or code in ambiguous:
                    continue
                if owner(code):
                    log(f"  wikipedia: {name} {code} is already {sorted(owner(code))}'s — left out")
                    continue
                if len(steps) == 1:
                    if by_stepping(name, code, steps[0], "wikipedia"):
                        counts["wikipedia"] += 1
                elif len(cpuid_sets) == 1:
                    # Rule 3: one CPUID, so one place. Each of its entries
                    # that has no code of its own gets it.
                    for _, p in where:
                        if not [c for c in p["sSpec"] if c not in p.get("sSpecSource", {})]:
                            add(p, code, "wikipedia")
                    counts["wikipedia"] += 1

    # Rule 6: a model the article lists under a CPUID it is not sold on. It
    # goes when, there, it has no code, ARK gives it steppings none of which
    # is that entry's, and another entry of it, whose stepping ARK gives, has
    # its codes — Broadwell-DE Xeon D under Ice Lake D, Skylake-X under
    # Cascade Lake, Kaby Lake R under Kaby Lake U.
    moved = []
    for e in entries:
        keep = []
        for p in e["processors"]:
            name = p["name"]
            steps = {s["stepping"] for s in ark_by_model.get(name, ()) if s.get("stepping")}
            placed = any(p2["sSpec"] and steps & entry_steppings(e2, every)
                         for e2, p2 in places[name] if e2 is not e)
            if (not p.get("series") and not p["sSpec"] and steps and placed
                    and not steps & entry_steppings(e, every)):
                moved.append(f"{name} ({'/'.join(e['cpuids'])}, ARK {'/'.join(sorted(steps))})")
                continue
            keep.append(p)
        e["processors"] = keep
    for m in moved:
        log(f"  moved: {m} is under its other CPUID — taken out")
    counts["moved"] = len(moved) + len(relocated)
    found_sources = {
        "intel": {"about": "an Intel document other than ARK's ordering tab (a specification "
                           "update, a datasheet, a product change notification) that gives the "
                           "code for the model; the page per code is in "
                           "Skills/update-cpuid-brand-names/scripts/found-sspec.json"},
        "database": {"about": "an S-SPEC database page that gives the code with its stepping or "
                              "CPUID; the page per code is in "
                              "Skills/update-cpuid-brand-names/scripts/found-sspec.json"},
        "marking": {"about": "the code printed on the package beside the model number, read from "
                             "at least two photographs of different chips on different sites; the "
                             "photographs per code are in "
                             "Skills/update-cpuid-brand-names/scripts/found-sspec.json"},
    }
    return {
        "counts": dict(counts),
        "sources": {
            "ark": {"about": "Intel ARK, the Ordering & Compliance tab of each model's page; "
                             "the URL per model is in Skills/update-cpuid-brand-names/scripts/ark-sspec.json",
                    "retrieved": ark["retrieved"]},
            "wikipedia": {"pages": [{"title": t, "revid": r,
                                     "url": "https://en.wikipedia.org/w/index.php?oldid=" + str(r)}
                                    for t, r in WIKIPEDIA_PAGES.items()]},
            **{k: v for k, v in found_sources.items() if counts[k]},
            "steppings": {"about": "stepping per CPUID, from Intel's microcode release notes",
                          "url": INTEL_NOTES_URL},
        },
    }
