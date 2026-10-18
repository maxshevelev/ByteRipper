// The processor strap section, field by field, as Intel's Flash Image Tool
// lays it out — emitted by `Skills/me-eom-structures/scripts/strap_map.py`
// from the tool's own resources. Names, offsets, bits and defaults are the
// tool's, copied; nothing here is read out of a dump.
//
// A table is picked by the length of the section it describes — the words the
// descriptor's own FLMAP2 states — because that is what an image states about
// itself. `StrapMap.swift` says what a table is and what the lookup does;
// another length is added by running the script with it.
//
// A processor table keeps only the fields **every** document of that
// length states alike — the same name at the same offset and bits. Two
// documents of one length can differ (a field's width, which bits are
// reserved), and a field they disagree about is left out rather than
// taken from one of them.

import Foundation

extension DescriptorStrapMap {
    /// The 3-word section, as Flash Image Tool 11 (spt_fit_layout.xml) lays it out.
    public static let sptCpu3 = DescriptorStrapMap(
        name: "spt_fit_layout.xml",
        words: 3,
        fields: [
            Field(name: "CpuStrapHtDisable", word: 0, bits: 0...0, defaultValue: 0x0),
            Field(name: "CpuStrapNumActiveCores", word: 0, bits: 1...3, defaultValue: 0x0),
            Field(name: "reserved_0x0_4", word: 0, bits: 4...4, defaultValue: 0x0),
            Field(name: "CpuStrapBistInit", word: 0, bits: 5...5, defaultValue: 0x0),
            Field(name: "CpuStrapFlexRatio", word: 0, bits: 6...11, defaultValue: 0x0),
            Field(name: "CpuStrapCpuMaxFreqBoot", word: 0, bits: 12...12, defaultValue: 0x1),
            Field(name: "CpuStrapJtagPwrDis", word: 0, bits: 13...13, defaultValue: 0x0),
            Field(name: "reserved_0x0_31_14", word: 0, bits: 14...31, defaultValue: 0x0),
            Field(name: "CpuStrapSaPowerPlaneTopology", word: 1, bits: 0...3, defaultValue: 0x2),
            Field(name: "CpuStrapSaVrType", word: 1, bits: 4...4, defaultValue: 0x1),
            Field(name: "CpuStrapIaPowerPlaneTopology", word: 1, bits: 5...8, defaultValue: 0x0),
            Field(name: "CpuStrapIaVrType", word: 1, bits: 9...9, defaultValue: 0x0),
            Field(name: "CpuStrapRingPowerPlaneTopology", word: 1, bits: 10...13, defaultValue: 0x0),
            Field(name: "CpuStrapRingVrType", word: 1, bits: 14...14, defaultValue: 0x0),
            Field(name: "CpuStrapGtUsPowerPlaneTopology", word: 1, bits: 15...18, defaultValue: 0x3),
            Field(name: "CpuStrapGtUsVrType", word: 1, bits: 19...19, defaultValue: 0x0),
            Field(name: "CpuStrapGtSPowerPlaneTopology", word: 1, bits: 20...23, defaultValue: 0x1),
            Field(name: "CpuStrapGtSVrType", word: 1, bits: 24...24, defaultValue: 0x0),
            Field(name: "CpuStrapRsvd", word: 1, bits: 25...29, defaultValue: 0x0),
            Field(name: "CpuStrapSvidNotPresent", word: 1, bits: 30...30, defaultValue: 0x0),
            Field(name: "CpuStrapPlatformImonDisable", word: 1, bits: 31...31, defaultValue: 0x1),
            Field(name: "CpuStrapEopioPowerPlaneTopology", word: 2, bits: 0...3, defaultValue: 0x5),
            Field(name: "CpuStrapEopioVrType", word: 2, bits: 4...4, defaultValue: 0x1),
            Field(name: "CpuStrapEdramPowerPlaneTopology", word: 2, bits: 5...8, defaultValue: 0x4),
            Field(name: "CpuStrapEdramVrType", word: 2, bits: 9...9, defaultValue: 0x1),
            Field(name: "reserved_0x4_0", word: 2, bits: 10...27, defaultValue: 0x0),
            Field(name: "CpuStrapSeKeyMode", word: 2, bits: 28...31, defaultValue: 0x0),
        ])
}
