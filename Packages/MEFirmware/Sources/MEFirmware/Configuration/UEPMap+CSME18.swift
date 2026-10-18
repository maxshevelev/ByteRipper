// The FPF/UEP settings of CSME 18, as Flash Image Tool 18.1 lays them out — emitted by
// `Skills/me-eom-structures/scripts/uep18_map.py` from the tool's own
// `UEPs_Data` documents. Names, labels, sections, option words and places
// are the tool's; nothing here is read out of a dump.
//
// A setting's place is an array and an offset into it, in the arrays that
// follow the container's 8-byte `$UEP` header (signature, CRC-16,
// reserved). Each array is `arraySize` bytes.
//
// What the arrays hold on a vendor dump is the state the build wrote, not
// the fuses the platform will burn: see `Design/ME_STRUCTURES.md`.

import Foundation

extension UEPMap {
    /// The FPF settings, as the tool lays them out.
    public static let csme18 = UEPMap(
        name: "CSME 18 (Flash Image Tool 18.1)",
        settings: [
            Setting(name: "ESE_CFG_DONE", placement: Placement(array: 0, offset: 0x10, bit: 0, count: 1)),
            Setting(name: "ESE_TRC_EN", placement: Placement(array: 0, offset: 0x10, bit: 1, count: 1)),
            Setting(name: "OEM_CFG_DONE", placement: Placement(array: 0, offset: 0x40, bit: 0, count: 1)),
            Setting(name: "GLITCH_D_EN", placement: Placement(array: 0, offset: 0x40, bit: 1, count: 1)),
            Setting(name: "FW_TYPE", placement: Placement(array: 0, offset: 0x48, bit: 27, count: 3)),
            Setting(name: "LO_ID_V", placement: Placement(array: 0, offset: 0x4C, bit: 4, count: 1)),
            Setting(name: "OEM_ID_V", placement: Placement(array: 0, offset: 0x4C, bit: 6, count: 1)),
            Setting(name: "FW_TYPE_V", placement: Placement(array: 0, offset: 0x4C, bit: 9, count: 1)),
            Setting(name: "OEM_KH_0_V", placement: Placement(array: 0, offset: 0x4C, bit: 14, count: 1)),
            Setting(name: "OEM_KH_1_V", placement: Placement(array: 0, offset: 0x4C, bit: 15, count: 1)),
            Setting(name: "KM_ID_V", placement: Placement(array: 0, offset: 0x4C, bit: 25, count: 1)),
            Setting(name: "BTG_PROFILE_V", placement: Placement(array: 0, offset: 0x4C, bit: 26, count: 1)),
            Setting(name: "PLAT_ID_V", placement: Placement(array: 1, offset: 0x4, bit: 18, count: 1)),
            Setting(name: "KM_ID", placement: Placement(array: 0, offset: 0x48, bit: 23, count: 4), label: "Key Manifest ID", section: "BootGuardConfiguration", help: "ODM identifier used during the Key manifest authentication process. This setting is only configurable, and must be non-0, when OEM Public Key Hash is set (See PlatformIntegrity/OemPublicKeyHash)."),
            Setting(name: "BTG_PROFILE", placement: Placement(array: 0, offset: 0x48, bit: 30, count: 3), label: "Boot Guard Profile", section: "BootGuardConfiguration", help: "This option configures the which boot guard policy profile will be used. Note: all profiles with the exception of profile 0 - fvme support txt being enabled.", options: [0: "Boot Guard Disabled", 3: "Debug Profile", 4: "Verified Boot", 5: "Verified and Measured Boot"]),
            Setting(name: "BSP_INIT_DIS", placement: Placement(array: 0, offset: 0x4C, bit: 23, count: 1), label: "BSP Initialization", section: "BootGuardConfiguration", help: "This setting determines BSP behavior when it receives an INIT signal. When set to 'Enabled' BSP will behave normally if it receives an INIT (Disabled BSP Initialization (DBI) bit = 0). When set to 'Disabled' BSP will shutdown if it receives an INIT ('DBI' bit = 1).", options: [0: "Enabled", 1: "Disabled"]),
            Setting(name: "CPU_DEBUG_DIS", placement: Placement(array: 0, offset: 0x4C, bit: 24, count: 1), label: "CPU Debugging", section: "BootGuardConfiguration", help: "This setting determines if CPU debug modes will be displayed. When set to 'Yes' CPU debugging is enabled.", options: [0: "Enabled", 1: "Disabled"]),
            Setting(name: "BPK_DISABLE", placement: Placement(array: 0, offset: 0x24, bit: 0, count: 1), label: "MIPI I3C Debug", section: "Debug", options: [0: "Enabled", 1: "Disabled"]),
            Setting(name: "FDV_EN", placement: Placement(array: 0, offset: 0x4C, bit: 3, count: 1), label: "Flash Descriptor Verification Supported", section: "DescConfiguration", options: [0: "No", 1: "Yes"]),
            Setting(name: "MRP_EN", placement: Placement(array: 0, offset: 0x4C, bit: 20, count: 1), label: "MRP Enabled", section: "ImageSettings", help: "Enable MRP support for critical layout components", options: [0: "No", 1: "Yes"]),
            Setting(name: "DFX_DISABLE_CLTAP", placement: Placement(array: 0, offset: 0x20, bit: 2, count: 1), label: "Disable JTAG", section: "IntelDebugProtectionTechnology", help: "When this setting is enabled, JTAG access will be disabled, when manufacture is completed. An Intel DPT token can be used to re-enable JTAG.", options: [0: "No", 1: "Yes"]),
            Setting(name: "DFX_DISABLE_BSCAN", placement: Placement(array: 0, offset: 0x20, bit: 3, count: 1), label: "Disable Boundary Scan", section: "IntelDebugProtectionTechnology", help: "When this setting is enabled, BSCAN access will be disabled, when manufacture is completed. An Intel DPT token can be used to re-enable BSCAN.", options: [0: "No", 1: "Yes"]),
            Setting(name: "KM_SVN_EN", placement: Placement(array: 0, offset: 0x4C, bit: 16, count: 1), label: "Key Manifest FVC State", section: "IntelFpfFirmwareVersionControlConfiguration", help: "Configure usage of Intel FPF for Intel(R) Firmware Version Control (Intel(R) FVC) mechanism for Secure Boot Key Manifest component.", options: [0: "Disabled", 1: "Enabled"]),
            Setting(name: "BSMM_SVN_EN", placement: Placement(array: 0, offset: 0x4C, bit: 17, count: 1), label: "BSMM FVC State", section: "IntelFpfFirmwareVersionControlConfiguration", options: [0: "Disabled", 1: "Enabled"]),
            Setting(name: "OEM_KM_SVN_EN", placement: Placement(array: 0, offset: 0x4C, bit: 18, count: 1), label: "OEM Key Manifest FVC State", section: "IntelFpfFirmwareVersionControlConfiguration", help: "Configure usage of Intel FPF for Intel(R) Firmware Version Control (Intel(R) FVC) mechanism for OEM Key Manifest component.", options: [0: "Disabled", 1: "Enabled"]),
            Setting(name: "GSC_FW_SVN_EN", placement: Placement(array: 0, offset: 0x4C, bit: 22, count: 1), label: "GSC HW SVN Enabled", section: "IntelFpfFirmwareVersionControlConfiguration", help: "Configure usage of Intel FPF for Intel(R) Firmware Version Control (Intel(R) FVC) mechanism for GSC FW Manifest component.", options: [0: "Disabled", 1: "Enabled"]),
            Setting(name: "ESE_ROM_SVN_EN", placement: Placement(array: 1, offset: 0x4, bit: 0, count: 1), label: "Intel(R) Silicon Security Engine ROM FVC State", section: "IntelFpfFirmwareVersionControlConfiguration", help: "Configure usage of Intel FPF mechanism for ESE ROM component.", options: [0: "Disabled", 1: "Enabled"]),
            Setting(name: "CSE_BOOTSTRAP_SVN_EN", placement: Placement(array: 1, offset: 0x4, bit: 19, count: 1), label: "CSE Bootstrap FVC State", section: "IntelFpfFirmwareVersionControlConfiguration", help: "Configure usage of Intel FPF for Intel(R) Firmware Version Control (Intel(R) FVC) mechanism for CSE Bootstrap component.", options: [0: "Disabled", 1: "Enabled"]),
            Setting(name: "CSE_FW_SVN_EN", placement: Placement(array: 1, offset: 0x4, bit: 20, count: 1), label: "CSE FVC State", section: "IntelFpfFirmwareVersionControlConfiguration", help: "Configure usage of Intel FPF for Intel(R) Firmware Version Control (Intel(R) FVC) mechanism for CSE component.", options: [0: "Disabled", 1: "Enabled"]),
            Setting(name: "AMT_HW_EN", placement: Placement(array: 0, offset: 0x4C, bit: 19, count: 1), label: "Manageability Application HW State", section: "IntelManageabilityAppConfiguration", help: "This setting will permanently disable Manageability hardware through platform FPFs. At End-of-Manufacturing (EOM), enable/disable policy value is committed to FPF and can never be changed. Permanently disabling Manageability HW via this setting requires 'Manageability Application Supported' is set to permanently disabled and 'Intel(R) ME Network Services Supported' is set to disabled. Note: When 'Manageability Application Hardware Status' is Enabled but 'Manageability Application Supported' is set to permanently disabled and 'Intel(R) ME Network Services Supported' is set to disabled, Manageability HW is disabled by a soft strap.", options: [0: "Enabled", 1: "Disabled"]),
            Setting(name: "NCC", placement: Placement(array: 0, offset: 0x4C, bit: 5, count: 1), label: "Persistent PRTC Backup Power", section: "IntelMeBootConfiguration", help: "FPF that indicates if the device is designed such that it may lose PRTC power more than 10 times throughout the normal lifecycle of the product and hence has no persistent time or AR protection. At EOM, this value is burned to an FPF, and can never be changed.", options: [0: "Exists", 1: "None"]),
            Setting(name: "FTPM_EN", placement: Placement(array: 0, offset: 0x4C, bit: 1, count: 1), label: "Intel(R) PTT Supported [FPF]", section: "IntelPttConfiguration", help: "This setting will permanently disable Intel(R) PTT through platform FPFs. Caution: Using this option will permanently disable Intel(R) PTT on the platform hardware.", options: [0: "No", 1: "Yes"]),
            Setting(name: "OEM_ID", placement: Placement(array: 0, offset: 0x48, bit: 0, count: 16), label: "UPID OEM ID [FPF]", section: "IntelUniquePlatformIdConfiguration", help: "This setting allows OEMs to configure their PCIe Vendor ID Unique ID into the platform FPFs."),
            Setting(name: "PLAT_ID", placement: Placement(array: 1, offset: 0x4, bit: 0, count: 16), label: "DnX OEM Platform ID", section: "OEMandPlatformIDs", help: "This setting allows OEMs to configure a Unique Platform ID into the base FPFs. Note: The OEM Platform ID FPF and Platform ID for the DnX Image should match."),
            Setting(name: "DNX", placement: Placement(array: 1, offset: 0x4, bit: 16, count: 1), label: "DnX State", section: "OEMandPlatformIDs", help: "DnX permanent enable/disable FPF", options: [0: "Enabled", 1: "Disabled"]),
            Setting(name: "OEM_KP", placement: Placement(array: 0, offset: 0x4C, bit: 7, count: 1), label: "OEM Key Manifest State", section: "PlatformIntegrity", options: [0: "Not-Present", 1: "Present"]),
            Setting(name: "OEM_RH_EN", placement: Placement(array: 0, offset: 0x4C, bit: 13, count: 1), label: "OEM Key Revocation Supported", section: "PlatformIntegrity", help: "Enabling the OEM key revocation mechanism requires 'OEM Public Key Hash' and 'Second OEM key hash' to be configured.", options: [0: "No", 1: "Yes"]),
            Setting(name: "RPMC_EN", placement: Placement(array: 0, offset: 0x4C, bit: 2, count: 1), label: "RPMC FW Supported", section: "RpmcConfiguration", help: "This setting determines if RPMC is enabled. Note: The SPI parts being used need to support RPMC In order to use this feature.", options: [0: "No", 1: "Yes"]),
            Setting(name: "RPMC_OVER_EC_EN", placement: Placement(array: 0, offset: 0x4C, bit: 27, count: 1), label: "RPMC Over EC Supported", section: "RpmcConfiguration", help: "This setting determines if RPMC is enabled over eSPI OOB to be handled by EC (EC might provide RPMC capabilities or offload it to another SPI flash device).", options: [0: "No", 1: "Yes"]),
            Setting(name: "RPMC_RB", placement: Placement(array: 1, offset: 0x4, bit: 17, count: 1), label: "RPMC Rebinding Supported", section: "RpmcConfiguration", help: "This setting determines if Rebinding of RPMC enabled SPI parts is enabled.", options: [0: "No", 1: "Yes"]),
            Setting(name: "TXT_EN", placement: Placement(array: 0, offset: 0x4C, bit: 8, count: 1), label: "TXT Supported", section: "TxtConfiguration", help: "This setting determines is enabled for the platform.", options: [0: "No", 1: "Yes"]),
        ],
        arrayStart: 8,
        arraySize: 0x80)
}

