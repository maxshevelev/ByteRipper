#!/usr/bin/env python3
"""Emit an old PCH's strap tables from flashrom's descriptor structures.

The generations before Sunrise Point have no FIT layout documents: Flash Image
Tool Classic keeps its strap map in code, and its executables carry no
`LayoutEntry` XML. What does state the map, bit by bit, is flashrom's
`include/ich_descriptors.h` — the `ibex` and `cougar` unions, written from
Intel's SPI Programming Guides (the 7 Series/C216 guide, document 475653,
Appendix A, carries the same fields and positions for Panther Point). The
structs are parsed here: each named bitfield becomes a `Field`, its bit range
computed from the widths in declaration order. The emitted Swift holds names,
positions and option words, not flashrom code.

**The tool's own template fills in what the guide leaves out.** Flash Image
Tool Classic reads a `newfiletmpl.xml` from its directory — the project every
new image starts from. It is not in the executable (only its Windows manifest
is), but the ME System Tools packages ship it beside `fitc.exe`: v8 r3 for
Cougar Point, v9.1 r7 and v9.5 r6 for Lynx Point, v10.0 r8 for Wildcat Point.
Per `PchStrapN` it states each field's **default value**, the words of every
option and the tool's own label — what the emitted tables otherwise lack for
these generations. `--template` reads one.

The template states no bit positions. Where the guide has a field, its bits are
the guide's and the template only adds the default, the label and the options.
The two words the guide does not lay out — 14 and 19, added by Lynx and
Wildcat Point — take their positions from the template's field order: fields
are packed from the high end of the section they fill, in the order the
template lists them, each as wide as its option list needs. That is not a
guess: on eight dumps the low 16 bits of word 14 read back as exactly the
SATA/PCIe lane modes `PchStrap14` names, and the two `PchStrap19` fields sit in
the low bits its two settings occupy. Words 18 and 20 are in no template and
stay raw.

    python3 Skills/me-eom-structures/scripts/intel_strap_map.py \
        --header <flashrom>/include/ich_descriptors.h --kind cougar \
        --template "<tools>/Flash Image Tool/v8.1.40.1456/newfiletmpl.xml" \
        --generation cougarPoint --words 18 --variable pch18 > \
        Packages/UEFIImage/Sources/UEFIImage/StrapMap+CPT.swift

`--kind` picks the union (`ibex` or `cougar`). For Lynx Point the 8-series
guide (Intel document 487990) is not public: `--kind cougar --carried-forward`
emits the Cougar Point field set for the first 18 of the generation's 21 words
and says so in the file's header. The fields it carries are the ones the
MacBook Air 13 dump corroborates (SMB_EN, SML1_EN, Deep_SX_EN and ICC_PRO_SEL
read at the 7-series bits); the template adds Lynx Point's own words 14 and 19,
and words 18 and 20 have no layout in either source and stay raw.

Stdlib only, read-only, no network.
"""

import math
import re
import sys
import xml.etree.ElementTree as ET

# The words of the unions as flashrom comments them: `struct { /* STRP0 */`.
WORD = re.compile(r'struct\s*\{\s*/\*\s*STRP(\d+)\s*\*/(.*?)\};', re.S)
FIELD = re.compile(r'(?:([A-Za-z_][A-Za-z0-9_]*)\s*)?:\s*(\d+)')

# The tool's own parameter names, from Intel's SPI Programming Guide Appendix A
# and flashrom's printer. Only labels the guide states are here.
LABELS = {
    "SMB_EN": "Intel ME SMBus Select",
    "SML0_EN": "SMLink0 Enable",
    "SML1_EN": "SMLink1 Enable",
    "SML1FRQ": "SMLink1 Frequency",
    "SMB0FRQ": "Intel ME SMBus Frequency",
    "SML0FRQ": "SMLink0 Frequency",
    "LANPHYPC_GP12_SEL": "LAN PHY Power Control GPIO12 Select",
    "LINKSEC_DIS": "MACsec Disable",
    "DMI_REQID_DIS": "DMI RequesterID Check Disable",
    "BBBS": "BIOS Boot-Block Size",
    "MESMASDEN": "Intel ME SMBus ASD Address Enable",
    "MESMASDA": "Intel ME SMBus ASD Address",
    "MESMMCTPAEN": "Intel ME SMBus MCTP Address Enable",
    "MESMMCTPA": "Intel ME SMBus MCTP Address",
    "MESMI2CEN": "Intel ME SMBus I2C Address Enable",
    "MESMI2CA": "Intel ME SMBus I2C Address",
    "PHYCON": "PHY Connectivity",
    "GBEMAC_SMBUS_ADDR_EN": "GbE MAC SMBus Address Enable",
    "GBEMAC_SMBUS_ADDR": "GbE MAC SMBus Address",
    "GBEPHY_SMBUS_ADDR": "GbE PHY SMBus Address",
    "MESMA2UDID_VENDOR": "Intel ME SMBus Subsystem Vendor ID",
    "MESMA2UDID_DEVICE": "Intel ME SMBus Subsystem Device ID",
    "PCIEPCS1": "PCI Express Port Configuration Strap 1",
    "PCIEPCS2": "PCI Express Port Configuration Strap 2",
    "PCIELR1": "PCIe Lane Reversal 1",
    "PCIELR2": "PCIe Lane Reversal 2",
    "DMILR": "DMI Lane Reversal",
    "PHY_PCIEPORTSEL": "Default PHY PCIe Port",
    "PHY_PCIE_EN": "Integrated MAC/PHY Communication over PCIe",
    "SUB_DECODE_EN": "PCIe Ports Subtractive Decode Agent",
    "PCHHOT_SML1ALERT_SEL": "GPIO74 PCHHOT# / SML1ALERT# Select",
    "ME_BOOT_FLASH": "ME Boot from Flash",
    "MDSMBE_EN": "ME Debug SMBus Emergency Mode Enable",
    "MDSMBE_ADD": "ME Debug SMBus Emergency Mode Address",
    "ICC_SEL": "Integrated Clocking Configuration",
    "MER_CL1": "ME Reset Capture on CL_RST1#",
    "ICC_PRO_SEL": "ICC Profile Selected by Soft Strap",
    "Deep_SX_EN": "Deep SX Support",
    "ME_DBG_LAN": "Intel ME Debug LAN Emergency Mode",
    "SML1GPAEN": "SMLink1 GP Address Enable",
    "SML1GPA": "SMLink1 General Purpose Target Address",
    "SML1I2CAEN": "SMLink1 I2C Target Address Enable",
    "SML1I2CA": "SMLink1 I2C Target Address",
    "IWL_EN": "Integrated Wired LAN Enabled",
    "SMLINK1_THERM_SEL": "SMLink1 Thermal Reporting Select",
    "SLP_LAN_GP29_SEL": "SLP_LAN# / GPP_G29 Select",
}

# The words a value may stand for, where the guide states them. A code the
# guide calls reserved is left out, and the panel shows the number.
OPTIONS = {
    "BBBS": {0: "64 KB", 1: "128 KB", 2: "256 KB"},
    "SML1FRQ": {1: "100 kHz"},
    "SMB0FRQ": {1: "100 kHz"},
    "SML0FRQ": {1: "100 kHz", 3: "Fast Mode"},
    "PHYCON": {0: "No PHY connected", 2: "PHY on SMLink0"},
    "PCIEPCS1": {0: "4 x1 ports", 1: "1 x2 and 2 x1 ports",
                 2: "2 x2 ports", 3: "1 x4 port"},
    "PCIEPCS2": {0: "4 x1 ports", 1: "1 x2 and 2 x1 ports",
                 2: "2 x2 ports", 3: "1 x4 port"},
    "LANPHYPC_GP12_SEL": {0: "General purpose output", 1: "LAN_PHY_PWR_CTRL"},
    "DMI_REQID_DIS": {0: "Checks enabled", 1: "Checks disabled"},
    "LINKSEC_DIS": {0: "Enabled", 1: "Disabled"},
    "SMB_EN": {0: "Disabled", 1: "Enabled"},
    "SML0_EN": {0: "Disabled", 1: "Enabled"},
    "SML1_EN": {0: "Disabled", 1: "Enabled"},
    "IWL_EN": {0: "Disabled", 1: "Enabled"},
    "PHY_PCIE_EN": {0: "Disabled", 1: "Enabled"},
    "SUB_DECODE_EN": {0: "Disabled", 1: "Enabled"},
    "PCHHOT_SML1ALERT_SEL": {0: "SML1ALERT#", 1: "PCHHOT#"},
    "ME_BOOT_FLASH": {0: "ROM, then flash", 1: "From flash"},
    "Deep_SX_EN": {0: "Not supported", 1: "Supported"},
    "ICC_PRO_SEL": {0: "BIOS (via MEI)", 1: "Soft strap"},
    "ME_DBG_LAN": {0: "Disabled", 1: "Enabled"},
    "MDSMBE_EN": {0: "Disabled", 1: "Enabled"},
}


# Which element of `newfiletmpl.xml` is which field of flashrom's union. The
# tool renamed a few between versions (v8 writes `LanPhyPcGp12Sel`, v9.5 and
# v10 `LanPhyPowerControl`), so each entry is the list it may appear under.
# Names not here have no field in the guide, and their bits come from the
# template's order — only the words in `TEMPLATE_ONLY_WORDS` have those.
TEMPLATE_TAGS = {
    "SMB_EN": ["SmBusEnable"],
    "SML0_EN": ["SmLink0Enable"],
    "SML1_EN": ["SmLink1Enable"],
    "SML1FRQ": ["SmLink1Freq"],
    "SMB0FRQ": ["SmBusFreq"],
    "SML0FRQ": ["SmLink0Freq"],
    "LANPHYPC_GP12_SEL": ["LanPhyPcGp12Sel", "LanPhyPowerControl"],
    "LINKSEC_DIS": ["MacSecDisable"],
    "DMI_REQID_DIS": ["DmiReqIdDisable"],
    "BBBS": ["BiosBootBlockSize"],
    "MESMASDEN": ["SmBusAsdAddrEn"],
    "MESMASDA": ["SmBusAsdAddr"],
    "MESMMCTPAEN": ["SmBusMctpAddrEn"],
    "MESMMCTPA": ["SmBusMctpAddr"],
    "MESMI2CEN": ["SmBusI2cAddrEn"],
    "MESMI2CA": ["SmBusI2cAddr"],
    "PHYCON": ["PhyConnectivity"],
    "GBEMAC_SMBUS_ADDR_EN": ["GbeSmBusAddrEn"],
    "GBEMAC_SMBUS_ADDR": ["GbeSmBusAddr"],
    "GBEPHY_SMBUS_ADDR": ["GbePhySmBusAddr"],
    "PCIEPCS1": ["PCIePortConf1"],
    "PCIEPCS2": ["PCIePortConf2"],
    "PCIELR1": ["PCIeLaneReversal1"],
    "PCIELR2": ["PCIeLaneReversal2"],
    "DMILR": ["DmiLaneReversal"],
    "PHY_PCIEPORTSEL": ["GbePciePortSelect"],
    "PHY_PCIE_EN": ["GbeOverPcieEn"],
    "SUB_DECODE_EN": ["SubtractDecodeAgentEn"],
    "PCHHOT_SML1ALERT_SEL": ["PchHotSml1AlertSel"],
    "ME_BOOT_FLASH": ["MeBootFromFlash"],
    "MDSMBE_EN": ["MeDbgSmbusEmergencyModeEn"],
    "MDSMBE_ADD": ["MeDbgSmbusEmergencyModeAddr"],
    "ICC_SEL": ["IccBootProfile"],
    "MER_CL1": ["MeResetCapture"],
    "ICC_PRO_SEL": ["IccProfileSelBy", "IccBootProfileSelectedBySoftStrap"],
    "Deep_SX_EN": ["DeepSx"],
    "ME_DBG_LAN": ["MeDbgLanEmergencyModeEn"],
    "SML1GPAEN": ["SmLink1GpAddrEn"],
    "SML1GPA": ["SmLink1GpAddr"],
    "SML1I2CAEN": ["SmLink1I2cAddrEn"],
    "SML1I2CA": ["SmLink1I2cAddr"],
    "IWL_EN": ["IntLanEn"],
    "SMLINK1_THERM_SEL": ["SmLink1ThermRepSel"],
    "SLP_LAN_GP29_SEL": ["SlpLanGpio29Sel"],
    "ICML": ["IcBtSoftStrp"],
}

# The words only the template lays out: 14 arrives with Lynx Point, 19 with
# Wildcat Point. Their positions are packed from the high end of the fields'
# own section downward, in the template's order — the order the dumps read
# back as the fields' values (`StrapMap+CPT.swift`'s header says how that was
# checked). Every other template-only field either overlaps a field the guide
# already places or has no width the template states, and is left out rather
# than guessed at.
TEMPLATE_ONLY_WORDS = {14, 19}

# Fields the tool calls reserved, and its raw word 16 (a 32-bit catch-all with
# no meaning of its own).
TEMPLATE_SKIP = re.compile(r"^(Reserved|SoftStrap)", re.I)


def template_words(path):
    """`newfiletmpl.xml` as `word → [field]`, in the template's order.

    A field is `{tag, name, value, value_list, help_text}` straight from the
    XML. The template states no bit position; `template_extras` gives the
    words where its order is the layout.
    """
    root = ET.parse(path).getroot()
    words = {}
    for element in root.iter():
        match = re.fullmatch(r"PchStrap(\d+)", element.tag)
        if not match:
            continue
        fields = []
        for child in element:
            if TEMPLATE_SKIP.match(child.tag):
                continue
            fields.append({
                "tag": child.tag,
                "name": child.get("name", ""),
                "value": child.get("value", ""),
                "value_list": child.get("value_list"),
                "help_text": child.get("help_text", ""),
            })
        words[int(match.group(1))] = fields
    return words


def option_number(item):
    """The number an option stands for, where the tool writes it.

    The template writes codes two ways: binary with a colon ("10: 2x2",
    "00: 4x1") and a bare digit before a bracket ("0 (General Purpose
    Output)"). Everything else — "Fast Mode", "64KB" — is its position in the
    list.
    """
    match = re.match(r"^\s*([01]+)\s*[:=]", item)
    if match:
        return int(match.group(1), 2)
    match = re.match(r"^\s*(\d+)\s*\(", item)
    if match:
        return int(match.group(1))
    return None


def option_label(item):
    """The words of an option, without the code the template puts before it."""
    match = re.match(r"^\s*(?:[01]+|\d+)\s*[:=]\s*(.*)$", item)
    return match.group(1).strip() if match else item.strip()


def template_options(field):
    """An option list as `value → words`, or nil where the template states none."""
    raw = field["value_list"]
    if not raw:
        return None
    options = {}
    for index, item in enumerate(raw.split(",,")):
        number = option_number(item)
        options[index if number is None else number] = option_label(item)
    return options or None


def template_default(field):
    """The field's default as the number the strap word holds, or nil."""
    value = field["value"].strip()
    raw = field["value_list"]
    if raw:
        items = raw.split(",,")
        if value in [item.strip() for item in items]:
            item = items[[item.strip() for item in items].index(value)]
            number = option_number(item)
            return number if number is not None else items.index(item)
        return None
    lowered = value.lower()
    if lowered == "true":
        return 1
    if lowered == "false":
        return 0
    if lowered.startswith("0x"):
        try:
            return int(value, 16)
        except ValueError:
            return None
    if value.isdigit():
        return int(value)
    return None


def template_width(field):
    """How many bits the field takes, where the template says it.

    An option list states it (the count's bit length); a boolean is one bit.
    A bare number or address does not, and is nil rather than guessed at.
    """
    raw = field["value_list"]
    if raw:
        count = len(raw.split(",,"))
        return max(1, math.ceil(math.log2(count))) if count > 1 else 1
    if field["value"].strip().lower() in ("true", "false"):
        return 1
    return None


def template_extras(word, fields):
    """The fields of a template-only word, packed from the high end down.

    The template lists them most significant first, so the last field takes bit
    0 and each earlier one the bits above it, as wide as its options need.
    Nil when a field's width is not stated, rather than a partial layout.
    """
    widths = [template_width(field) for field in fields]
    if not fields or any(width is None for width in widths):
        return None
    total = sum(widths)
    if total > 32:
        return None
    placed = []
    high = total - 1
    for field, width in zip(fields, widths):
        placed.append((field, high - width + 1, high))
        high -= width
    return placed


def strap_words(text, kind):
    """The union's words, as `word → [(name, low, high), …]`.

    Every word is 32 bits. flashrom's `cougar` union has one declaration whose
    trailing anonymous field is five bits too wide (`STRP1` adds up to 37), a
    typo in the reserved tail rather than a longer record: the union is an
    array of words, so the tail is trimmed to make the word whole.
    """
    start = text.index("/* %s" % kind)
    # The union member ends at its `} kind;`.
    end = text.index("} %s;" % kind, start)
    block = text[start:end]
    words = {}
    for match in WORD.finditer(block):
        number = int(match.group(1))
        declared = []
        for field in FIELD.finditer(match.group(2)):
            name, width = field.group(1), int(field.group(2))
            if name in ("uint32_t", "uint16_t", "uint8_t", "unsigned", "int"):
                name = None
            declared.append((name, width))
        total = sum(width for _, width in declared)
        if total != 32 and declared and declared[-1][0] is None:
            fixed = declared[-1][1] + (32 - total)
            if fixed >= 0:
                declared[-1] = (None, fixed)
                total = 32
        if total != 32:
            raise SystemExit("STRP%d in the %s union is %d bits, not 32"
                             % (number, kind, total))
        bit = 0
        fields = []
        for name, width in declared:
            if name:
                fields.append((name, bit, bit + width - 1))
            bit += width
        words[number] = fields
    return words


def swift_literal(text):
    return '"%s"' % text.replace("\\", "\\\\").replace('"', '\\"')


def field(name, low, high, word, label=None, options=None, default=None):
    parts = ["name: %s" % swift_literal("PCHSTRP%d_%s" % (word, name)),
             "word: %d" % word]
    if low == high:
        parts.append("bits: %d...%d" % (low, low))
    else:
        parts.append("bits: %d...%d" % (low, high))
    width = high - low + 1
    if default is not None and 0 <= default < (1 << width):
        parts.append("defaultValue: %d" % default)
    shown_label = label if label is not None else LABELS.get(name)
    if shown_label:
        parts.append("label: %s" % swift_literal(shown_label))
    shown_options = options if options is not None else OPTIONS.get(name)
    if shown_options:
        pairs = ", ".join("%d: %s" % (n, swift_literal(shown_options[n]))
                          for n in sorted(shown_options))
        parts.append("options: [%s]" % pairs)
    return "            Field(%s)," % ", ".join(parts)


def main():
    args = sys.argv[1:]
    if "--header" not in args:
        print(__doc__)
        return 2
    header = args[args.index("--header") + 1]
    kind = args[args.index("--kind") + 1] if "--kind" in args else "cougar"
    generation = (args[args.index("--generation") + 1]
                  if "--generation" in args else "cougarPoint")
    words = int(args[args.index("--words") + 1]) if "--words" in args else 18
    variable = (args[args.index("--variable") + 1]
                if "--variable" in args else "pch%d" % words)
    template = (args[args.index("--template") + 1]
                if "--template" in args else None)
    carried = "--carried-forward" in args

    text = open(header, encoding="utf-8").read()
    source = "flashrom's `include/ich_descriptors.h`"
    if carried:
        source = ("flashrom's `include/ich_descriptors.h`, whose `cougar` union "
                  "is the last published layout of this section")
    parsed = strap_words(text, kind)
    covered = sorted(parsed)
    if covered != list(range(max(covered) + 1)):
        raise SystemExit("the %s union's words are not contiguous: %s"
                         % (kind, covered))
    if words != len(covered):
        if not carried or words < len(covered):
            raise SystemExit("asked for %d words, the %s union states %d"
                             % (words, kind, len(covered)))

    template_by_word = template_words(template) if template else {}
    template_by_tag = {
        word: {field["tag"]: field for field in fields}
        for word, fields in template_by_word.items()
    }

    # Each word's fields, in the order they are emitted: the guide's bits first,
    # with the template's default, label and options where it has the field,
    # then — for the words only the template lays out — its own packed fields.
    rows = {}
    for word in covered:
        rows[word] = []
        for name, low, high in parsed[word]:
            match = None
            for tag in TEMPLATE_TAGS.get(name, []):
                match = template_by_tag.get(word, {}).get(tag)
                if match:
                    break
            rows[word].append((
                name, low, high,
                (match["name"] or None) if match and name not in LABELS else None,
                (template_options(match)
                 if match and name not in OPTIONS else None),
                template_default(match) if match else None,
            ))
    for word in sorted(TEMPLATE_ONLY_WORDS):
        if word >= words or parsed.get(word):
            continue
        placed = template_extras(word, template_by_word.get(word, []))
        if not placed:
            continue
        rows[word] = [
            (field["tag"], low, high, field["name"] or None,
             template_options(field), template_default(field))
            for field, low, high in placed
        ]
    covered = sorted(rows)
    missing = [word for word in range(words) if word not in rows]

    emit = []
    emit.append("// The PCH soft straps of %s, as Intel's SPI Programming Guide" % generation)
    emit.append("// lays them out — emitted by")
    emit.append("// `Skills/me-eom-structures/scripts/intel_strap_map.py` from %s." % source)
    if template:
        emit.append("// Names, bits, labels and option words are the guide's; the defaults,")
        emit.append("// and the label and options of a few fields, are Flash Image Tool's own")
        emit.append("// from the `newfiletmpl.xml` of its package.")
    else:
        emit.append("// Names, bits, labels and option words are the guide's; nothing here is")
        emit.append("// read out of a dump.")
    emit.append("//")
    if carried:
        emit.append("// The 8-series guide (Intel document 487990) is not public: the first")
        emit.append("// %d of the %d words are the Cougar Point fields carried forward, and"
                    % (len(parsed), words))
        emit.append("// the dumps at hand corroborate them (SMB_EN, SML1_EN, Deep_SX_EN and")
        emit.append("// ICC_PRO_SEL read at these bits on the MacBook Air 13 dump).")
        if template and any(word in rows for word in TEMPLATE_ONLY_WORDS):
            emit.append("// The template adds the words this generation introduced. Its fields")
            emit.append("// are packed most significant first from the high end of the section")
            emit.append("// they fill; the dumps at hand read word 14 back as exactly its")
            emit.append("// SATA/PCIe lane modes, and word 19 as the two power controls (both")
            emit.append("// clear on every dump). A word neither source lays out is raw.")
        else:
            emit.append("// Words %s have no public layout and are shown as raw words."
                        % ", ".join(str(word) for word in missing))
        emit.append("//")
    emit.append("// A field the guide calls reserved is not here: it has no name, and the")
    emit.append("// panel shows the word's raw value where a word names no field.")
    emit.append("")
    emit.append("import Foundation")
    emit.append("")
    emit.append("extension DescriptorStrapMap {")
    emit.append("    /// The %d-word PCH strap section." % words)
    emit.append("    public static let %s = DescriptorStrapMap(" % variable)
    emit.append("        name: %s,%s" % (swift_literal(source), ""))
    emit.append("        words: %d," % words)
    emit.append("        fields: [")
    for word in covered:
        for name, low, high, label, options, default in rows[word]:
            emit.append(field(name, low, high, word, label=label,
                              options=options, default=default))
    emit.append("        ])")
    emit.append("}")
    print("\n".join(emit))
    print("%s: %d words, %d fields" %
          (variable, words, sum(len(fields) for fields in rows.values())),
          file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
