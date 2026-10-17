// The FPF/UEP settings of CSME 16, as Modular Flash Image Tool 16.1.42 names them — emitted by
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
    public static let csme16 = UEPMap(
        name: "CSME 16 (Modular Flash Image Tool 16.1.42)",
        settings: [
            Setting(name: "oem_cfg_done", placement: Placement(array: 0, offset: 0x50, bit: 0, count: 1)),
            Setting(name: "TrcEnableFpf", placement: Placement(array: 0, offset: 0x50, bit: 1, count: 1)),
            Setting(name: "glitch_d_dis", placement: Placement(array: 0, offset: 0x54, bit: 0, count: 1)),
            Setting(name: "cpu_cosign_en", placement: Placement(array: 0, offset: 0x60, bit: 0, count: 1)),
            Setting(name: "comp_eom", placement: Placement(array: 0, offset: 0x60, bit: 10, count: 1)),
            Setting(name: "lo_id", placement: Placement(array: 0, offset: 0x64, bit: 0, count: 7)),
            Setting(name: "fw_type", placement: Placement(array: 0, offset: 0x64, bit: 7, count: 3)),
            Setting(name: "lo_id_v", placement: Placement(array: 0, offset: 0x64, bit: 10, count: 1)),
            Setting(name: "fw_type_v", placement: Placement(array: 0, offset: 0x64, bit: 11, count: 1)),
            Setting(name: "oem_id_v", placement: Placement(array: 0, offset: 0x64, bit: 13, count: 1)),
            Setting(name: "plat_id_v", placement: Placement(array: 0, offset: 0x64, bit: 14, count: 1)),
            Setting(name: "sb", placement: Placement(array: 0, offset: 0x64, bit: 15, count: 1)),
            Setting(name: "FBGAcmEn", placement: Placement(array: 0, offset: 0x64, bit: 16, count: 1), label: "Force Boot Guard ACM Enabled"),
            Setting(name: "ProtectBiosEnvironment", placement: Placement(array: 0, offset: 0x64, bit: 19, count: 1), label: "Protect BIOS Environment Enabled"),
            Setting(name: "MeasuredBoot", placement: Placement(array: 0, offset: 0x64, bit: 20, count: 1), label: "Measured Boot Enabled"),
            Setting(name: "VerifiedBoot", placement: Placement(array: 0, offset: 0x64, bit: 21, count: 1), label: "Verified Boot Enabled"),
            Setting(name: "ftpm_ek", placement: Placement(array: 0, offset: 0x68, bit: 0, count: 1)),
            Setting(name: "ftpm_ah", placement: Placement(array: 0, offset: 0x68, bit: 1, count: 10)),
            Setting(name: "drop_ship_seal", placement: Placement(array: 0, offset: 0x68, bit: 16, count: 1)),
            Setting(name: "oem_kh_0_r", placement: Placement(array: 0, offset: 0x68, bit: 17, count: 1)),
            Setting(name: "oem_kh_1_r", placement: Placement(array: 0, offset: 0x68, bit: 18, count: 1)),
            Setting(name: "oem_kh_2_r", placement: Placement(array: 0, offset: 0x68, bit: 19, count: 1)),
            Setting(name: "spiral_cpu_en", placement: Placement(array: 0, offset: 0x68, bit: 20, count: 1)),
            Setting(name: "refurb_ctr", placement: Placement(array: 0, offset: 0x68, bit: 21, count: 5)),
            Setting(name: "soc_cl", placement: Placement(array: 0, offset: 0x68, bit: 31, count: 1)),
            Setting(name: "spi", placement: Placement(array: 0, offset: 0x74, bit: 0, count: 1)),
            Setting(name: "ufs", placement: Placement(array: 0, offset: 0x74, bit: 1, count: 1)),
            Setting(name: "emmc", placement: Placement(array: 0, offset: 0x74, bit: 2, count: 1)),
            Setting(name: "rpmb_dis", placement: Placement(array: 0, offset: 0x74, bit: 6, count: 1)),
            Setting(name: "rpmb_rb_dis", placement: Placement(array: 0, offset: 0x74, bit: 7, count: 1)),
            Setting(name: "hash_con_dis", placement: Placement(array: 0, offset: 0x74, bit: 10, count: 1)),
            Setting(name: "pch_cosig_en", placement: Placement(array: 0, offset: 0x74, bit: 15, count: 1)),
            Setting(name: "rmd", placement: Placement(array: 0, offset: 0x74, bit: 17, count: 1)),
            Setting(name: "oem_kh_0_v", placement: Placement(array: 0, offset: 0x74, bit: 19, count: 1)),
            Setting(name: "oem_rsa_1_s", placement: Placement(array: 0, offset: 0x74, bit: 23, count: 1)),
            Setting(name: "oem_kh_2_s", placement: Placement(array: 0, offset: 0x74, bit: 24, count: 1)),
            Setting(name: "oem_kh_2_v", placement: Placement(array: 0, offset: 0x74, bit: 25, count: 1)),
            Setting(name: "oem_rsa_2_s", placement: Placement(array: 0, offset: 0x74, bit: 26, count: 1)),
            Setting(name: "dcrt_en", placement: Placement(array: 0, offset: 0x74, bit: 28, count: 1)),
            Setting(name: "ErrorEnforcement_0", placement: Placement(array: 0, offset: 0x74, bit: 30, count: 1), label: "Error Enforcement Policy 0"),
            Setting(name: "ErrorEnforcement_1", placement: Placement(array: 0, offset: 0x74, bit: 31, count: 1), label: "Error Enforcement Policy 1"),
            Setting(name: "rpmc_mc", placement: Placement(array: 0, offset: 0x78, bit: 0, count: 16)),
            Setting(name: "rpmb_mc", placement: Placement(array: 0, offset: 0x78, bit: 16, count: 16)),
            Setting(name: "BtGuardCpuDebugEnable", placement: Placement(array: 0, offset: 0x64, bit: 17, count: 1), label: "CPU Debugging", section: "BootGuardConfiguration", help: "This setting determines if CPU debug modes will be displayed.  When set to 'Yes' CPU debugging is enabled."),
            Setting(name: "BtGuardBspInitEnable", placement: Placement(array: 0, offset: 0x64, bit: 18, count: 1), label: "BSP Initialization", section: "BootGuardConfiguration", help: "This setting determines BSP behavior when it receives an INIT signal. When set to 'Enabled' BSP will behave normally if it receives an INIT (Disabled BSP Initialization (DBI) bit = 0). When set to 'Disabled' BSP will shutdown if it receives an INIT ('DBI' bit = 1)."),
            Setting(name: "BtGuardKeyManifestId", placement: Placement(array: 0, offset: 0x64, bit: 22, count: 4), label: "Key Manifest ID", section: "BootGuardConfiguration", help: "ODM identifier used during the Key manifest authentication process. This setting is only configurable, and must be non-0, when OEM Public Key Hash is set (See PlatformIntegrity/OemPublicKeyHash)."),
            Setting(name: "MrpEnabled", placement: Placement(array: 0, offset: 0x60, bit: 9, count: 1), label: "MRP Enabled", section: "BuildResults", help: "Enable MRP support for critical layout components"),
            Setting(name: "FdvEnabled", placement: Placement(array: 0, offset: 0x64, bit: 12, count: 1), label: "Flash Descriptor Verification Enabled", section: "DescConfiguration"),
            Setting(name: "MngHwStatus", placement: Placement(array: 0, offset: 0x60, bit: 8, count: 1), label: "Manageability Application Hardware Status", section: "IntelAmtConfiguration", help: "This setting will permanently disable Manageability hardware through platform FPFs. At End-of-Manufacturing (EOM), enable/disable policy value is committed to FPF and can never be changed. Permanently disabling Manageability HW via this setting requires 'Manageability Application Supported' is set to permanently disabled and 'Intel(R) ME Network Services Supported' is set to disabled. Note: When 'Manageability Application Hardware Status' is Enabled but 'Manageability Application Supported' is set to permanently disabled and 'Intel(R) ME Network Services Supported' is set to disabled, Manageability HW is disabled by a soft strap."),
            Setting(name: "PmcSvnEnabled", placement: Placement(array: 0, offset: 0x60, bit: 1, count: 1), label: "PMC SVN Enabled", section: "IntelFpfFirmwareVersionControlConfiguration", help: "Configure usage of Intel FPF for Intel(R) Firmware Version Control (Intel(R) FVC) mechanism for PMC component."),
            Setting(name: "UcodeSvnEnabled", placement: Placement(array: 0, offset: 0x60, bit: 2, count: 1), label: "uCode SVN Enabled", section: "IntelFpfFirmwareVersionControlConfiguration", help: "Configure usage of Intel FPF for Intel(R) Firmware Version Control (Intel(R) FVC) mechanism for uCode component."),
            Setting(name: "RbeSvnEnabled", placement: Placement(array: 0, offset: 0x60, bit: 3, count: 1), label: "CSE SVN Enabled", section: "IntelFpfFirmwareVersionControlConfiguration", help: "Configure usage of Intel FPF for Intel(R) Firmware Version Control (Intel(R) FVC) mechanism for CSE component."),
            Setting(name: "KmSvnEnabled", placement: Placement(array: 0, offset: 0x60, bit: 4, count: 1), label: "Secure Boot Key Manifest SVN Enabled", section: "IntelFpfFirmwareVersionControlConfiguration", help: "Configure usage of Intel FPF for Intel(R) Firmware Version Control (Intel(R) FVC) mechanism for Secure Boot Key Manifest component."),
            Setting(name: "BsmmSvnEnabled", placement: Placement(array: 0, offset: 0x60, bit: 5, count: 1), label: "BIOS Startup Module Manifest SVN Enabled", section: "IntelFpfFirmwareVersionControlConfiguration", help: "Configure usage of Intel FPF for Intel(R) Firmware Version Control (Intel(R) FVC) mechanism for BIOS Startup Module Manifest component."),
            Setting(name: "RotSvnEnabled", placement: Placement(array: 0, offset: 0x60, bit: 6, count: 1), label: "ROT KM SVN Enabled", section: "IntelFpfFirmwareVersionControlConfiguration", help: "Configure usage of Intel FPF for Intel(R) Firmware Version Control (Intel(R) FVC) mechanism for ROT Key Manifest component."),
            Setting(name: "OEM_PIM_ARB_EN", placement: Placement(array: 0, offset: 0x60, bit: 13, count: 1), label: "OPIM SVN Enabled", section: "IntelFpfFirmwareVersionControlConfiguration", help: "Configure usage of Intel FPF for Intel(R) Firmware Version Control (Intel(R) FVC) mechanism for OPIM"),
            Setting(name: "OEM_CIM_ARB_EN", placement: Placement(array: 0, offset: 0x60, bit: 14, count: 1), label: "OCIM SVN Enabled", section: "IntelFpfFirmwareVersionControlConfiguration", help: "Configure usage of Intel FPF for Intel(R) Firmware Version Control (Intel(R) FVC) mechanism for OCIM"),
            Setting(name: "CseBootstrapSvnEnabled", placement: Placement(array: 0, offset: 0x74, bit: 11, count: 1), label: "CSE SVN Enabled", section: "IntelFpfFirmwareVersionControlConfiguration", help: "Configure usage of Intel FPF for Intel(R) Firmware Version Control (Intel(R) FVC) mechanism for CSE Bootstrap component."),
            Setting(name: "IdlmSvnEnabled", placement: Placement(array: 0, offset: 0x74, bit: 12, count: 1), label: "IDLM SVN Enabled", section: "IntelFpfFirmwareVersionControlConfiguration", help: "Configure usage of Intel FPF for Intel(R) Firmware Version Control (Intel(R) FVC) mechanism for IDLM component."),
            Setting(name: "DnxSvnEnabled", placement: Placement(array: 0, offset: 0x74, bit: 13, count: 1), label: "DNX SVN Enabled", section: "IntelFpfFirmwareVersionControlConfiguration", help: "Configure usage of Intel FPF for Intel(R) Firmware Version Control (Intel(R) FVC) mechanism for DNX component."),
            Setting(name: "OemKmSvnEnabled", placement: Placement(array: 0, offset: 0x74, bit: 14, count: 1), label: "OEM Key Manifest SVN Enabled", section: "IntelFpfFirmwareVersionControlConfiguration", help: "Configure usage of Intel FPF for Intel(R) Firmware Version Control (Intel(R) FVC) mechanism for OEM Key Manifest component."),
            Setting(name: "PrtcBackupPower", placement: Placement(array: 0, offset: 0x60, bit: 7, count: 1), label: "Persistent PRTC Backup Power", section: "IntelMeBootConfiguration", help: "FPF that indicates if the device is designed such that it may lose PRTC power more than 10 times throughout the normal lifecycle of the product and hence has no persistent time or AR protection. At EOM, this value is burned to an FPF, and can never be changed."),
            Setting(name: "PttSupportedFpf", placement: Placement(array: 0, offset: 0x74, bit: 27, count: 1), label: "Intel(R) PTT Supported [FPF]", section: "IntelPttConfiguration", help: "This setting will permanently disable Intel(R) PTT through platform FPFs.  Caution: Using this option will permanently disable Intel(R) PTT on the platform hardware."),
            Setting(name: "DnxEnabled", placement: Placement(array: 0, offset: 0x74, bit: 8, count: 1), label: "DnX Enabled", section: "OEMandPlatformIDs", help: "DnX permanent enable/disable FPF"),
            Setting(name: "CPU_AAB_ENABLED", placement: Placement(array: 0, offset: 0x60, bit: 0, count: 1), label: "CPU Automotive Authorized Boot", section: "OemPchCpuSigning", help: "Enable Automotive Authorized Boot FPF on CPU"),
            Setting(name: "PCH_AAB_ENABLED", placement: Placement(array: 0, offset: 0x74, bit: 15, count: 1), label: "PCH Automotive Authorized Boot", section: "OemPchCpuSigning", help: "Enable Automotive Authorized Boot FPF on PCH"),
            Setting(name: "OemManifestSet", placement: Placement(array: 0, offset: 0x74, bit: 9, count: 1), section: "PlatformIntegrity"),
            Setting(name: "OemKeyRevEnable", placement: Placement(array: 0, offset: 0x74, bit: 16, count: 1), label: "Oem Key Revocation Enable", section: "PlatformIntegrity", help: "Enabling the OEM key revocation mechanism requires 'OEM Public Key Hash' and 'Second OEM key hash' to be configured."),
            Setting(name: "HashConfigFPF", placement: Placement(array: 0, offset: 0x74, bit: 18, count: 1), section: "PlatformIntegrity"),
            Setting(name: "OemRsaKeySize", placement: Placement(array: 0, offset: 0x74, bit: 20, count: 1), section: "PlatformIntegrity"),
            Setting(name: "HashConfigFPF_1", placement: Placement(array: 0, offset: 0x74, bit: 21, count: 1), section: "PlatformIntegrity"),
            Setting(name: "oem_kh_1_v", placement: Placement(array: 0, offset: 0x74, bit: 22, count: 1), section: "PlatformIntegrity"),
            Setting(name: "RpmcOverEc", placement: Placement(array: 0, offset: 0x60, bit: 12, count: 1), label: "RPMC Over EC Supported", section: "RpmcConfiguration", help: "This setting determines if RPMC is enabled over eSPI OOB to be handled by EC (EC might provide RPMC capabilities or offload it to another SPI flash device)."),
            Setting(name: "RpmcSupported", placement: Placement(array: 0, offset: 0x74, bit: 4, count: 1), label: "RPMC Supported", section: "RpmcConfiguration", help: "This setting determines if RPMC is enabled. Note: The SPI parts being used need to support RPMC In order to use this feature."),
            Setting(name: "RpmcRebindEn", placement: Placement(array: 0, offset: 0x74, bit: 5, count: 1), label: "RPMC Rebinding Enabled", section: "RpmcConfiguration", help: "This setting determines if Rebinding of RPMC enabled SPI parts is enabled."),
            Setting(name: "TxtSupported", placement: Placement(array: 0, offset: 0x74, bit: 29, count: 1), label: "TXT Supported", section: "TxtConfiguration", help: "With the introduction of Converged Boot Guard & Intel TXT(CBnT), this configuration setting determines if TXT is supported on the platform for the ACM module.\n\nNo = Intel Boot Guard Only Support (Client). Used if TXT is not going to be supported (non-vPro).\n\nYes = Support Intel TXT on platform (Intel(R) vPro).\n\nNote: This setting will be permanently set in the FPFs at close of manufacturing."),
        ])
}

