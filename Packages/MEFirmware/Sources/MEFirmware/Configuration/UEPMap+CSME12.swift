// The FPF/UEP settings of CSME 12, as Flash Image Tool 12 lays them out — emitted by
// `Skills/me-eom-structures/scripts/uep12_map.py` from the tool's own
// `Uep` and configuration class documents. Names, labels, sections,
// option words and places are the tool's; nothing here is read out of a
// dump.
//
// A setting's place is an array and an offset into it, in the four 0x80-
// byte arrays that follow the container's 8-byte `$UEP` header
// (signature, CRC-16, reserved). A name the tool places in several arrays
// is kept once, where it first appears.
//
// What the arrays hold on a vendor dump is the state the build wrote, not
// the fuses the platform will burn: see `Design/ME_STRUCTURES.md`.

import Foundation

extension UEPMap {
    /// The FPF settings, as the tool lays them out.
    public static let csme12 = UEPMap(
        name: "CSME 12 (Flash Image Tool 12)",
        settings: [
            Setting(name: "dnx", placement: Placement(array: 0, offset: 0x20, bit: 0, count: 4), label: "DNX"),
            Setting(name: "sb", placement: Placement(array: 0, offset: 0x20, bit: 4, count: 4), label: "SB"),
            Setting(name: "emmc", placement: Placement(array: 0, offset: 0x20, bit: 12, count: 4), label: "EMMC"),
            Setting(name: "ufs", placement: Placement(array: 0, offset: 0x20, bit: 16, count: 4), label: "UFS"),
            Setting(name: "spi", placement: Placement(array: 0, offset: 0x20, bit: 20, count: 4), label: "SPI"),
            Setting(name: "soc_cl", placement: Placement(array: 0, offset: 0x20, bit: 24, count: 4), label: "SOC_CL"),
            Setting(name: "rbe_m_svn_en", placement: Placement(array: 0, offset: 0x24, bit: 0, count: 4), label: "RBE_M_SVN_EN"),
            Setting(name: "rpmc_en", placement: Placement(array: 0, offset: 0x24, bit: 12, count: 4), label: "RPMC_EN"),
            Setting(name: "rmd", placement: Placement(array: 0, offset: 0x24, bit: 28, count: 4), label: "RMD"),
            Setting(name: "dcrt_ed", placement: Placement(array: 0, offset: 0x28, bit: 4, count: 4), label: "DCRT_ED"),
            Setting(name: "lo_id", placement: Placement(array: 0, offset: 0x40, bit: 0, count: 7), label: "LO_ID"),
            Setting(name: "lo_id_v", placement: Placement(array: 0, offset: 0x40, bit: 7, count: 1), label: "LO_ID_V"),
            Setting(name: "oem_id_v", placement: Placement(array: 0, offset: 0x40, bit: 14, count: 1), label: "OEM_ID_V"),
            Setting(name: "plat_id_v", placement: Placement(array: 0, offset: 0x40, bit: 15, count: 1), label: "PLAT_ID_V"),
            Setting(name: "fw_type", placement: Placement(array: 0, offset: 0x40, bit: 19, count: 3), label: "FW_TYPE"),
            Setting(name: "fw_type_v", placement: Placement(array: 0, offset: 0x40, bit: 22, count: 1), label: "FW_TYPE_V"),
            Setting(name: "rbe_m_svn", placement: Placement(array: 0, offset: 0x4C, bit: 0, count: 32), label: "RBE_M_SVN"),
            Setting(name: "sb_acm_svn", placement: Placement(array: 1, offset: 0x40, bit: 0, count: 15), label: "SB_ACM_SVN"),
            Setting(name: "sb_km_svn", placement: Placement(array: 1, offset: 0x40, bit: 15, count: 15), label: "SB_KM_SVN"),
            Setting(name: "sb_bsmm_svn", placement: Placement(array: 1, offset: 0x40, bit: 30, count: 15), label: "SB_BSMM_SVN"),
            Setting(name: "ftpm_ek", placement: Placement(array: 1, offset: 0x54, bit: 0, count: 1), label: "FTPM_EK"),
            Setting(name: "ftpm_ah", placement: Placement(array: 1, offset: 0x54, bit: 1, count: 10), label: "FTPM_AH"),
            Setting(name: "dal_seed", placement: Placement(array: 1, offset: 0x54, bit: 16, count: 1), label: "DAL_SEED"),
            Setting(name: "drop_ship_seal", placement: Placement(array: 1, offset: 0x54, bit: 18, count: 1), label: "DROP_SHIP_SEAL"),
            Setting(name: "idlm_m_svn", placement: Placement(array: 1, offset: 0x58, bit: 0, count: 32), label: "IDLM_M_SVN"),
            Setting(name: "BtGuardCpuDebugEnable", placement: Placement(array: 0, offset: 0x44, bit: 1, count: 1), label: "CPU Debugging", section: "BootGuardConfiguration", help: "This setting determines if CPU debug modes will be displayed.  When set to 'Yes' CPU debugging is enabled.", options: [0: "Enabled", 1: "Disabled"]),
            Setting(name: "BtGuardBspInitEnable", placement: Placement(array: 0, offset: 0x44, bit: 2, count: 1), label: "BSP Initialization", section: "BootGuardConfiguration", help: "This setting determines BSP behavior when it receives an INIT signal.  When set to 'Yes', when BSP receives an INIT, BSP will signal an error to the BSS register and enter unrecoverable shutdown.", options: [0: "Enabled", 1: "Disabled"]),
            Setting(name: "BtGuardKeyManifestId", placement: Placement(array: 0, offset: 0x44, bit: 6, count: 4), label: "Key Manifest ID", section: "BootGuardConfiguration", help: "ODM identifier used during the Key manifest authentication process. This setting is only configurable, and must be non-0, when OEM Public Key Hash is set (See PlatformIntegrity/OemPublicKeyHash)."),
            Setting(name: "BtGuardS3Optimize", placement: Placement(array: 0, offset: 0x44, bit: 10, count: 1), label: "S3 Optimization", section: "BootGuardConfiguration", help: "S3 Optimization capability has been deprecated from Intel(R) CSME FW. Refrain from updating or using this field.", options: [0: "Enabled", 1: "Disabled"]),
            Setting(name: "ErrorEnforcement_0", placement: Placement(array: 0, offset: 0x2C, bit: 0, count: 4), label: "Error Enforcement Policy 0", section: "BootGuardProfileSettings"),
            Setting(name: "ErrorEnforcement_1", placement: Placement(array: 0, offset: 0x2C, bit: 4, count: 4), label: "Error Enforcement Policy 1", section: "BootGuardProfileSettings"),
            Setting(name: "FBGAcmEn", placement: Placement(array: 0, offset: 0x44, bit: 0, count: 1), label: "Force Boot Guard ACM Enabled", section: "BootGuardProfileSettings", options: [0: "false", 1: "true"]),
            Setting(name: "ProtectBiosEnvironment", placement: Placement(array: 0, offset: 0x44, bit: 3, count: 1), label: "Protect BIOS Environment Enabled", section: "BootGuardProfileSettings", options: [0: "false", 1: "true"]),
            Setting(name: "MeasuredBoot", placement: Placement(array: 0, offset: 0x44, bit: 4, count: 1), label: "Measured Boot Enabled", section: "BootGuardProfileSettings", options: [0: "false", 1: "true"]),
            Setting(name: "VerifiedBoot", placement: Placement(array: 0, offset: 0x44, bit: 5, count: 1), label: "Verified Boot Enabled", section: "BootGuardProfileSettings", options: [0: "false", 1: "true"]),
            Setting(name: "FdvEnabled", placement: Placement(array: 0, offset: 0x2C, bit: 8, count: 4), label: "Flash Descriptor Verification Enabled", section: "DescConfiguration", options: [12: "No", 15: "Yes"]),
            Setting(name: "PrtcBackupPower", placement: Placement(array: 0, offset: 0x40, bit: 13, count: 1), label: "Persistent PRTC Backup Power", section: "IntelMeBootConfiguration", help: "FPF that indicates if the device is designed such that it may lose PRTC power more than 10 times throughout the normal lifecycle of the product and hence has no persistent time or AR protection. At EOM, this value is burned to an FPF, and can never be changed.", options: [0: "Exists", 1: "None"]),
            Setting(name: "PttSupportedFpf", placement: Placement(array: 0, offset: 0x20, bit: 8, count: 4), label: "Intel(R) PTT Supported [FPF]", section: "IntelPttConfiguration", help: "This setting will permanently disable Intel(R) PTT through platform FPFs.  Caution: Using this option will permanently disable Intel(R) PTT on the platform hardware.", options: [12: "No", 15: "Yes"]),
            Setting(name: "OemVendorId", placement: Placement(array: 0, offset: 0x3C, bit: 0, count: 16), label: "OEM Vendor ID", section: "OEMandPlatformIDs", help: "This setting allows OEMs to configure their Unique ID into the platform FPFs. Note: The OEM Vendor ID FPF and OEM ID for the DnX Image should match."),
            Setting(name: "OemPlatformId", placement: Placement(array: 0, offset: 0x3C, bit: 16, count: 16), label: "OEM Platform ID", section: "OEMandPlatformIDs", help: "This setting allows OEMs to configure a Unique Platform ID into the base FPFs. Note: The OEM Platform ID FPF and Platform ID for the DnX Image should match."),
            Setting(name: "OemManifestSet", placement: Placement(array: 0, offset: 0x40, bit: 17, count: 1), label: "OEM_KP", section: "PlatformIntegrity", options: [0: "No", 1: "Yes"]),
            Setting(name: "TxtSupported", placement: Placement(array: 0, offset: 0x40, bit: 18, count: 1), label: "TXT Supported", section: "TxtConfiguration", help: "This setting determines is enabled for the platform.", options: [0: "No", 1: "Yes"]),
        ],
        arrayStart: 8,
        arraySize: 0x80)
}

