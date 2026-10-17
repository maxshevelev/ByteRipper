// The CPU strap message's layout of CSME 18, as Flash Image Tool 18.1 lays it out
// — emitted by `Skills/me-eom-structures/scripts/strap18_map.py` from the
// tool's own `CPU_smip` documents. Names, offsets, bits, labels, sections,
// help and option words are the tool's; nothing here is read out of a dump,
// and no default is stated: the values are per reference platform.
//
// CSME 18 keeps this message in the FITC partition's MIP table, not in the
// descriptor's MIP area (`CPUStrapMap`).

import Foundation

extension CPUStrapMap {
    /// The CPU straps, as the tool lays them out.
    public static let csme18 = CPUStrapMap(
        name: "CSME 18 (Flash Image Tool 18.1)",
        fields: [
            Field(name: "CPU_smip_Strap_CPU_SMT_Disable", offset: 0x0, bit: 0, count: 1, label: "Disable Hyperthreading", section: "CpuStraps", help: "This setting control enabling / disabling of Hyper threading.\nNote: Hyper threading is not supported on Arrow Lake-H processors.\nNote: This strap is intended for debugging purposed only. See BIOS Spec for more details on enabling / disabling Hyper threading", options: [0: "No", 1: "Yes"]),
            Field(name: "CPU_smip_Strap_CPU_Num_Of_Big_Cores", offset: 0x0, bit: 1, count: 4, label: "Number of Active Big Cores", section: "CpuStraps", help: "This setting controls the number of active Big Core processors.\nNote: This strap is intended for debugging purposed only. See BIOS Spec for more details on enabling / disabling processor cores.", options: [0: "All Cores Active", 1: "1 Core Active", 2: "2 Cores Active", 3: "3 Cores Active", 4: "4 Cores Active", 5: "5 Cores Active"]),
            Field(name: "CPU_smip_Strap_CPU_BIST", offset: 0x0, bit: 5, count: 1, label: "BIST Initialization", section: "CpuStraps", help: "This setting determines if BIST will be run at platform reset after BIOS requested actions.\nNote: This strap is intended for debugging purposed only.", options: [0: "No", 1: "Yes"]),
            Field(name: "CPU_smip_Strap_CPU_FlexRatio", offset: 0x0, bit: 6, count: 6, label: "Flex Ratio", section: "CpuStraps", help: "This setting controls the maximum processor non-turbo ratio.\nNote: This strap is intended for debugging purposed only. See BIOS Spec for more details on maximum processor non-turbo ratio configuration."),
            Field(name: "CPU_smip_Strap_CPU_Fast_wakeup", offset: 0x0, bit: 12, count: 1, label: "Processor Boot at P1 Frequency", section: "CpuStraps", help: "This setting determines if the processor will boot at P1 frequency.\nNote: This strap is intended for debugging purposed only.", options: [0: "No", 1: "Yes"]),
            Field(name: "CPU_smip_Strap_CPU_JTAG_PowerGate_DISABLE", offset: 0x0, bit: 13, count: 1, label: "JTAG Power Disable", section: "CpuStraps", help: "This setting determines if JTAG power will be maintained on C10 or lower power states.\nNote: This strap is intended for debugging purposed only.", options: [0: "No JTAG Power on C10 and Lower", 1: "JTAG Power on C10 and Lower"]),
            Field(name: "CPU_smip_Strap_CPU_CORE_HIGH_VOLTAGE_MODE", offset: 0x0, bit: 14, count: 1),
            Field(name: "CPU_smip_Strap_CPU_NON_CORE_HIGH_VOLTAGE_MODE", offset: 0x0, bit: 15, count: 1),
            Field(name: "CPU_smip_Strap_CPU_enDebug_DISABLED", offset: 0x0, bit: 16, count: 1),
            Field(name: "CPU_smip_Strap_CPU_NUM_OF_COMPUTE_ATOM_CORES", offset: 0x0, bit: 17, count: 5, label: "Active Compute Small Cores", section: "CpuStraps", help: "This setting controls the number of active small core processors.\nNote: If the Number of Active Big Cores setting is configured to a specific number of individual cores active and the Number of Active Compute Small Cores is configured to All Cores Active the Compute Small core processors will be disabled.\nNote: This strap is intended for debugging purposed only. See BIOS Spec for more details on enabling / disabling processor cores.", options: [0: "All Cores Active", 1: "1 Core Active", 2: "2 Cores Active", 3: "3 Cores Active", 4: "4 Cores Active", 5: "5 Cores Active", 6: "6 Cores Active", 7: "7 Cores Active"]),
            Field(name: "CPU_smip_Strap_CPU_NUM_OF_SOC_ATOM_CORES", offset: 0x0, bit: 22, count: 3, label: "Number of Active Small Cores", section: "CpuStraps", help: "This setting controls the number of active small core processors.\nNote: If the Number of Active Big Cores setting is configured to a specific number of individual cores active and the Number of Active Small Cores is configured to All Cores Active the Small core processors will be disabled.\nNote: This strap is intended for debugging purposed only. See BIOS Spec for more details on enabling / disabling processor cores.", options: [0: "Disable All Cores", 1: "1 Core Active", 2: "2 Cores Active"]),
            Field(name: "CPU_smip_Strap_CPU_BOOT_IA_AT_CTDP1", offset: 0x0, bit: 25, count: 1, label: "Processor P1 Boot Ratio", section: "CpuStraps", help: "This setting determines the processor P1 boot ratio.", options: [0: "Nominal P1 Ratio", 1: "TDP1 P1 Ratio"]),
            Field(name: "CPU_smip_Strap_CPU_CPU_DLVR_PG_MODE", offset: 0x0, bit: 26, count: 1),
            Field(name: "CPU_smip_Strap_CPU_RSVD_DW2_28_27", offset: 0x0, bit: 27, count: 2),
            Field(name: "CPU_smip_Strap_CPU_SMT4_DISABLED", offset: 0x0, bit: 29, count: 1),
            Field(name: "CPU_smip_Strap_CPU_KVMR_CAPTURE_DISABLE", offset: 0x0, bit: 30, count: 1),
            Field(name: "CPU_smip_Strap_CPU_KVMR_SPRITE_DISABLE", offset: 0x0, bit: 31, count: 1),
            Field(name: "CPU_smip_Strap_CPU_RSVD_DW3_7_0", offset: 0x4, bit: 0, count: 8),
            Field(name: "CPU_smip_Strap_CPU_IA_VR_ADDR", offset: 0x4, bit: 8, count: 4, label: "IA VR Address", section: "CpuStraps", help: "This setting determines the IA VR address. See Processor EDS for details.\nNote: This strap should be left at the recommended default setting."),
            Field(name: "CPU_smip_Strap_CPU_IA_VR_TYPE", offset: 0x4, bit: 12, count: 1, label: "IA VR Type", section: "CpuStraps", help: "This setting determines the IA core VR type. See Processor EDS for details.", options: [0: "SVID", 1: "Fixed VR"]),
            Field(name: "CPU_smip_Strap_CPU_GT_VR_ADDR", offset: 0x4, bit: 13, count: 4, label: "GT VR Address", section: "CpuStraps", help: "This setting determines the GT VR address. See Processor EDS for details.\nNote: This strap should be left at the recommended default setting."),
            Field(name: "CPU_smip_Strap_CPU_GT_VR_TYPE", offset: 0x4, bit: 17, count: 1, label: "GT VR Type", section: "CpuStraps", help: "This setting determines the GT core VR type. See Processor EDS for details.", options: [0: "SVID", 1: "Fixed VR"]),
            Field(name: "CPU_smip_Strap_CPU_CPU_RSVD_DW3_21_18", offset: 0x4, bit: 18, count: 4),
            Field(name: "CPU_smip_Strap_CPU_PEG62_disable", offset: 0x4, bit: 22, count: 1),
            Field(name: "CPU_smip_Strap_CPU_PEGx10_disable", offset: 0x4, bit: 23, count: 1),
            Field(name: "CPU_smip_Strap_CPU_PEG60_disable", offset: 0x4, bit: 24, count: 1),
            Field(name: "CPU_smip_Strap_CPU_SA_VR_ADDR", offset: 0x4, bit: 25, count: 4, label: "SA VR Address", section: "CpuStraps", help: "This setting determines the SA VR address. See Processor EDS for details.\nNote: This strap should be left at the recommended default setting."),
            Field(name: "CPU_smip_Strap_CPU_SA_VR_TYPE", offset: 0x4, bit: 29, count: 1, label: "SA VR Type", section: "CpuStraps", help: "This setting determines the SA VR type. See Processor EDS for details.", options: [0: "SVID", 1: "Fixed VR"]),
            Field(name: "CPU_smip_Strap_CPU_RSVD_DW3_30", offset: 0x4, bit: 30, count: 1),
            Field(name: "CPU_smip_Strap_CPU_Psys_Disable", offset: 0x4, bit: 31, count: 1, label: "Platform IMON", section: "CpuStraps", help: "This strap should be left at the recommended default setting.", options: [0: "Enabled", 1: "Disabled"]),
            Field(name: "CPU_smip_Strap_CPU_TCSS_PORT_EN_MASK_STRAP", offset: 0x8, bit: 0, count: 6),
            Field(name: "CPU_smip_Strap_CPU_TCSS_TBT_EN_STRAP", offset: 0x8, bit: 6, count: 1),
            Field(name: "CPU_smip_Strap_CPU_RSVD_DW4_7", offset: 0x8, bit: 7, count: 1),
            Field(name: "CPU_smip_Strap_CPU_DTI", offset: 0x8, bit: 8, count: 8),
            Field(name: "CPU_smip_Strap_CPU_CRC", offset: 0x8, bit: 16, count: 16),
        ])
}

