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

    python3 Skills/me-eom-structures/scripts/intel_strap_map.py \
        --header <flashrom>/include/ich_descriptors.h --kind cougar \
        --generation cougarPoint --words 18 --variable pch18 > \
        Packages/UEFIImage/Sources/UEFIImage/StrapMap+CPT.swift

`--kind` picks the union (`ibex` or `cougar`). For Lynx Point the 8-series
guide (Intel document 487990) is not public: `--kind cougar --carried-forward`
emits the Cougar Point field set for the first 18 of the generation's 21 words
and says so in the file's header. The fields it carries are the ones the
MacBook Air 13 dump corroborates (SMB_EN, SML1_EN, Deep_SX_EN and ICC_PRO_SEL
read at the 7-series bits); words 18-20 have no public layout and stay raw.

Stdlib only, read-only, no network.
"""

import re
import sys

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


def field(name, low, high, word):
    parts = ["name: %s" % swift_literal("PCHSTRP%d_%s" % (word, name)),
             "word: %d" % word]
    if low == high:
        parts.append("bits: %d...%d" % (low, low))
    else:
        parts.append("bits: %d...%d" % (low, high))
    label = LABELS.get(name)
    if label:
        parts.append("label: %s" % swift_literal(label))
    options = OPTIONS.get(name)
    if options:
        pairs = ", ".join("%d: %s" % (n, swift_literal(options[n]))
                          for n in sorted(options))
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

    emit = []
    emit.append("// The PCH soft straps of %s, as Intel's SPI Programming Guide" % generation)
    emit.append("// lays them out — emitted by")
    emit.append("// `Skills/me-eom-structures/scripts/intel_strap_map.py` from %s." % source)
    emit.append("// Names, bits, labels and option words are the guide's; nothing here is")
    emit.append("// read out of a dump.")
    emit.append("//")
    if carried:
        emit.append("// The 8-series guide (Intel document 487990) is not public: the first")
        emit.append("// %d of the %d words are the Cougar Point fields carried forward, and"
                    % (len(covered), words))
        emit.append("// the dumps at hand corroborate them (SMB_EN, SML1_EN, Deep_SX_EN and")
        emit.append("// ICC_PRO_SEL read at these bits on the MacBook Air 13 dump). Words")
        emit.append("// %d-%d have no public layout and are shown as raw words."
                    % (len(covered), words - 1))
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
        for name, low, high in parsed[word]:
            emit.append(field(name, low, high, word))
    emit.append("        ])")
    emit.append("}")
    print("\n".join(emit))
    print("%s: %d words, %d fields" %
          (variable, len(covered), sum(len(v) for v in parsed.values())),
          file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
