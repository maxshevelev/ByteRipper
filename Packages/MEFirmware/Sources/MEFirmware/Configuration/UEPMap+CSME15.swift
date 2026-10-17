// The FPF/UEP settings of CSME 15, as Flash Image Tool 15.0 names them — emitted by
// `Skills/me-eom-structures/scripts/uep_map.py` from the tool's own
// documents. Names, labels, sections and places are the tool's; nothing
// here is read out of a dump.
//
// A setting's place is in the **first** bit array of the `$UEP` container
// — the array an image's reading takes (the Boot Guard word's, see
// `BootGuardReader`). The tool also places many settings in the container's
// other arrays; those copies are not read, and such a setting is not here.
//
// What the arrays hold on a vendor dump is the state the build wrote, not
// the fuses the platform will burn: see `Design/ME_STRUCTURES.md`.

import Foundation

extension UEPMap {
    /// The FPF settings, as the tool lays them out.
    public static let csme15 = UEPMap(
        name: "CSME 15 (Flash Image Tool 15.0)",
        settings: [
            Setting(name: "soc_cl", placement: Placement(array: 0, offset: 0x10, bit: 0, count: 4)),
            Setting(name: "sb", placement: Placement(array: 0, offset: 0x10, bit: 4, count: 4)),
            Setting(name: "vln_en", placement: Placement(array: 0, offset: 0x10, bit: 24, count: 4)),
            Setting(name: "rbe_svn_en", placement: Placement(array: 0, offset: 0x14, bit: 0, count: 4)),
            Setting(name: "idlm_svn_en", placement: Placement(array: 0, offset: 0x14, bit: 4, count: 4)),
            Setting(name: "rbe_m_svn", placement: Placement(array: 0, offset: 0x1C, bit: 0, count: 32)),
            Setting(name: "dnx", placement: Placement(array: 0, offset: 0x20, bit: 0, count: 4)),
            Setting(name: "ftpm_ek", placement: Placement(array: 0, offset: 0x20, bit: 0, count: 1)),
            Setting(name: "idlm_m_svn", placement: Placement(array: 0, offset: 0x20, bit: 0, count: 32)),
            Setting(name: "ftpm_ah", placement: Placement(array: 0, offset: 0x20, bit: 1, count: 10)),
            Setting(name: "emmc", placement: Placement(array: 0, offset: 0x20, bit: 12, count: 4)),
            Setting(name: "dal_seed", placement: Placement(array: 0, offset: 0x20, bit: 16, count: 1)),
            Setting(name: "ufs", placement: Placement(array: 0, offset: 0x20, bit: 16, count: 4)),
            Setting(name: "drop_ship_seal", placement: Placement(array: 0, offset: 0x20, bit: 17, count: 1)),
            Setting(name: "spi", placement: Placement(array: 0, offset: 0x20, bit: 20, count: 4)),
            Setting(name: "lo_id", placement: Placement(array: 0, offset: 0x24, bit: 0, count: 7)),
            Setting(name: "lo_id_v", placement: Placement(array: 0, offset: 0x24, bit: 7, count: 1)),
            Setting(name: "fw_type", placement: Placement(array: 0, offset: 0x24, bit: 8, count: 3)),
            Setting(name: "fw_type_v", placement: Placement(array: 0, offset: 0x24, bit: 11, count: 1)),
            Setting(name: "oem_id_v", placement: Placement(array: 0, offset: 0x24, bit: 15, count: 1)),
            Setting(name: "pfr_en", placement: Placement(array: 0, offset: 0x24, bit: 15, count: 1)),
            Setting(name: "plat_id_v", placement: Placement(array: 0, offset: 0x24, bit: 16, count: 1)),
            Setting(name: "sb_acm_svn", placement: Placement(array: 0, offset: 0x28, bit: 0, count: 15)),
            Setting(name: "dcrt_ed", placement: Placement(array: 0, offset: 0x28, bit: 4, count: 4)),
            Setting(name: "sb_km_svn", placement: Placement(array: 0, offset: 0x28, bit: 15, count: 15)),
            Setting(name: "sb_bsmm_svn", placement: Placement(array: 0, offset: 0x28, bit: 30, count: 15)),
            Setting(name: "cse_bootstrap_m_svn", placement: Placement(array: 0, offset: 0x34, bit: 0, count: 32)),
            Setting(name: "rpmc_mc", placement: Placement(array: 0, offset: 0x48, bit: 0, count: 16)),
            Setting(name: "oem_cfg_done", placement: Placement(array: 0, offset: 0x50, bit: 0, count: 1)),
            Setting(name: "glitch_d_dis", placement: Placement(array: 0, offset: 0x54, bit: 0, count: 1)),
            Setting(name: "rpmb_dis", placement: Placement(array: 0, offset: 0x54, bit: 6, count: 1)),
            Setting(name: "rpmb_rb_dis", placement: Placement(array: 0, offset: 0x54, bit: 7, count: 1)),
            Setting(name: "hash_con_dis", placement: Placement(array: 0, offset: 0x54, bit: 10, count: 1)),
            Setting(name: "pch_cosig_en", placement: Placement(array: 0, offset: 0x54, bit: 15, count: 1)),
            Setting(name: "rmd", placement: Placement(array: 0, offset: 0x54, bit: 17, count: 1)),
            Setting(name: "dphy_dis", placement: Placement(array: 0, offset: 0x54, bit: 18, count: 1)),
            Setting(name: "oem_kh_0_v", placement: Placement(array: 0, offset: 0x54, bit: 19, count: 1)),
            Setting(name: "dcrt_en", placement: Placement(array: 0, offset: 0x54, bit: 20, count: 1)),
            Setting(name: "txt_en", placement: Placement(array: 0, offset: 0x54, bit: 21, count: 1)),
            Setting(name: "oem_kh_1_v", placement: Placement(array: 0, offset: 0x54, bit: 22, count: 1)),
            Setting(name: "oem_kh_2_s", placement: Placement(array: 0, offset: 0x54, bit: 24, count: 1)),
            Setting(name: "oem_kh_2_v", placement: Placement(array: 0, offset: 0x54, bit: 25, count: 1)),
            Setting(name: "rpmb_mc", placement: Placement(array: 0, offset: 0x58, bit: 16, count: 16)),
            Setting(name: "oem_id", placement: Placement(array: 0, offset: 0x5C, bit: 0, count: 16)),
            Setting(name: "cpu_cosign_en", placement: Placement(array: 0, offset: 0x60, bit: 0, count: 1)),
            Setting(name: "amt_hw_en", placement: Placement(array: 0, offset: 0x60, bit: 9, count: 1)),
            Setting(name: "comp_eom", placement: Placement(array: 0, offset: 0x60, bit: 10, count: 1)),
            Setting(name: "doss", placement: Placement(array: 0, offset: 0x60, bit: 11, count: 1)),
            Setting(name: "fdv_en", placement: Placement(array: 0, offset: 0x60, bit: 12, count: 1)),
            Setting(name: "tcss_dis", placement: Placement(array: 0, offset: 0x64, bit: 0, count: 1)),
            Setting(name: "pavp_lite_en", placement: Placement(array: 0, offset: 0x64, bit: 17, count: 1)),
            Setting(name: "oem_kh_0_r", placement: Placement(array: 0, offset: 0x68, bit: 17, count: 1)),
            Setting(name: "oem_kh_1_r", placement: Placement(array: 0, offset: 0x68, bit: 18, count: 1)),
            Setting(name: "oem_kh_2_r", placement: Placement(array: 0, offset: 0x68, bit: 19, count: 1)),
            Setting(name: "spiral_cpu_en", placement: Placement(array: 0, offset: 0x68, bit: 20, count: 1)),
            Setting(name: "refurb_ctr", placement: Placement(array: 0, offset: 0x68, bit: 21, count: 5)),
        ])
}

