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
    /// The 11-word section, as Flash Image Tool 15.0 (cnp_lp_rvp.xml) lays it out.
    public static let cpu11 = DescriptorStrapMap(
        name: "cnp_lp_rvp.xml",
        words: 11,
        fields: [
            Field(name: "CPU_Strap_SMT_Dis_HyperThreadingDisable", word: 0, bits: 0...0, defaultValue: 0x0),
            Field(name: "CPU_Strap_Num_Active_Cores", word: 0, bits: 1...4, defaultValue: 0x0),
            Field(name: "CPU_Strap_BIST_BistInit", word: 0, bits: 5...5, defaultValue: 0x0),
            Field(name: "CPU_Strap_FlexRatio", word: 0, bits: 6...11, defaultValue: 0x0),
            Field(name: "CPU_Strap_Fast_wakeup", word: 0, bits: 12...12, defaultValue: 0x1),
            Field(name: "CPU_Strap_JTAG_PG_DIS_JtagPwrDisable", word: 0, bits: 13...13, defaultValue: 0x0),
            Field(name: "CPU_Strap_CORE_HIGH_VOLTAGE_MODE", word: 0, bits: 14...14, defaultValue: 0x0),
            Field(name: "CPU_Strap_NON_CORE_HIGH_VOLTAGE_MODE", word: 0, bits: 15...15, defaultValue: 0x0),
            Field(name: "CPU_Strap_enDebug_Disable", word: 0, bits: 16...16, defaultValue: 0x0),
            Field(name: "CPU_Strap_DW2_Reserved_30_17", word: 0, bits: 17...30, defaultValue: 0x0),
            Field(name: "CPU_Strap_PEG_DEF", word: 0, bits: 31...31, defaultValue: 0x1),
            Field(name: "CPU_Strap_VCCIN_AUX_EXIST", word: 1, bits: 0...0, defaultValue: 0x0),
            Field(name: "CPU_Strap_DW3_Reserved_1", word: 1, bits: 1...1, defaultValue: 0x0),
            Field(name: "CPU_Strap_VccSTG_PG_Exist", word: 1, bits: 2...2, defaultValue: 0x1),
            Field(name: "CPU_Strap_VccST_PG_Exist", word: 1, bits: 3...3, defaultValue: 0x1),
            Field(name: "CPU_Strap_VccSFR_OC_PG_Exist", word: 1, bits: 4...4, defaultValue: 0x1),
            Field(name: "CPU_Strap_VCCIN_AUX_LP_LEVEL", word: 1, bits: 5...5, defaultValue: 0x0),
            Field(name: "CPU_Strap_DW3_Reserved_24_6", word: 1, bits: 6...24, defaultValue: 0x0),
            Field(name: "CPU_Strap_VCCIN_SVID_Address", word: 1, bits: 25...28, defaultValue: 0x0),
            Field(name: "CPU_Strap_VCCIN_VR_TYPE", word: 1, bits: 29...29, defaultValue: 0x0),
            Field(name: "CPU_Strap_SVID_not_present", word: 1, bits: 30...30, defaultValue: 0x0),
            Field(name: "CPU_Strap_Psys_Disable", word: 1, bits: 31...31, defaultValue: 0x0),
            Field(name: "CPU_Strap_TCSS_PORT_EN_MASK_STRAP", word: 2, bits: 0...5, defaultValue: 0xF),
            Field(name: "CPU_Strap_TCSS_TBT_EN_STRAP", word: 2, bits: 6...6, defaultValue: 0x1),
            Field(name: "CPU_Strap_DTI", word: 2, bits: 8...15, defaultValue: 0x0),
            Field(name: "CPU_Strap_CRC", word: 2, bits: 16...31, defaultValue: 0x0),
            Field(name: "CPU_Strap_IOM_TC_CONFIG0", word: 3, bits: 0...31, defaultValue: 0x0),
            Field(name: "CPU_Strap_PFIX1", word: 4, bits: 0...3, defaultValue: 0x0),
            Field(name: "CPU_Strap_PFIX2", word: 4, bits: 4...7, defaultValue: 0x0),
            Field(name: "CPU_Strap_PFIX3", word: 4, bits: 8...11, defaultValue: 0x0),
            Field(name: "CPU_Strap_PFIX4", word: 4, bits: 12...15, defaultValue: 0x0),
            Field(name: "CPU_Strap_PFIX5", word: 4, bits: 16...19, defaultValue: 0x0),
            Field(name: "CPU_Strap_PFIX6", word: 4, bits: 20...23, defaultValue: 0x0),
            Field(name: "CPU_Strap_DW6_Reserved_31_24", word: 4, bits: 24...31, defaultValue: 0x0),
            Field(name: "CPU_Strap_DW7_ior_strp_secur_en", word: 5, bits: 0...0, defaultValue: 0x0),
            Field(name: "CPU_Strap_DW7_ee_arc_enable_override", word: 5, bits: 1...1, defaultValue: 0x0),
            Field(name: "CPU_Strap_XHC_PORT1_OWNERSHIP_STRAP", word: 6, bits: 0...0, defaultValue: 0x0),
            Field(name: "CPU_Strap_XHC_PORT2_OWNERSHIP_STRAP", word: 6, bits: 1...1, defaultValue: 0x0),
            Field(name: "CPU_Strap_XHC_PORT3_OWNERSHIP_STRAP", word: 6, bits: 2...2, defaultValue: 0x0),
            Field(name: "CPU_Strap_XHC_PORT4_OWNERSHIP_STRAP", word: 6, bits: 3...3, defaultValue: 0x0),
            Field(name: "CPU_Strap_XHC_PORT5_OWNERSHIP_STRAP", word: 6, bits: 4...4, defaultValue: 0x0),
            Field(name: "CPU_Strap_XHC_PORT6_OWNERSHIP_STRAP", word: 6, bits: 5...5, defaultValue: 0x0),
            Field(name: "CPU_Strap_DW8_Reserved_7_6", word: 6, bits: 6...7, defaultValue: 0x0),
            Field(name: "CPU_Strap_USB3_SSIC_PORT1_STRAP", word: 6, bits: 8...8, defaultValue: 0x0),
            Field(name: "CPU_Strap_USB3_SSIC_PORT2_STRAP", word: 6, bits: 9...9, defaultValue: 0x0),
            Field(name: "CPU_Strap_USB3_SSIC_PORT3_STRAP", word: 6, bits: 10...10, defaultValue: 0x0),
            Field(name: "CPU_Strap_USB3_SSIC_PORT4_STRAP", word: 6, bits: 11...11, defaultValue: 0x0),
            Field(name: "CPU_Strap_USB3_SSIC_PORT5_STRAP", word: 6, bits: 12...12, defaultValue: 0x0),
            Field(name: "CPU_Strap_USB3_SSIC_PORT6_STRAP", word: 6, bits: 13...13, defaultValue: 0x0),
            Field(name: "CPU_Strap_DW8_Reserved_15_14", word: 6, bits: 14...15, defaultValue: 0x0),
            Field(name: "CPU_Strap_PORT_SPEED_CAP_STRAP_PORT1", word: 6, bits: 16...16, defaultValue: 0x0),
            Field(name: "CPU_Strap_PORT_SPEED_CAP_STRAP_PORT2", word: 6, bits: 17...17, defaultValue: 0x0),
            Field(name: "CPU_Strap_PORT_SPEED_CAP_STRAP_PORT3", word: 6, bits: 18...18, defaultValue: 0x0),
            Field(name: "CPU_Strap_PORT_SPEED_CAP_STRAP_PORT4", word: 6, bits: 19...19, defaultValue: 0x0),
            Field(name: "CPU_Strap_PORT_SPEED_CAP_STRAP_PORT5", word: 6, bits: 20...20, defaultValue: 0x0),
            Field(name: "CPU_Strap_PORT_SPEED_CAP_STRAP_PORT6", word: 6, bits: 21...21, defaultValue: 0x0),
            Field(name: "CPU_Strap_DW8_Reserved_23_22", word: 6, bits: 22...23, defaultValue: 0x0),
            Field(name: "CPU_Strap_INIT_PORT_SPEED_SELECT_STRAP_PORT1", word: 6, bits: 24...24, defaultValue: 0x0),
            Field(name: "CPU_Strap_INIT_PORT_SPEED_SELECT_STRAP_PORT2", word: 6, bits: 25...25, defaultValue: 0x0),
            Field(name: "CPU_Strap_INIT_PORT_SPEED_SELECT_STRAP_PORT3", word: 6, bits: 26...26, defaultValue: 0x0),
            Field(name: "CPU_Strap_INIT_PORT_SPEED_SELECT_STRAP_PORT4", word: 6, bits: 27...27, defaultValue: 0x0),
            Field(name: "CPU_Strap_INIT_PORT_SPEED_SELECT_STRAP_PORT5", word: 6, bits: 28...28, defaultValue: 0x0),
            Field(name: "CPU_Strap_INIT_PORT_SPEED_SELECT_STRAP_PORT6", word: 6, bits: 29...29, defaultValue: 0x0),
            Field(name: "CPU_Strap_DW8_Reserved_31_30", word: 6, bits: 30...31, defaultValue: 0x0),
            Field(name: "CPU_Strap_ESS_CONNECTOR_TYPE_STRAP_PORT1", word: 7, bits: 0...3, defaultValue: 0x0),
            Field(name: "CPU_Strap_ESS_CONNECTOR_TYPE_STRAP_PORT2", word: 7, bits: 4...7, defaultValue: 0x0),
            Field(name: "CPU_Strap_ESS_CONNECTOR_TYPE_STRAP_PORT3", word: 7, bits: 8...11, defaultValue: 0x0),
            Field(name: "CPU_Strap_ESS_CONNECTOR_TYPE_STRAP_PORT4", word: 7, bits: 12...15, defaultValue: 0x0),
            Field(name: "CPU_Strap_ABMODE4_ESS_CONNECTOR_TYPE_STRAP_PORT5", word: 7, bits: 16...19, defaultValue: 0x0),
            Field(name: "CPU_Strap_ESS_CONNECTOR_TYPE_STRAP_PORT6", word: 7, bits: 20...23, defaultValue: 0x0),
            Field(name: "CPU_Strap_TYPE_AB_MODE_STRAP", word: 7, bits: 24...24, defaultValue: 0x0),
            Field(name: "CPU_Strap_DW9_Reserved_31_25", word: 7, bits: 25...31, defaultValue: 0x0),
            Field(name: "CPU_Strap_SPLIT_DIE_XDCI_UFP_SM_PRESENT", word: 8, bits: 0...0, defaultValue: 0x1),
            Field(name: "CPU_Strap_FORCE_XDCI_USB2_ONLY_MODE", word: 8, bits: 1...1, defaultValue: 0x0),
            Field(name: "CPU_Strap_xdci_reserved", word: 8, bits: 2...31, defaultValue: 0x0),
            Field(name: "CPU_Strap_DW11_ior_strp_secur_en", word: 9, bits: 0...0, defaultValue: 0x0),
            Field(name: "CPU_Strap_DW11_ee_arc_enable_override", word: 9, bits: 1...1, defaultValue: 0x0),
            Field(name: "CPU_Strap_DW12_Tbt3_reserved", word: 10, bits: 0...31, defaultValue: 0x0),
        ])
}
