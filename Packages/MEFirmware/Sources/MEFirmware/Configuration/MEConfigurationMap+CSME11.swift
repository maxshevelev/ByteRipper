// The CSME 11 map of the ME configuration — emitted by
// `Skills/me-eom-structures/scripts/fit_map.py` from Flash Image Tool 11.0's
// own layout documents (the spt_fit_layout platform of ME 11).
//
// The family is the tool's own name for the platform half: `_lp`/`_p` is
// the mobile one and `_h`/`_s` the desktop one, and a dump is read with
// the one its descriptor's strap section length names
// (`MEConfigurationMap.forME(major:family:)`).
// Offsets, bits, the tool's own name for each setting (`label`), its option
// labels and the file paths are FIT's, copied out of its
// `ProcessNvar` bindings and value dictionaries; nothing here is read out of a
// dump. FIT 11.0 marks no setting `Auto` — it has no such attribute — so no
// setting here carries that mark.
//
// A generation's map lives in a file of its own: see `MEConfigurationMap.swift`
// for what a map is and why each generation has its own.

import Foundation

extension MEConfigurationMap {
    /// The ME 11 configuration, as FIT 11.0 lays it out. The files stand in the
    /// order a bench reads them, and the rest in the tool's own order.
    public static let csme11 = MEConfigurationMap(
        name: "CSME 11 (Flash Image Tool 11.0, spt_fit_layout)",
        files: [
        File(path: "/home/mca/eom", alias: "EOM", settings: [
            Setting(name: "EOM", offset: 0, length: 1),
        ]),
        File(path: "/home/policy/cfgmgr/cfg_rules", alias: "ME_CONF_WRK", settings: [
            Setting(name: "AmtSupported", offset: 344, length: 1, label: "Intel(R) AMT Supported", help: "This setting allows customers to disable Intel(R) AMT on the platform and force the platform into Standard Manageability mode.  Note: This setting is only applies to Desktop and Workstation platforms.", bits: 0...0, options: [0: "No", 1: "Yes"]),
            Setting(name: "FwUpdEnable", offset: 92, length: 1, label: "Hide MEBx Firmware Update Control", disabledBy: Condition(name: "HideMEBxFwUpdCtrl", value: 1), bits: 0...0, options: [0: "No", 1: "Yes"]),
            Setting(name: "HideMEBxFwUpdCtrl", offset: 88, length: 1, label: "Hide MEBx Firmware Update Control", help: "This setting allows customers to hide the Firmware Update option in the MEBx interface.", bits: 1...1, options: [0: "No", 1: "Yes"]),
            Setting(name: "IshPowerUpState", offset: 404, length: 2, label: "Integrated Sensor Hub Initial Power Up State", help: "This setting allows customers to determine the power up state for ISH.", disabledBy: Condition(name: "IshSupported", value: 0), bits: 10...10, options: [0: "Disabled", 1: "Enabled"]),
            Setting(name: "IshSupported", offset: 344, length: 2, label: "Integrated Sensor Hub Supported", help: "This setting allows customers to disable ISH on the platform.", bits: 10...10, options: [0: "No", 1: "Yes"]),
            Setting(name: "KvmSupported", offset: 344, length: 3, label: "KVM Redirection Supported", help: "This setting allows customers to enable / disable the KVM Redirection capabilities of the firmware.  Note: If this setting have been set to disabled it cannot be re-enabled once the descriptor has been locked.", bits: 18...18, options: [0: "No", 1: "Yes"]),
            Setting(name: "LkHstnPwrUpState", offset: 404, length: 4, label: "Lake Houston Initial Power-up State", help: "Select whether Lake Houston is enabled on platform power-up.", bits: 25...25, options: [0: "Disabled", 1: "Enabled"]),
            Setting(name: "LkHstnSupported", offset: 344, length: 4, label: "Lake Houston Supported", help: "Select whether Lake Houston is supported.", bits: 25...25, options: [0: "No", 1: "Yes"]),
            Setting(name: "MEDynAppLoad", offset: 344, length: 3, label: "Firmware Dynamic Application Loader", help: "This setting enables the Dynamic Application Loader capability of the Intel(R) ME Firmware.", bits: 20...20, options: [0: "Disabled", 1: "Enabled"]),
            Setting(name: "MELanPowerWell", offset: 188, length: 1, label: "LAN Power Well", help: "This setting allows the customer to configure the powerwell that will be used by Intel(R) Integrated LAN.  Note: Recommended setting is SLP_LAN#.", bits: 0...2, options: [0: "Core Well", 1: "SUS Well", 2: "ME Well", 3: "SLP_LAN#"]),
            Setting(name: "MEWlanPowerWell", offset: 200, length: 1, label: "WLAN Power Well", help: "This setting allows the customer to configure the powerwell that will be used by Intel(R) Wireless LAN.  Note: Recommended setting is SLP_WLAN#.", bits: 0...7, options: [128: "Disabled", 129: "Core Well || SLP_S3#", 130: "Primary Well || SLP_SUS#", 131: "ME Well || SLP_A#", 134: "SLP_WLAN#"]),
            Setting(name: "MeClinkEnable", offset: 464, length: 1, label: "Intel (R) ME CLINK Signal Enabled", help: "This setting allows customers to enable / disable the Wireless LAN CLINK signal through Intel (R) ME firmware.  Note: For using Intel(R) vPro Wireless solutions this should be set to 'Yes'.", bits: 0...0, options: [0: "No", 1: "Yes"]),
            Setting(name: "MngAppPowerUpState", offset: 404, length: 1, label: "Manageability Application initial power-up state", help: "This setting allows customers to determine the power up state for Intel(R) AMT or Standard Manageability.  Note: If this setting is disabled Intel(R) AMT or Standard Manageability can still be re-enabled through the MEBx interface.", bits: 2...2, options: [0: "Disabled", 1: "Enabled"]),
            Setting(name: "MngAppSupported", offset: 344, length: 1, label: "Manageability Application Supported", help: "This setting allows customers to permenantly disable Intel(R) AMT and Standard Manageability mode on the platform.", bits: 2...2, options: [0: "No", 1: "Yes"]),
            Setting(name: "NetServicesSupported", offset: 344, length: 3, label: "Intel(R) ME Network Services Supported", help: "This setting allows customers to enable / disable Intel(R) ME Network Services on the platform.  Note: If this setting is disabled Intel(R) AMT will also be disabled.", bits: 16...16, options: [0: "Yes", 1: "No"]),
            Setting(name: "NfcEnable", offset: 344, length: 4, label: "Enable Near Field Communication", bits: 31...31, options: [0: "No", 1: "Yes"]),
            Setting(name: "OemTag", offset: 524, length: 12, label: "OEM Tag", help: "This is a free form 32bit field that allows the OEM to configure their own unique identifier in the firmware image.", hex: true),
            Setting(name: "PavpSupported", offset: 344, length: 2, label: "PAVP Supported", help: "This setting determines if the Protected Audio Video Path (PAVP) feature will be permanently disabled in the firmware image.", bits: 12...12, options: [0: "No", 1: "Yes"]),
            Setting(name: "ProcEmulation", offset: 488, length: 1, label: "Processor Emulation", help: "This setting determines processor type to be emulated on pre-production silicon.", bits: 0...3, options: [0: "No Emulation", 1: "EMULATE Intel (R) vPro (TM) capable Processor", 2: "EMULATE Intel (R) Core (TM) branded Processor", 3: "EMULATE Intel (R) Celeron (R) branded Processor", 4: "EMULATE Intel (R) Pentium (R) branded Processor", 5: "EMULATE Intel (R) Xeon (R) branded Processor", 6: "EMULATE Intel (R) Xeon (R) Manageability capable Processor"]),
            Setting(name: "ProcMissingDetect", offset: 212, length: 1, label: "Missing Processor Detection Alert", help: "This setting determines if missing processor detection is enabled on Desktop / Workstation platforms.  Note: This feature will only work if the platform has the appropriate glue logic present.", bits: 0...7, options: [0: "Yes", 255: "No"]),
            Setting(name: "PttPwrUpState", offset: 404, length: 4, label: "Intel(R) PTT initial power-up state", help: "This setting determines if Intel(R) PTT is enabled on platform power-up.", bits: 29...29, options: [0: "Disabled", 1: "Enabled"]),
            Setting(name: "TlsSupported", offset: 344, length: 3, label: "Transport Layer Security Supported", help: "This setting allows customers to enable / disable firmware Transport Layer Security support.  Note: If this is disabled TLS will be permanently disabled in the firmware image.", bits: 21...21, options: [0: "No", 1: "Yes"]),
            Setting(name: "TouchEnabled", offset: 344, length: 1, label: "Intel(R) Precise Touch Technology Enabled", help: "This setting determines whether Intel(R) Precise Touch Technology is enabled.", bits: 4...4, options: [0: "Disabled", 1: "Enabled"]),
        ]),
        File(path: "/home/amt/rtfd/amt.wol", alias: "amt.wol", settings: [
            Setting(name: "AmtIdleTimeout", offset: 0, length: 2, label: "Intel(R) AMT Idle Timeout", help: "This setting configures the idle timeout value before Intel(R) AMT enters into an off state.", hex: true),
        ]),
        File(path: "/home/amt/rtfd/WDResetState", alias: "AmtWdTimer", settings: [
            Setting(name: "AmtWdAutoReset", offset: 0, length: 1, label: "Intel(R) AMT Watchdog Automatic Reset Enabled", help: "This setting allows customers to enable the Intel (R) ME firmware to trigger an automatic platform reset if either the MEI or Agent Presence are in a hung state.  Note: This feature only allows one reset at a time when the watchdog expires.  After this feature has triggered a reset it must be re-armed for re-use via management console.", options: [0: "No", 1: "Yes"]),
        ]),
        File(path: "/home/secureboot/bootpolres", alias: "BootGuardPolicyRestrictions", settings: [
            Setting(name: "BtGuardBspInitEnable", offset: 0, length: 1, label: "BSP Initialization", help: "This setting determines BSP behavior when it receives an INIT signal.  When set to 'Enabled', when BSP receives an INIT, BSP will signal an error to the BSS register and enter unrecoverable shutdown.", bits: 2...2, options: [0: "Enabled", 1: "Disabled"]),
            Setting(name: "BtGuardCpuDebugEnable", offset: 0, length: 1, label: "CPU Debugging", help: "When set to Enabled the CPU debugging capability probe mode is enabled.  When this field is set to Disabled it indicates CPU debugging capability probe mode is disabled and locked.", bits: 1...1, options: [0: "Enabled", 1: "Disabled"]),
            Setting(name: "FBGAcmEn", offset: 0, length: 1, label: "Force Boot Guard ACM Enabled", bits: 0...0, options: [0: "false", 1: "true"]),
            Setting(name: "ProtectBiosEnvironment", offset: 0, length: 1, label: "Protect BIOS Environment Enabled", bits: 3...3, options: [0: "false", 1: "true"]),
        ]),
        File(path: "/home/secureboot/kmid", alias: "BootGuardKeyManifestId", settings: [
            Setting(name: "BtGuardKeyManifestId", offset: 0, length: 1, label: "Key Manifest ID", help: "This option is for entering the hash of another public key, used by the ACM to verify the Boot Policy Manifest.", bits: 2...5, hex: true),
        ]),
        File(path: "/home/mca/fpf_commit", alias: "FPFOemRegionCommit", settings: [
            Setting(name: "BtGuardRegionCommit", offset: 0, length: 1, label: "Auto commit OEM Region FPFs", help: "This setting will cause FPFs to automatically be committed on first boot of the firmware on the platform after flashing.", bits: 0...0, options: [0: "No", 1: "Yes"]),
        ]),
        File(path: "/home/secureboot/s3optdis", alias: "BootGuardS3OptimizationDisable", settings: [
            Setting(name: "BtGuardS3Optimize", offset: 0, length: 1, label: "S3 Optimization", help: "This setting overrides Boot Guard S3 optimization.  Note: Used for testing only.", bits: 0...0, options: [0: "Enabled", 1: "Disabled"]),
        ]),
        File(path: "/home/bup/si_features", alias: "KernFixedData", settings: [
            Setting(name: "DbgOverridePreProdSi", offset: 12, length: 4, label: "Debug Override Pre-Production Silicon", help: "Allows the OEM to control FW features to assist with pre-production platform debugging.  This control has no effect if used on production silicon.  Note: Certain options will do not work when the descriptor is locked (See FW Bring-up Guide for setting details.", hex: true),
            Setting(name: "DbgOverrideProdSi", offset: 16, length: 4, label: "Debug Override Production Silicon", help: "Allows the OEM to control FW features to assist with production platform debugging.  Note: Certain options will do not work when the descriptor is locked (See FW Bring-up Guide for setting details.", hex: true),
        ]),
        File(path: "/home/hotham/dbg_dam_req", alias: "Dam", settings: [
            Setting(name: "DelayedAuthMode", offset: 0, length: 1, label: "Delayed Authentication Mode Enabled", help: "This setting enables Delayed Authentication Mode on the platform.", options: [0: "No", 1: "Yes"]),
        ]),
        File(path: "/home/bup/bup_sku/down_sku", alias: "DownSkuBup", settings: [
            Setting(name: "DownSkuConfiguration", offset: 0, length: 1, label: "Down SKU Configuration", options: [0: "No Downgrade", 1: "Downgrade to 1G", 2: "Downgrade to 2G"]),
        ]),
        File(path: "/home/amt/skip_rtfd/ehbc.state", alias: "EhcbState", settings: [
            Setting(name: "EhbcEnable", offset: 0, length: 1, label: "Embedded Host Based Configuration Enabled", help: "This setting allows customers to enable / disable Embedded Host Based Configuration.  Important: EHBC is primarily intended for use in embedded systems as it offers less user privacy/security protection than may be appropriate for business client systems.", options: [0: "No", 1: "Yes"]),
        ]),
        File(path: "/home/secureboot/enfpolicy", alias: "BootGuardErrorHandlingPolicy", settings: [
            Setting(name: "ErrorEnforcement", offset: 0, length: 1, label: "Error Enforcement Policy", hex: true),
        ]),
        File(path: "/home/policy/Bist/auto_config", alias: "BistMeAutoBistConfAndStatus", settings: [
            Setting(name: "FwAutoBist", offset: 0, length: 1, label: "Automatic Built in Self Test", help: "This setting enables the firmware Automatic Built in Self Test which is executed during first platform boot after initial image flashing.", bits: 0...0, options: [0: "Disabled", 1: "Enabled"]),
        ]),
        File(path: "/home/fwupdate/fwuoemid", alias: "OEM_ID_STRING", settings: [
            Setting(name: "FwUpdateOemId", offset: 0, length: 16, label: "Firmware Update OEM ID", help: "This setting allows configuration of an OEM unique ID to ensure that customers can only update their platform with images from the OEM of the platform."),
        ]),
        File(path: "/home/gpio/grp_volt_cfg", alias: "GpioGroupVoltage", settings: [
            Setting(name: "GppBgroupVoltSelect", offset: 0, length: 1, label: "GPIO Group B Voltage", help: "Configures voltage for all PCH GPIO pins in Group B.", bits: 1...1, options: [0: "3.3Volts", 1: "1.8Volts"]),
            Setting(name: "GppCgroupVoltSelect", offset: 0, length: 1, label: "GPIO Group C Voltage", help: "Configures voltage for all PCH GPIO pins in Group C.", bits: 2...2, options: [0: "3.3Volts", 1: "1.8Volts"]),
            Setting(name: "GppDgroupVoltSelect", offset: 0, length: 1, label: "GPIO Group D Voltage", help: "Configures voltage for all PCH GPIO pins in Group D.", bits: 3...3, options: [0: "3.3Volts", 1: "1.8Volts"]),
            Setting(name: "GppEgroupVoltSelect", offset: 0, length: 1, label: "GPIO Group E Voltage", help: "Configures voltage for all PCH GPIO pins in Group E.", bits: 4...4, options: [0: "3.3Volts", 1: "1.8Volts"]),
            Setting(name: "GppFgroupVoltSelect", offset: 0, length: 1, label: "GPIO Group F Voltage", help: "Configures voltage for all PCH GPIO pins in Group F.", bits: 5...5, options: [0: "3.3Volts", 1: "1.8Volts"]),
            Setting(name: "GppGgroupVoltSelect", offset: 0, length: 1, label: "GPIO Group G Voltage", help: "Configures voltage for all PCH GPIO pins in Group G.", bits: 6...6, options: [0: "3.3Volts", 1: "1.8Volts"]),
            Setting(name: "GppHgroupVoltSelect", offset: 0, length: 1, label: "GPIO Group H Voltage", help: "Configures voltage for all PCH GPIO pins in Group H.", bits: 7...7, options: [0: "3.3Volts", 1: "1.8Volts"]),
            Setting(name: "GppJgroupVoltSelect", offset: 0, length: 2, label: "GPIO Group J Voltage", help: "Configures voltage for all PCH GPIO pins in Group J.", bits: 9...9, options: [0: "3.3Volts", 1: "1.8Volts"]),
            Setting(name: "GppKgroupVoltSelect", offset: 0, length: 2, label: "GPIO Group K Voltage", help: "Configures voltage for all PCH GPIO pins in Group K.", bits: 10...10, options: [0: "3.3Volts", 1: "1.8Volts"]),
        ]),
        File(path: "/home/pavp/guc_hash", alias: "GucHash", settings: [
            Setting(name: "GucHash", offset: 0, length: 32),
        ]),
        File(path: "/home/fwupdate/fwuhmrfpo", alias: "HMRFPO_OEM_Enabled", settings: [
            Setting(name: "HmrfpoEnable", offset: 0, length: 1, label: "Intel(R) ME Region Flash Protection Override", help: "This setting enables descriptor unlock of the ME Region when the HMRFPO message is sent to firmware prior to BIOS End of POST.", options: [0: "No", 1: "Yes"]),
        ]),
        File(path: "/home/mca/ish_policy", alias: "IshSigningPol", settings: [
            Setting(name: "IshSigningPolicy", offset: 0, length: 1, label: "Integrated Sensor Hub Signing Policy", help: "This setting determines ISH signing will be checked against the Intel provisioned hash included in the base image or OEM public key hash provisioned on the platform.", options: [0: "Intel", 1: "OEM"]),
        ]),
        File(path: "/home/amt/rtfd/rsb.state", alias: "KvmScreenBlnk", settings: [
            Setting(name: "KvmScreenBlnkEnable", offset: 0, length: 1, label: "Firmware KVM Screen Blanking", help: "This setting enables KVM Screen blanking capabilities in the firmware image.  Note: This feature is dependent on processor level support.", options: [0: "No", 1: "Yes"]),
        ]),
        File(path: "/home/pavp/lspcon_port", alias: "PavpLspcon", settings: [
            Setting(name: "Lspcon4kdisp", offset: 0, length: 1, label: "LSPCON Internal Display Port 1 - LSPCON / 4K", help: "This setting determines which port for LSPCON will be connected to the HDCP 2.2 bridge adapter Display 1.", options: [0: "None", 2: "PortB", 4: "PortC", 8: "PortD"]),
        ]),
        File(path: "/home/mctp/device_ports", alias: "MctpDevicePorts", settings: [
            Setting(name: "MctpDevicePortBmc", offset: 3, length: 1, hex: true),
            Setting(name: "MctpDevicePortEc", offset: 0, length: 1, hex: true),
            Setting(name: "MctpDevicePortIsh", offset: 2, length: 1, hex: true),
            Setting(name: "MctpDevicePortSio", offset: 1, length: 1, hex: true),
        ]),
        File(path: "/home/mctp/smt3_devices", alias: "Smt3Devices", settings: [
            Setting(name: "MctpEcAddress", offset: 0, length: 2, label: "MCTP EC Address", help: "Defines the 8-bits MCTP address and 7-bits SMBus address of the EC on SMLink1 bus. This value is needed if EC is using the MCTP protocol. The SMBus (LS byte) must be from 0x01 to 0x7f (and should not overlap with any SMBus address in PCH Strap 11).  The EID (MS byte) must be outside 0x01 through 0x07.", hex: true),
        ]),
        File(path: "/home/mctp/mctp_espi_en", alias: "MctpOverEspiEnableVar", settings: [
            Setting(name: "MctpEspiEnabled", offset: 0, length: 1, options: [0: "No", 1: "Yes"]),
        ]),
        File(path: "/home/pmt/pmt_en", alias: "MctpOverPcieEnableVar", settings: [
            Setting(name: "MctpPCIeEnable", offset: 0, length: 1, label: "MCTP PCIe Enabled", options: [0: "No", 1: "Yes"]),
        ]),
        File(path: "/home/mctp/eid_db", alias: "MctpStackConfig", settings: [
            Setting(name: "MctpPcieAddress", offset: 5, length: 1, label: "MCTP PCIe Address", hex: true),
            Setting(name: "MctpStackConfig", offset: 2, length: 3),
        ]),
        File(path: "/home/secureboot/bootpoltype", alias: "BootGuardPolicyType", settings: [
            Setting(name: "MeasuredBoot", offset: 0, length: 1, label: "Measured Boot Enabled", bits: 0...0, options: [0: "false", 1: "true"]),
            Setting(name: "VerifiedBoot", offset: 0, length: 1, label: "Verified Boot Enabled", bits: 1...1, options: [0: "false", 1: "true"]),
        ]),
        File(path: "/home/nfc/SlaveAddress", alias: "NfcSlaveAddress", settings: [
            Setting(name: "NfcSmbusAddress", offset: 0, length: 1, label: "NFC SMBus Address", options: [40: "0x28-NXP", 41: "0x29-NXP", 42: "0x2A-NXP", 43: "0x2B-NXP"]),
        ]),
        File(path: "/home/mca/manuf_lock", alias: "EOMManufLock", settings: [
            Setting(name: "NvarPostManUnLckd", offset: 0, length: 1, label: "Post Manufacturing NVAR Configuration Enabled", help: "This setting determines if modifications to Customer configuable NVARs is to be allowed after close of manufacturing.", options: [0: "Yes", 1: "No"]),
        ]),
        File(path: "/home/policy/hci/sysintid1", alias: "sysintid1", settings: [
            Setting(name: "OdmIDIntelServices", offset: 0, length: 4, label: "ODM ID used by Intel(R) Services", help: "This setting is for entering the ODM ID for Intel(R) Services to identify the ODM Board builder.  Note: This ID is either generated by or registered with Intel(R) Services Web servers.", hex: true),
        ]),
        File(path: "/home/secureboot/pubkeyhash", alias: "BootGuardPublicKeyHash", settings: [
            Setting(name: "OemPublicKeyHash", offset: 0, length: 32, label: "OEM Public Key Hash", help: "This option is for entering the raw hash string for Boot Guard or ISH.  This 256-bit field represents the SHA-256 hash of the OEM public key corresponding to the private key used to sign the BIOS-SM for Bootguard or ISH firmware."),
        ]),
        File(path: "/home/amt/skip_rtfd/pki.suffix", alias: "PkiSuffix", settings: [
            Setting(name: "PkiDomainSuffix", offset: 0, length: 256, label: "PKI Domain Name Suffix", help: "This setting allows OEMs to pre-configure the Domain Name Suffix used for PKI provisioning in their firmware image.  Note: For normal out-of- box provisioning functionality this setting should be left empty.", text: true),
        ]),
        File(path: "/home/amt/skip_rtfd/pki.sec.sfx", alias: "PkiSecSfx", settings: [
            Setting(name: "PkiDomainSuffix", offset: 0, length: 256, label: "PKI Domain Name Suffix", help: "This setting allows OEMs to pre-configure the Domain Name Suffix used for PKI provisioning in their firmware image.  Note: For normal out-of- box provisioning functionality this setting should be left empty.", text: true),
        ]),
        File(path: "/home/policy/skumgr/ptt_owr", alias: "PttOwr", settings: [
            Setting(name: "PttOvrEnforcedC422", offset: 0, length: 1, label: "C422 Intel(R) PTT Override Enforcement", help: "This allows Intel(R) PTT on the Intel(R) C422 PCH.  This is only applicable to the Intel(R) C422 PCH.  Additional parameters must be configured for Intel(R) PTT to be enabled.", options: [0: "No", 1: "Yes"]),
        ]),
        File(path: "/home/mca/drtcc", alias: "DisRtcCheck", settings: [
            Setting(name: "PttRtcClearDetect", offset: 0, length: 1, label: "Intel(R) PTT RTC Clear Detection", help: "This setting determines how the Intel(R) PTT will behave when RTC (CMOS) clear is triggered on the platform.  When Disabled Intel(R) PTT will bypass normal RTC clear behavior. Note: For designs where there is no Physical Coin Cell Battery, for backing up data stored in the RTC well, this setting should be set to 'Disabled'.", options: [0: "Enabled", 1: "Disabled"]),
        ]),
        File(path: "/home/policy/skumgr/ftpm_enable", alias: "fTPMEnable", settings: [
            Setting(name: "PttSupportedHw", offset: 0, length: 1, label: "Intel(R) PTT Supported [FPF]", help: "This setting will permanently disable Intel(R) PTT through platform FPFs.  Caution: Using this option will permanently disable Intel(R) PTT on the platform hardware.", options: [0: "No", 1: "Yes"]),
        ]),
        File(path: "/home/amt/rtfd/PrivacyLvl", alias: "PrivacyLevel", settings: [
            Setting(name: "RedirectionPrivSecLevel", offset: 0, length: 1, label: "Redirection Privacy / Security Level", help: "This setting allows customers to configure the Privacy and Security level for redirection operations.  Default enables all redirection ports (User consent is configurable).  Enhanced enables all redirection ports (User consent is required and cannot be disabled).  Extreme disables all redirection capabilities.", options: [1: "Default", 2: "Enhanced", 3: "Extreme"]),
        ]),
        File(path: "/home/policy/hci/sysintid3", alias: "sysintid3", settings: [
            Setting(name: "ReservedIdIntelServices", offset: 0, length: 4, label: "Reserved ID used by Intel(R) Services", help: "This setting is for entering the Reserved ID for Intel(R) Services currently not used.", hex: true),
        ]),
        File(path: "/home/secureboot/selftestres", alias: "BootGuardSelfTestReset", settings: [
            Setting(name: "SelfTestReset", offset: 0, length: 1, bits: 0...0, options: [0: "false", 1: "true"]),
        ]),
        File(path: "/home/amt/skip_rtfd/sfx.isSecure", alias: "SfxIsSecure", settings: [
            Setting(name: "SuffixIsSecure", offset: 0, length: 1, options: [0: "false", 1: "true"]),
        ]),
        File(path: "/home/policy/hci/sysintid2", alias: "sysintid2", settings: [
            Setting(name: "SysIntIdIntelServices", offset: 0, length: 4, label: "System Integrator ID used by Intel(R) Services", help: "This setting is for entering the System Integrator ID for Intel(R) Services to identify the System Integrator.  Note: This ID is either generated by or registered with Intel(R) Services Web servers.", hex: true),
        ]),
        File(path: "/home/secureboot/txten", alias: "TxtEnabled", settings: [
            Setting(name: "TxtSupported", offset: 0, length: 1, label: "TXT Supported", help: "This setting determines if Intel(R) TXT is enabled on the platform.", options: [0: "No", 1: "Yes"]),
        ]),
        File(path: "/home/hotham/utok_keyhash", alias: "OemUtokKeyHash", settings: [
            Setting(name: "UnlockTokenKeyHash", offset: 0, length: 8, label: "Unlock Token Key Hash", help: "This allows the OEM to input the hash of the public key needed to verify an OEM Unlock Token. The hash is SHA256 (32-bytes) but will be truncated to the lower 8-bytes."),
        ]),
        ])
}
