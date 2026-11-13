#!/usr/bin/env python3
"""Turn the CPUID / brand-name table of one published article into JSON.

The FIT panel names a microcode update by its CPUID; a bench wants to know
which processors that is. Intel publishes no machine-readable list, so the
list is taken from the table in

    https://comsystem-tlt.ru/obzori/primenenie-cpuid-na-praktike-dlja-zameni-soc--kombajnov-

and written to
`Modules/FITTool/Sources/FITTool/Resources/IntelCPUIDBrandNames.json`.

The table is hand-written: cells number their sub-groups ("1.", "2:"),
S-SPECs precede some names, many lines list models after one shared prefix
("Intel Xeon Gold 5115, 5118, ..."), and a few lines are simply garbled.
The rules below read the regular part; `CORRECTIONS` fixes the rest by
hand, each fix keyed by the exact text it replaces, so a fix that no longer
matches the page fails loudly instead of being silently skipped.

Nothing is invented: a model the page does not name is not added, and an
obvious slip of the page (a truncated number, a duplicate) is either
removed or left as written — never guessed into another model.

A CPUID the article has no row for can be given one in `extra-entries.json`
beside this file, every fact with the page it came from; such an entry is
written after the article's with `"source": "extra"`, and refused once the
article has the CPUID itself.

The article gives an S-SPEC for about a third of its models; `enrich.py`
adds what Intel ARK and Wikipedia give for the rest, where the code can be
put under the right CPUID, and says so for each code it adds.

Usage:
    Skills/update-cpuid-brand-names/scripts/import.py [page.html] [--retrieved YYYY-MM-DD]
                                        [--cache DIR]

Without a file it downloads the page. `--cache` keeps what it downloads
(Wikipedia, Intel's release notes) for the next run. stdlib only; the run is
a diff to review.
"""

import datetime
import html
import json
import os
import re
import sys
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import enrich as enrichment  # noqa: E402 — the file beside this one

URL = ("https://comsystem-tlt.ru/obzori/"
       "primenenie-cpuid-na-praktike-dlja-zameni-soc--kombajnov-")
EXTRA = os.path.join(os.path.dirname(os.path.abspath(__file__)), "extra-entries.json")
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..",
                   "Modules", "FITTool", "Sources", "FITTool", "Resources",
                   "IntelCPUIDBrandNames.json")

# Whole-line replacements in the brand-name cell, applied after the line is
# cleaned (marks, numbering and non-breaking spaces gone). Each must match
# exactly once.
CORRECTIONS = {
    # The family name sits between the prefix and the models.
    "Intel Xeon W-1300 Processors W-1390P, W-1390, W-1390T, W-1370P, W-1370, W-1350P, W-1350":
        "Intel Xeon W-1390P, W-1390, W-1390T, W-1370P, W-1370, W-1350P, W-1350",
    # "W-1290 E, TE" is W-1290E and W-1290TE.
    "Intel Xeon W-10855, W-1290 E, TE processors":
        "Intel Xeon W-10855, W-1290E, W-1290TE",
    # A missing space.
    "Intel XeonE-2388G, E-2378G, E-2378, E-2386G, E-2356G, E-2336, E-2374G, E-2334, E-2324G, E-2314, E-2378G, E-2378, E-2386G, E-2356G, E-2336, E-2374G, E-2334, E-2324G, E-2314 processor":
        "Intel Xeon E-2388G, E-2378G, E-2378, E-2386G, E-2356G, E-2336, E-2374G, E-2334, E-2324G, E-2314",
    # Three vendors' lines run together with a full stop.
    "Intel Pentium Processor J6426, N6415, Intel Celeron Processor N6210, J6413, J6412, N6211. Intel Atom Processor x6211E, x6212RE, x6413E, x6414RE, x6425E, x6425RE, x6427FE, x6200FE":
        "Intel Pentium J6426, N6415, Intel Celeron N6210, J6413, J6412, N6211, Intel Atom x6211E, x6212RE, x6413E, x6414RE, x6425E, x6425RE, x6427FE, x6200FE",
}

# Models the page writes that are not a model: "E5-260" is a cut-off number
# (E5-2603? E5-2608L?) — which one is not ours to guess.
# Models the page names that Intel never sold under that name, with nothing
# Intel did sell close enough to stand for them (checked on ARK, 2026-11):
# the i5-10110Y is an i3 in Intel's line (i3-10110Y), the D-1564N has no
# neighbour at all.
DROP = {"Intel Xeon E5-260 v3", "Intel Core i5-10110Y", "Intel Xeon D-1564N"}

# Models the page misnames, each with the model Intel sells under the name
# closest to it — same number, the prefix or suffix the page lost — read on
# ARK's ordering tab (2026-11). Each must be met on the page.
RENAME = {
    # ARK SKU 189122: "Core i7-9800X X-series", SREZ9, M0. No i9-9800X exists.
    "Intel Core i9-9800X": "Intel Core i7-9800X",
    # ARK SKU 121500: the Kaby Lake-X i5-7640X, SR3FR. No i7-7640X exists.
    "Intel Core i7-7640X": "Intel Core i5-7640X",
    # ARK SKU 201908: "Xeon W-10855M", SRH8M, R1. No W-10855 exists.
    "Intel Xeon W-10855": "Intel Xeon W-10855M",
    # ARK SKU 122998: "Xeon D-1533N", SR3KS, A1. No plain D-1533 exists.
    "Intel Xeon D-1533": "Intel Xeon D-1533N",
    # ARK SKU 91559: "Pentium Processor D1519", SR2DM, V2, in the D-1500
    # family. No Xeon D-1519 exists.
    "Intel Xeon D-1519": "Intel Pentium D1519",
}

# Lines the page writes where only a series is named, not its models.
SERIES = {"Intel Xeon Platinum", "Intel Xeon Platinum 8300", "Intel Xeon Gold 6300",
          "Intel Xeon Gold 5300", "Intel Xeon Silver 4300"}

# The product-family cell of A0660/A0661 has its numbering in mid-line.
FAMILY_CORRECTIONS = {
    "10th Generation Intel Core (A0) 2.Processor Family": "10th Generation Intel Core Processor Family (A0)",
}

SEGMENTS = {
    "server": "Server", "amt server": "Server", "desktop": "Desktop",
    "mobile": "Mobile", "embedded": "Embedded", "iot/embedded": "Embedded",
    "workstation": "Workstation", "networking": "Networking",
}

SSPEC = r"(?:SR[0-9A-Z]{3}|Q[0-9A-Z]{3})"
NUMBERING = re.compile(r"^\d+(?:\s*,\s*\d+)*\s*[.:]?\s+|^\d+(?:\s*,\s*\d+)*\s*[.:]\s*")


def clean(text):
    text = html.unescape(text).replace("\xa0", " ")
    text = text.replace("®", "").replace("™", "")
    return re.sub(r"[ \t]+", " ", text).strip()


def lines(cell):
    out = []
    for line in cell.split("\n"):
        line = clean(line)
        line = NUMBERING.sub("", line).strip()
        if line:
            out.append(line)
    return out


def code_names(cell):
    """A line that only qualifies the one before it — "(Core Series 1)",
    "Re-refresh" — belongs to it."""
    out = []
    for line in lines(cell):
        if out and (line.startswith("(") or line.startswith("Re-")):
            out[-1] += " " + line
        else:
            out.append(line)
    return out


# The core architectures the article writes in brackets after a code name:
# "Alder Lake S (Golden Cove, Gracemont)". They name the cores, not the part,
# so they go to `cores` and leave the code name; whatever else the brackets
# say ("Core Series 1", "Broadwell DE", "no SGX") stays where it was.
CORE_ARCHITECTURES = ["Golden Cove", "Raptor Cove", "Gracemont", "Goldmont", "Tremont"]


def split_cores(name):
    """`Alder Lake S (Golden Cove, Gracemont)` → (`Alder Lake S`,
    [`Golden Cove`, `Gracemont`]); `Apollo Lake (Goldmont - no SGX)` →
    (`Apollo Lake (no SGX)`, [`Goldmont`])."""
    m = re.match(r"^(.*?)\s*\(([^()]*)\)\s*$", name)
    if not m:
        return name, []
    parts = [p.strip() for p in re.split(r"[,/]|\s+-\s+", m.group(2)) if p.strip()]
    cores = [p for p in parts if p in CORE_ARCHITECTURES]
    if not cores:
        return name, []
    rest = [p for p in parts if p not in CORE_ARCHITECTURES]
    return (f"{m.group(1)} ({', '.join(rest)})" if rest else m.group(1)), cores


def cells_of(page):
    table = re.search(r"<table.*?</table>", page, re.S).group(0)
    for row in re.findall(r"<tr.*?</tr>", table, re.S)[1:]:
        cells = re.findall(r"<t[dh][^>]*>(.*?)</t[dh]>", row, re.S)
        cells = [re.sub(r"<br\s*/?>", "\n", c) for c in cells]
        cells = [re.sub(r"</p>\s*<p[^>]*>", "\n", c) for c in cells]
        yield [html.unescape(re.sub(r"<[^>]+>", "", c)) for c in cells]


def canonical(name):
    """One way of writing a model, whichever way the page wrote it."""
    name = re.sub(r"\b[Pp]rocessors?\b", "", name)
    name = re.sub(r"\s+", " ", name).strip(" ,.")
    name = re.sub(r"^Intel Mobile ", "Intel ", name)
    name = re.sub(r"\b(i[3579]) (\d)", r"\1-\2", name)          # i7 6600U
    if not name.startswith("Intel"):
        if re.match(r"^(i[3579]|m[357])-", name) or name.startswith("Ultra "):
            name = "Intel Core " + name
        elif re.match(r"^(Celeron|Pentium|Atom|Xeon|Core)\b", name):
            name = "Intel " + name
    name = re.sub(r"^Intel (i[3579]|m[357])-", r"Intel Core \1-", name)
    name = re.sub(r"^Intel (?:X-series |Extreme Edition )", "Intel ", name)
    name = re.sub(r"^Intel Core (?:X-series |Extreme Edition )", "Intel Core ", name)
    # A part sold as "Intel Processor N100" has no brand but the word.
    name = re.sub(r"^Intel (?=[A-Z]?\d)", "Intel Processor ", name)
    if re.match(r"^N\d+$", name):
        name = "Intel Processor " + name
    # "Intel Xeon v3 E5-2695" is sold as "Intel Xeon E5-2695 v3".
    m = re.match(r"^(Intel Xeon) (v\d) (.+)$", name)
    if m:
        name = f"{m.group(1)} {m.group(3)} {m.group(2)}"
    return name


MET = set()                                       # RENAME and DROP keys the page has


def processors(cell):
    """[(name, [sspec])] in the order the page lists them."""
    result = []
    for line in lines(cell):
        line = CORRECTIONS.pop(line, line)
        # What is said about a part rather than its name.
        line = re.sub(r"\s*\((?:with IPU|Alder Lake P|Q2DW ES full name)\)", "", line)
        line = re.sub(r" with Radeon [^,]*graphics", "", line)
        line = re.sub(r"\(([^()]*)\)", r"\1", line)               # SRGL2 (Intel Pentium 6405U)
        m = re.match(rf"^((?:{SSPEC}\s*,?\s*)+)(.*)$", line)
        sspecs = re.findall(SSPEC, m.group(1)) if m else []
        rest = m.group(2) if m else line
        prefix = None
        for item in [i.strip() for i in rest.split(",")]:
            item = re.sub(r"\s+processors?$", "", item, flags=re.I).strip()
            if not item:
                continue
            words = item.split()
            if len(words) == 1 and prefix:
                full = f"{prefix} {item}"
            else:
                full = item
                if re.match(r"^Intel\b", item):
                    stripped = re.sub(r"\b[Pp]rocessors?\b", "", item).split()
                    prefix = " ".join(stripped[:-1])
            for variant in full.split("/"):
                if variant != full and not variant.startswith("Intel"):
                    # J3355/J3355E: the second shares the first's prefix.
                    variant = full.split("/")[0].rsplit(" ", 1)[0] + " " + variant
                name = canonical(variant)
                if name in RENAME:
                    MET.add(name)
                    name = RENAME[name]
                if name in DROP:
                    MET.add(name)
                    continue
                result.append((name, sspecs))
    return result


def merged(pairs):
    """A model listed twice keeps one row, with every S-SPEC either named."""
    order, specs = [], {}
    for name, sspecs in pairs:
        if name not in specs:
            order.append(name)
            specs[name] = []
        for s in sspecs:
            if s not in specs[name]:
                specs[name].append(s)
    return [dict({"name": n, "sSpec": specs[n]}, **({"series": True} if n in SERIES else {}))
            for n in order]


def unique(items):
    seen, out = set(), []
    for i in items:
        if i not in seen:
            seen.add(i)
            out.append(i)
    return out


def extra_entries(entries):
    """The entries of `extra-entries.json`: CPUIDs the article has no row for,
    each with the pages its facts came from. One whose CPUID the article has
    is refused — the article's row stands, and two rows would split it."""
    with open(EXTRA, encoding="utf-8") as f:
        extra = json.load(f)["entries"]
    have = {c for e in entries for c in e["cpuids"]}
    out = []
    for e in extra:
        if have & set(e["cpuids"]):
            sys.exit(f"extra-entries.json: {e['cpuids']} is in the article now — take it out")
        if not e.get("evidence"):
            sys.exit(f"extra-entries.json: {e['cpuids']} has no evidence")
        out.append({
            "cpuids": e["cpuids"], "codeNames": e["codeNames"], "cores": e.get("cores", []),
            "productFamilies": e.get("productFamilies", []), "steppings": e.get("steppings", []),
            "segments": e.get("segments", []),
            "processors": [{"name": p["name"], "sSpec": list(p.get("sSpec", []))} for p in e["processors"]],
            "source": "extra",
        })
    return out


def main(argv):
    retrieved = datetime.date.today().isoformat()
    cache = None
    if "--cache" in argv:
        i = argv.index("--cache")
        cache = argv[i + 1]
        del argv[i:i + 2]
    if "--retrieved" in argv:
        i = argv.index("--retrieved")
        retrieved = argv[i + 1]
        del argv[i:i + 2]
    if len(argv) > 1:
        with open(argv[1], encoding="utf-8") as f:
            page = f.read()
    else:
        request = urllib.request.Request(URL, headers={"User-Agent": "Mozilla/5.0"})
        page = urllib.request.urlopen(request).read().decode("utf-8")

    entries = []
    for code, family, brands, segment, cpuid in cells_of(page):
        families = [FAMILY_CORRECTIONS.get(f, f) for f in lines(family)]
        steppings = unique(re.findall(r"\b([A-Z][0-9])\b",
                                      " ".join(re.findall(r"\(([^)]*)\)", family)
                                               + [l for l in clean(family).split("\n")
                                                  if re.match(r"^\s*\d\.\s*[A-Z]\d\s*$", l)]
                                               + [clean(family)])))
        families = [re.sub(r"\s*\((?:[A-Z]\d(?:\s*(?:,|or)\s*[A-Z]\d)*)\)?\s*$", "", f).strip()
                    for f in families]
        families = [re.sub(r"\s*\([^)]*$", "", f).strip() for f in families]
        families = [f for f in families
                    if f and not re.fullmatch(r"\(?[A-Z]\d\)?|\(?\d(?:,\d)*\s*[A-Z]\d", f)]
        codes = code_names(code)
        # A code name written into the family column.
        codes += [f for f in families if f.endswith("Lake-N") and f not in codes]
        families = [f for f in families if not f.endswith("Lake-N")]
        split = [split_cores(c) for c in codes]
        codes = [name for name, _ in split]
        cores = unique(core for _, found in split for core in found)
        entries.append({
            "cpuids": [c.upper() for c in re.findall(r"[0-9A-Fa-fX]{5}", clean(cpuid))],
            "codeNames": unique(codes),
            "cores": cores,
            "productFamilies": unique(families),
            "steppings": steppings,
            "segments": unique(SEGMENTS[s.lower()] for s in
                               (re.sub(r"\(.*?\)", "", l).strip() for l in lines(segment))
                               if s),
            "processors": merged(processors(brands)),
        })
    unmet = (set(RENAME) | DROP) - MET
    if unmet:
        sys.exit("renames and drops that match nothing on the page:\n  " + "\n  ".join(sorted(unmet)))
    if CORRECTIONS:
        sys.exit("corrections that match nothing on the page:\n  "
                 + "\n  ".join(CORRECTIONS))

    entries += extra_entries(entries)

    added = enrichment.enrich(entries, cache=cache)

    document = {
        "source": {
            "url": URL,
            "title": "Применение CPUID на практике для замены SoC-комбайнов",
            "retrieved": retrieved,
        },
        "about": ("CPUID (family-model-stepping, as a microcode update's header "
                  "and its file name write it) to the processors sold with it. "
                  "An X in a CPUID stands for any one hexadecimal digit. The "
                  "list is the source's and is not complete; a CPUID can appear "
                  "in more than one entry. An entry with source \"extra\" is not "
                  "the article's: it is from Skills/update-cpuid-brand-names/"
                  "scripts/extra-entries.json, which gives each fact's page. "
                  "sSpec lists the article's codes and "
                  "those added from sSpecSources; sSpecSource says, for each "
                  "added code, which."),
        "sSpecSources": added["sources"],
        "entries": entries,
    }
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w", encoding="utf-8") as f:
        json.dump(document, f, ensure_ascii=False, indent=2)
        f.write("\n")
    processors_ = [p for e in entries for p in e["processors"] if not p.get("series")]
    print(f"{len(entries)} entries, {len(processors_)} processors, "
          f"{sum(1 for p in processors_ if not p['sSpec'])} without an S-SPEC; "
          f"added {added['counts']} -> {os.path.relpath(OUT)}")


if __name__ == "__main__":
    main(sys.argv)
