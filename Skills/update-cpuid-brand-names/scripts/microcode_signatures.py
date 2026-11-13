#!/usr/bin/env python3
"""Which Intel microcode updates serve several CPUIDs, from the updates themselves.

An Intel microcode update names one processor in its header and may name more
in an extended signature table after its data (Intel SDM vol. 3A, §10.11.2):
one update, the same bytes, for every processor listed. The collection at
`github.com/platomav/CPUMicrocodes` files such an update once under each
processor it serves — `cpuB06F2_…`, `cpuB06F5_…` — each copy with its own
CPUID in the header and the same table after the data. The file names say
nothing of it; the files do.

This reads every Intel file of the collection at one commit, groups the copies
of one update by the bytes of its data, and writes

    Modules/FITTool/Sources/FITTool/Resources/IntelMicrocodeSignatures.json

    {"source": {"repository", "commit", "retrieved"},
     "updates": [{"revision": "3E", "date": "2025-10-12",
                  "signatures": [{"cpuid": "90672", "platforms": "07"}, …],
                  "files": ["Intel/cpu90672_plat07_ver0000003E_2025-10-12_PRD_….bin", …]}]}

— only the updates whose table names more than one CPUID. The FIT panel's
processors popover says which CPUIDs share a CPUID's microcode, and the Add
Microcode form shows and searches a file's other CPUIDs, from this.

Usage:
    microcode_signatures.py [--cache DIR] [--commit SHA]

Without --commit it reads the collection's current master and pins what it
read. `--cache` keeps the downloaded files (≈ 40 MB) for the next run.
stdlib only; the run is a diff to review.
"""

import argparse
import datetime
import hashlib
import json
import os
import struct
import sys
import urllib.request

REPO = "platomav/CPUMicrocodes"
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..",
                   "Modules", "FITTool", "Sources", "FITTool", "Resources",
                   "IntelMicrocodeSignatures.json")
HEADER = struct.Struct("<IiIIIIIII")          # version, revision, date, signature, checksum,
                                              # loader, processor flags, data size, total size


def get(url, cache=None):
    name = None
    if cache:
        name = os.path.join(cache, url.replace("://", "_").replace("/", "_"))
        if os.path.exists(name):
            with open(name, "rb") as f:
                return f.read()
    request = urllib.request.Request(url, headers={"User-Agent": "ByteRipper-update-skill"})
    with urllib.request.urlopen(request, timeout=60) as response:
        body = response.read()
    if name:
        os.makedirs(cache, exist_ok=True)
        with open(name, "wb") as f:
            f.write(body)
    return body


def parse(data):
    """(revision, date, data bytes, [(cpuid, platforms)]) of one update file.

    The header's own signature first, then the extended table's, each once.
    """
    (version, revision, date, signature, _checksum, _loader, flags,
     data_size, total_size) = HEADER.unpack_from(data, 0)
    if version != 1:
        raise ValueError(f"header version {version}")
    data_size = data_size or 2000            # SDM: 0 means 2000 bytes of data,
    total_size = total_size or 2048          # and a 2048-byte update
    body = data[48:48 + data_size]
    signatures = [(signature, flags)]
    if total_size > 48 + data_size:
        offset = 48 + data_size
        count, = struct.unpack_from("<I", data, offset)
        for i in range(count):
            sig, pf, _ = struct.unpack_from("<III", data, offset + 20 + 12 * i)
            if (sig, pf) not in signatures:
                signatures.append((sig, pf))
    # The date field is BCD mmddyyyy: 0x10122025 is 2025-10-12.
    day = f"{date & 0xFFFF:04x}-{date >> 24 & 0xFF:02x}-{date >> 16 & 0xFF:02x}"
    return revision & 0xFFFFFFFF, day, body, signatures


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--cache")
    parser.add_argument("--commit")
    args = parser.parse_args()

    commit = args.commit
    if not commit:
        head = json.loads(get(f"https://api.github.com/repos/{REPO}/commits/master"))
        commit = head["sha"]
    tree = json.loads(get(f"https://api.github.com/repos/{REPO}/git/trees/{commit}?recursive=1",
                          args.cache))
    if tree.get("truncated"):
        sys.exit("the tree listing is truncated")
    paths = sorted(n["path"] for n in tree["tree"]
                   if n["type"] == "blob" and n["path"].startswith("Intel/cpu")
                   and n["path"].endswith(".bin"))

    updates = {}                                  # sha256 of the data → update
    for i, path in enumerate(paths):
        data = get(f"https://raw.githubusercontent.com/{REPO}/{commit}/{path}", args.cache)
        try:
            revision, day, body, signatures = parse(data)
        except (ValueError, struct.error) as error:
            print(f"  {path}: not read — {error}", file=sys.stderr)
            continue
        key = hashlib.sha256(body).hexdigest()
        update = updates.setdefault(key, {"revision": f"{revision:X}", "date": day,
                                          "signatures": [], "files": []})
        for sig, pf in signatures:
            item = {"cpuid": f"{sig:X}", "platforms": f"{pf:02X}"}
            if item not in update["signatures"]:
                update["signatures"].append(item)
        update["files"].append(path)
        if (i + 1) % 100 == 0:
            print(f"  {i + 1}/{len(paths)}", file=sys.stderr)

    shared = [u for u in updates.values() if len({s["cpuid"] for s in u["signatures"]}) > 1]
    for u in shared:
        u["signatures"].sort(key=lambda s: (len(s["cpuid"]), s["cpuid"], s["platforms"]))
        u["files"].sort()
    shared.sort(key=lambda u: (u["signatures"][0]["cpuid"], u["revision"]))
    document = {
        "source": {"repository": f"https://github.com/{REPO}", "commit": commit,
                   "retrieved": datetime.date.today().isoformat()},
        "about": ("Intel microcode updates whose extended signature table names more than one "
                  "CPUID, read from the files of the collection at the commit given: one update, "
                  "the same data, for each CPUID and platform set listed. files are the "
                  "collection's copies of it, one per CPUID it serves."),
        "updates": shared,
    }
    with open(OUT, "w", encoding="utf-8") as f:
        json.dump(document, f, ensure_ascii=False, indent=2)
        f.write("\n")
    print(f"{len(paths)} files, {len(updates)} updates, {len(shared)} serve several CPUIDs "
          f"-> {os.path.relpath(OUT)}")


if __name__ == "__main__":
    main()
