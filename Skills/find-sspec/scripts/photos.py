#!/usr/bin/env python3
"""Photographs of a processor's package, downloaded for reading its marking.

The marking on an Intel package is the one place a code is printed beside the
model it was sold as:

    INTEL® CORE™ i5          brand
    i5-10500                 model
    SRH3A 3.10GHZ            S-SPEC (and clock)
    X122J379  (e4)           FPO / lot — one per batch of chips; e4 is lead-free

Marketplaces (eBay, Yahoo Auctions, Mercari, shops) photograph the chip they
sell. eBay and the S-SPEC databases refuse a script (403); Bing's image search
does not, and its results carry each image's direct URL and the page it is on.
This script searches, downloads the images into `--out`, drops exact
duplicates, and writes `index.json`:

    [{"file": "03.jpg", "sha256": "…", "image": "<image URL>",
      "page": "<page URL>", "host": "<page host>", "title": "<page title>"}]

Nothing is read from the images here — a model reads them (`SKILL.md`,
"Photographs"). The files are untrusted data: images only, kept in their own
directory, never opened by anything but an image viewer.

Usage:
    photos.py "Intel Core i5-10500" --out DIR [--max 16] [--query '"i5-10500" SR' …]

Without --query the searches are built from the model number:
`"i5-10500" intel processor` and `"i5-10500" sspec`.

stdlib only.
"""

import argparse
import hashlib
import html
import json
import os
import re
import sys
import urllib.parse
import urllib.request

USER_AGENT = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 "
              "(KHTML, like Gecko) Version/17.0 Safari/605.1.15")
MAGIC = [(b"\xff\xd8\xff", "jpg"), (b"\x89PNG\r\n\x1a\n", "png"),
         (b"GIF8", "gif"), (b"RIFF", "webp")]
LIMIT = 8 * 1024 * 1024


def get(url, timeout=20):
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT,
                                                   "Accept-Language": "en,de;q=0.8"})
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return response.read(LIMIT + 1)


def queries_for(model):
    """`Intel Core i5-10500` → `"i5-10500" intel processor`, `"i5-10500" sspec`."""
    words = model.split()
    number = words[-1]
    if re.fullmatch(r"v\d", number) and len(words) > 1:   # Xeon E5-2690 v3
        number = f"{words[-2]} {number}"
    return [f'"{number}" intel processor', f'"{number}" sspec']


def bing(query, first=1):
    """[(image URL, page URL, title)] from one page of Bing's image results."""
    url = ("https://www.bing.com/images/search?form=HDRSC2&first=" + str(first)
           + "&q=" + urllib.parse.quote(query))
    text = get(url).decode("utf-8", "replace")
    found = []
    for raw in re.findall(r'\sm="(\{[^"]*\})"', text):
        try:
            meta = json.loads(html.unescape(raw))
        except ValueError:
            continue
        if meta.get("murl"):
            found.append((meta["murl"], meta.get("purl") or "", meta.get("t") or ""))
    return found


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("model")
    parser.add_argument("--out", required=True)
    parser.add_argument("--max", type=int, default=16, help="images to keep")
    parser.add_argument("--query", action="append",
                        help="a search of your own; may be given more than once")
    args = parser.parse_args()

    os.makedirs(args.out, exist_ok=True)
    index_path = os.path.join(args.out, "index.json")
    index = json.load(open(index_path, encoding="utf-8")) if os.path.exists(index_path) else []
    seen_images = {i["image"] for i in index}
    seen_hashes = {i["sha256"] for i in index}

    candidates = []
    for query in args.query or queries_for(args.model):
        try:
            candidates += bing(query)
        except Exception as error:                      # noqa: BLE001 — report and go on
            print(f"search failed: {query}: {error}", file=sys.stderr)

    kept = failed = duplicate = 0
    for image, page, title in candidates:
        if kept >= args.max:
            break
        if image in seen_images:
            continue
        seen_images.add(image)
        try:
            body = get(image)
        except Exception:                               # noqa: BLE001
            failed += 1
            continue
        kind = next((k for m, k in MAGIC if body.startswith(m)), None)
        if kind is None or len(body) > LIMIT or len(body) < 4096:
            failed += 1
            continue
        digest = hashlib.sha256(body).hexdigest()
        if digest in seen_hashes:
            duplicate += 1
            continue
        seen_hashes.add(digest)
        name = f"{len(index) + 1:02d}.{kind}"
        with open(os.path.join(args.out, name), "wb") as f:
            f.write(body)
        index.append({"file": name, "sha256": digest, "image": image, "page": page,
                      "host": urllib.parse.urlsplit(page or image).hostname or "",
                      "title": title})
        kept += 1

    with open(index_path, "w", encoding="utf-8") as f:
        json.dump(index, f, ensure_ascii=False, indent=2)
    print(f"{args.model}: {kept} new images ({duplicate} duplicates, {failed} not loaded), "
          f"{len(index)} in {index_path}")


if __name__ == "__main__":
    main()
