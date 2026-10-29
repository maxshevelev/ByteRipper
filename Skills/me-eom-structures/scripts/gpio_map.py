#!/usr/bin/env python3
"""Emit a generation's GPIO CSME pin map from a FIT build's own resources.

Flash Image Tool knows the pins the CSME firmware may drive: the usage a pin
serves (`INTEGRATED_TOUCH_1`, `SMT_SMLINK1_CLK`), the feature set it belongs to
(`GPIO_TOUCH_FEATURE_ID`), who owns it (`CSME_MODE`) and its pad mode
(`NATIVE_FUNCTION_1`), each a value class in the tool's layout documents:

    <Class name="GpioCsmeFunctionValues">
        <CfgOpt name="INTEGRATED_TOUCH_1" value="2" type="dword" />
        ...

The tool writes the configured pins to `/home/gpio/csme_pins` — the file the
`MeFeaturePins` class's `ProcessFeatureGpios` action names — and the reader
(`GPIOPinReader`) turns those records back into the names with this map. Only
the dictionaries are emitted: the record's shape is the file's, not the map's.

Run it and write the JSON (which the compiler reads, `Design/MAP_DATA.md`)
under `MapSources/gpio/`:

    python3 Skills/me-eom-structures/scripts/gpio_map.py <fit-11.exe> \
        --generation 11 --tool 11.0 --format json > \
        Packages/MEFirmware/MapSources/gpio/csme11.json

The JSON is compiled into `GPIOMaps.bin` by `map_bin.py`.

Stdlib only, read-only, no network, and the binary is never run.
"""

import hashlib
import json
import re
import sys
import zlib

# The zlib streams inside a FIT build do not all open with the same byte after
# the `0x78` — the usual `0x9C` misses more than half of them.
ZLIB = rb"\x78[\x01\x9c\xda]"

# The value classes this map is made of, and the Swift property each becomes.
# FIT 11 has no feature id: its pin records carry the usage alone, and the
# class is absent from that build.
CLASSES = [
    ("features", "GpioCsmeFeatureIdValues"),
    ("usages", "GpioCsmeFunctionValues"),
    ("ownerships", "GpioOwnershipValues"),
    ("padModes", "GpioPadModeValues"),
    ("groups", "GpioGroupValues"),
]


def documents(blob):
    """Every zlib stream in the executable that holds a document."""
    seen = set()
    for match in re.finditer(ZLIB, blob):
        try:
            out = zlib.decompressobj().decompress(
                blob[match.start():match.start() + 20_000_000])
        except Exception:
            continue
        if len(out) < 200:
            continue
        text = out.decode("utf-8", "replace")
        if not text.lstrip().startswith("<"):
            continue
        digest = hashlib.sha1(out).hexdigest()
        if digest in seen:
            continue
        seen.add(digest)
        yield text


def members(texts, name):
    """A value class's members over every document that defines it.

    Returns `number → label` and the numbers the documents disagree about. A
    number two documents give different names is not a name the map claims:
    it is dropped and reported, as the strap maps drop a disputed bit.
    """
    found, conflicts = {}, []
    for text in texts:
        match = re.search(r'<Class name="%s"[^>]*>(.*?)</Class\s*>' % re.escape(name),
                          text, re.S)
        if not match:
            continue
        definitions = len(re.findall(r'<Class name="%s"' % re.escape(name), text))
        if definitions > 1:
            print("! %s: %d definitions, the first is read"
                  % (name, definitions), file=sys.stderr)
        body = match.group(1)
        stated = len(re.findall(r'<CfgOpt\b', body))
        pairs = re.findall(r'<CfgOpt name="([^"]+)"\s+value="([^"]*)"', body)
        if stated != len(pairs):
            print("! %s: %d of %d <CfgOpt> entries did not parse"
                  % (name, stated - len(pairs), stated), file=sys.stderr)
        for label, value in pairs:
            try:
                number = int(value, 0)
            except ValueError:
                continue
            if number in found and found[number] != label:
                if number not in conflicts:
                    conflicts.append(number)
            found[number] = label
    for number in conflicts:
        del found[number]
    return found, conflicts


def swift_literal(text):
    return '"%s"' % text.replace("\\", "\\\\").replace('"', '\\"')


def dictionary(values):
    if not values:
        return "[:]"
    return "[%s]" % ", ".join("%d: %s" % (number, swift_literal(values[number]))
                              for number in sorted(values))


def option(args, name, default):
    """A `--name value` option, taken out of the argument list."""
    if name not in args:
        return args, default
    at = args.index(name)
    value = args[at + 1]
    return [a for i, a in enumerate(args) if i not in (at, at + 1)], value


def pretty_json(document):
    """JSON with one value per line: a diff reads a number at a time."""
    dictionaries = ("features", "usages", "ownerships", "padModes", "groups")
    lines = ["{"]
    for key in sorted(document):
        if key == "maps":
            continue
        lines.append(" %s: %s," % (
            json.dumps(key),
            json.dumps(document[key], ensure_ascii=False, sort_keys=True)))
    lines.append(' "maps": [')
    for map_index, mapping in enumerate(document["maps"]):
        scalars = ", ".join(
            "%s: %s" % (json.dumps(key),
                        json.dumps(mapping[key], ensure_ascii=False, sort_keys=True))
            for key in sorted(mapping) if key not in dictionaries)
        lines.append("  {%s," % scalars)
        present = [key for key in dictionaries if key in mapping]
        for key_index, key in enumerate(present):
            pairs = mapping[key]
            lines.append('   "%s": [' % key)
            for pair_index, pair in enumerate(pairs):
                lines.append("    %s%s" % (
                    json.dumps(pair, ensure_ascii=False,
                               separators=(", ", ": ")),
                    "," if pair_index + 1 < len(pairs) else ""))
            lines.append('   ]%s' % ("," if key_index + 1 < len(present) else ""))
        lines.append('  }%s' % ("," if map_index + 1 < len(document["maps"]) else ""))
    lines.append(" ]")
    lines.append("}")
    return "\n".join(lines)


def json_document(generation, tool, variable, values):
    mapping = {"id": variable,
               "name": "CSME %s (Flash Image Tool %s)" % (generation, tool)}
    for key, table in values.items():
        mapping[key] = [[number, table[number]] for number in sorted(table)]
    return pretty_json({
        "schema": "byteripper.map/1",
        "kind": "gpio",
        "tool": tool,
        "maps": [mapping],
    })


def main():
    args = sys.argv[1:]
    if not args:
        print(__doc__)
        return 2
    args, generation = option(args, "--generation", "15")
    args, tool = option(args, "--tool", "15.0")
    args, variable = option(args, "--variable", "csme%s" % generation)
    args, output_format = option(args, "--format", "swift")
    if output_format not in ("swift", "json"):
        print("--format is swift or json", file=sys.stderr)
        return 2
    blob = open(args[0], "rb").read()
    texts = list(documents(blob))

    values, missing = {}, []
    for key, class_name in CLASSES:
        found, conflicts = members(texts, class_name)
        if not found:
            missing.append(class_name)
            continue
        for number in conflicts:
            print("! %s: value %d is named differently in different documents — dropped"
                  % (class_name, number), file=sys.stderr)
        values[key] = found
    if "usages" not in values:
        raise SystemExit("no GpioCsmeFunctionValues class in this build")

    if output_format == "json":
        print(json_document(generation, tool, variable, values))
        if missing:
            print("classes absent from this build: %s" % ", ".join(missing),
                  file=sys.stderr)
        print("values: %s" % ", ".join("%s %d" % (key, len(values[key]))
                                       for key in values), file=sys.stderr)
        return 0

    print("// The GPIO feature pins of CSME %s, as Flash Image Tool %s names them —"
          % (generation, tool))
    print("// emitted by `Skills/me-eom-structures/scripts/gpio_map.py` from the")
    print("// tool's own value classes. The names are Intel's, copied; nothing here")
    print("// is read out of a dump.")
    print("//")
    print("// `/home/gpio/csme_pins` — the file the tool's `MeFeaturePins` class")
    print("// writes — carries the pins the image configures, and `GPIOPinReader`")
    print("// reads its records through this map. A number the tool has no name for")
    print("// is shown as the number.")
    print()
    print("import Foundation")
    print()
    print("extension GPIOPinMap {")
    print("    /// The values of CSME %s's `GpioCsme*` classes." % generation)
    print("    public static let %s = GPIOPinMap(" % variable)
    print('        name: "CSME %s (Flash Image Tool %s)",' % (generation, tool))
    for key, _ in CLASSES:
        if key in values:
            print("        %s: %s," % (key, dictionary(values[key])))
    print("    )")
    print("}")
    if missing:
        print("classes absent from this build: %s" % ", ".join(missing), file=sys.stderr)
    print("values: %s" % ", ".join("%s %d" % (key, len(values[key]))
                                   for key in values), file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
