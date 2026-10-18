// The CSME 15 map of the ME configuration — emitted by
// `Skills/me-eom-structures/scripts/fit_map.py` from Flash Image Tool 15.0's
// own layout documents (the tgp_h platform of ME 15).
//
// The family is the tool's own name for the platform half: `_lp`/`_p` is
// the mobile one and `_h`/`_s` the desktop one, and a dump is read with
// the one its descriptor's strap section length names
// (`MEConfigurationMap.forME(major:family:)`).
// Offsets, bits, the tool's own name for each setting (`label`), its option
// labels and the file paths are FIT's, copied out of its
// `ProcessNvar` bindings and value dictionaries; nothing here is read out of a
// dump. FIT 15.0 marks no setting `Auto` — it has no such attribute — so no
// setting here carries that mark.
//
// A generation's map lives in a file of its own: see `MEConfigurationMap.swift`
// for what a map is and why each generation has its own.

import Foundation

extension MEConfigurationMap {
    /// The ME 15 configuration, as FIT 15.0 lays it out. The files stand in the
    /// order a bench reads them, and the rest in the tool's own order.
    public static let csme15Desktop = MEConfigurationMap(
        name: "CSME 15 (Flash Image Tool 15.0, tgp_h)",
        files: [
        File(path: "/home/mca/eom_config", alias: "EOM_Config", settings: [
            Setting(name: "EomFirstBootEnabled", offset: 0, length: 1, label: "EOM on First Boot Enabled", help: "This setting detremines if End of Manufacturing will be triggered on first boot of the platform after flashing.\nNote: When this setting is enabled Intel(R) CSME will enter End of Manufacturing regardless of the descriptor settings.", bits: 0...0, options: [0: "No", 1: "Yes"]),
            Setting(name: "FlexibleEomSettings", offset: 0, length: 1, label: "Flexible EOM setting options", help: "This setting deteremines which settings will be automatically commited during End of Manufacturing flows.\nNote: The FPFs, RPMB / RPMC and set manufacturing mode settings are mandatory and cannot be overridden revenue parts. Simulation can be done on non-revenue part with the Hardware binding set to disabled.", bits: 1...2, options: [0: "Lock Descriptor and OEM Configs", 1: "Lock OEM Configs Only", 2: "Lock Descriptor Only", 3: "Do not lock Descriptor and OEM Configs"]),
        ]),
        File(path: "/home/mca/eom", alias: "EOM", settings: [
            Setting(name: "EndOfManufacturing", offset: 0, length: 1, label: "End of Manufacturing Enable", help: "EOM should be set when the image is built in production mode. This will trigger close manuf flows in FW. This setting is not configurable in SPI mode.", options: [0: "No", 1: "Yes"]),
            Setting(name: "EomFirstBootEnabled", offset: 0, length: 1, label: "EOM on First Boot Enabled", help: "This setting detremines if End of Manufacturing will be triggered on first boot of the platform after flashing.\nNote: When this setting is enabled Intel(R) CSME will enter End of Manufacturing regardless of the descriptor settings.", options: [0: "No", 1: "Yes"]),
        ]),
        File(path: "/home/iunit/iunit_oem_cfg", alias: "IUnitOemCfg", settings: [
            Setting(name: "FWSecureMode", offset: 17, length: 1, label: "FW Secure Mode", help: "If enabled, access blockers in IS and PS are enabled, and FW is read from IMR. Must be enabled for FW authentication flow and execution of authenticated FW.", options: [0: "Disabled", 1: "Enabled"]),
            Setting(name: "SecureTouch", offset: 18, length: 1, label: "Secure Touch", help: "When set, CAMERA_MASK register bits per CSI port are used to mask the data of cameras. When cleared, camera data is not masked. ", options: [0: "Disabled", 1: "Enabled"]),
            Setting(name: "SecureTouchCameraMask", offset: 0, length: 4, label: "Secure Touch and Camera Mask", help: "Camera mask bits per CSI port. When SECURE_TOUCH is set each set bit masks a CSI port for secure touch. When SECURE_TOUCH is cleared this register has no impact on the CSI ports.", hex: true),
        ]),
        File(path: "/home/policy/cfgmgr/cfg_rules", alias: "ME_CONF_WRK", settings: [
            Setting(name: "AmtSupported", offset: 344, length: 1, label: "Intel(R) AMT Supported", help: "This setting allows customers to disable Intel(R) AMT on the platform and force the platform into Standard Manageability mode.  Note: This setting is only applies to Desktop and Workstation platforms.", bits: 0...0, options: [0: "No", 1: "Yes"]),
            Setting(name: "CryptoHwSupport", offset: 344, length: 2, label: "Crypto HW Support", help: "This setting can be used to disable crypto funtionality. This settings disables all crypto dependent features.", bits: 13...13, options: [0: "Yes", 1: "No"]),
            Setting(name: "EnableTDS", offset: 344, length: 4, label: "Enable TDS Capabilities", help: "This setting enables Intel(R) Trusted Device Setup on the platform", bits: 25...25, options: [0: "No", 1: "Yes"]),
            Setting(name: "FID_INT_TOUCH", offset: 344, length: 1, bits: 4...4, options: [0: "No", 1: "Yes"]),
            Setting(name: "FID_ISH", offset: 344, length: 2, bits: 10...10, options: [0: "No", 1: "Yes"]),
            Setting(name: "FID_MEDAL", offset: 344, length: 3, bits: 20...20, options: [0: "Disabled", 1: "Enabled"]),
            Setting(name: "FID_PAV", offset: 344, length: 2, bits: 12...12, options: [0: "No", 1: "Yes"]),
            Setting(name: "FwUpdEnable", offset: 92, length: 1, label: "Hide MEBx Firmware Update Control", disabledBy: Condition(name: "HideMEBxFwUpdCtrl", value: 1), bits: 0...0, options: [0: "No", 1: "Yes"]),
            Setting(name: "HideMEBxFwUpdCtrl", offset: 88, length: 1, label: "Hide MEBx Firmware Update Control", help: "This setting allows customers to hide the Firmware Update option in the MEBx interface.", bits: 1...1, options: [0: "No", 1: "Yes"]),
            Setting(name: "IshPowerUpState", offset: 404, length: 2, label: "Integrated Sensor Hub Initial Power State", help: "This setting allows customers to determine the power up state for ISH.", disabledBy: Condition(name: "IshSupported", value: 1), bits: 10...10, options: [0: "Disabled", 1: "Enabled"]),
            Setting(name: "KvmSupported", offset: 344, length: 3, label: "KVM Redirection Supported", help: "This setting allows customers to enable / disable the KVM Redirection capabilities of the firmware.  Note: If this setting have been set to disabled it cannot be re-enabled once the descriptor has been locked.", bits: 18...18, options: [0: "No", 1: "Yes"]),
            Setting(name: "MEDynAppLoad", offset: 344, length: 3, label: "Firmware Dynamic Application Loader", help: "This setting enables the Dynamic Application Loader capability of the Intel(R) ME Firmware.", bits: 20...20, options: [0: "Disabled", 1: "Enabled"]),
            Setting(name: "MELanPowerWell", offset: 188, length: 1, label: "LAN Power Well", help: "This setting allows the customer to configure the powerwell that will be used by Intel(R) Integrated LAN.  Note: Recommended setting is SLP_LAN#.", bits: 0...2, options: [0: "Core Well", 1: "SUS Well", 2: "ME Well", 3: "SLP_LAN#"]),
            Setting(name: "MEWlanPowerWell", offset: 200, length: 1, label: "WLAN Power Well", bits: 0...7, options: [128: "Disabled", 129: "Core Well || SLP_S3#", 130: "Primary Well || SLP_SUS#", 131: "ME Well || SLP_A#", 134: "SLP_WLAN#"]),
            Setting(name: "MeClinkEnable", offset: 464, length: 1, label: "Intel(R) ME CLINK Signal Enabled", help: "This setting allows customers to enable / disable the Wireless LAN CLINK signal through Intel(R) ME firmware.  Note: For using Intel(R) vPro Wireless solutions this should be set to Yes.", bits: 0...0, options: [0: "No", 1: "Yes"]),
            Setting(name: "MngAppPowerUpState", offset: 404, length: 1, label: "Manageability Application initial power-up state", help: "This setting allows customers to determine the power up state for Intel(R) AMT or Standard Manageability.  Note: If this setting is disabled Intel(R) AMT or Standard Manageability can still be re-enabled through the MEBx interface.", bits: 2...2, options: [0: "Disabled", 1: "Enabled"]),
            Setting(name: "MngAppSupported", offset: 344, length: 1, label: "Manageability Application Supported", help: "This setting allows customers to permenantly disable Intel(R) AMT and Standard Manageability mode on the platform.", bits: 2...2, options: [0: "No", 1: "Yes"]),
            Setting(name: "NetServicesSupported", offset: 344, length: 3, label: "Intel(R) ME Network Services Supported", help: "This setting allows customers to enable / disable Intel(R) ME Network Services on the platform.  Note: If this setting is disabled Intel(R) AMT will also be disabled.", bits: 16...16, options: [0: "Yes", 1: "No"]),
            Setting(name: "OemTag", offset: 524, length: 12, label: "OEM Tag", hex: true),
            Setting(name: "ProcEmulation", offset: 488, length: 1, label: "Processor Emulation", bits: 0...3, options: [0: "No Emulation", 1: "EMULATE Intel (R) vPro (TM) capable Processor", 2: "EMULATE Intel (R) Core (TM) branded Processor", 3: "EMULATE Intel (R) Celeron (R) branded Processor", 4: "EMULATE Intel (R) Pentium (R) branded Processor", 5: "EMULATE Intel (R) Xeon E (R) branded Processor", 6: "EMULATE Intel (R) Xeon W (R) Manageability capable Processor"]),
            Setting(name: "ProcMissingDetect", offset: 212, length: 1, label: "Missing Processor Detection Alert", help: "This setting determines if missing processor detection is enabled on Desktop / Workstation platforms.  Note: This feature will only work if the platform has the appropriate glue logic present.", bits: 0...7, options: [0: "Yes", 255: "No"]),
            Setting(name: "PttPwrUpState", offset: 404, length: 4, label: "Intel(R) PTT initial power-up state", disabledBy: Condition(name: "PttSupported", value: 0), bits: 29...29, options: [0: "Disabled", 1: "Enabled"]),
            Setting(name: "PttSupported", offset: 344, length: 4, label: "Intel(R) PTT Supported", help: "This setting permanently disables Intel(R) PTT in the firmware image.", bits: 29...29, options: [0: "No", 1: "Yes"]),
            Setting(name: "TlsCryptoSupport", offset: 344, length: 3, label: "Transport Layer Security crypto support", help: "This setting allows customers to enable/ disable FW Transport Layer Security algorithm crypto fuse.  Note: if this is disabled, TLS is still operational but without crypto.", bits: 21...21, options: [0: "No", 1: "Yes"]),
        ]),
        File(path: "/home/amt/rtfd/amt.wol", alias: "amt.wol", settings: [
            Setting(name: "AmtIdleTimeout", offset: 0, length: 2, label: "Intel(R) AMT Idle Timeout", help: "This setting configures the idle timeout value before Intel(R) AMT enters into an off state.", hex: true),
        ]),
        File(path: "/home/amt/rtfd/WDResetState", alias: "AmtWdTimer", settings: [
            Setting(name: "AmtWdAutoReset", offset: 0, length: 1, label: "Intel(R) AMT Watchdog Automatic Reset Enabled", help: "This setting allows customers to enable the Intel (R) ME firmware to trigger an automatic platform reset if either the MEI or Agent Presence are in a hung state.  Note: This feature only allows one reset at a time when the watchdog expires.  After this feature has triggered a reset it must be re-armed for re-use via management console.", options: [0: "No", 1: "Yes"]),
        ]),
        File(path: "/home/secureboot/brm_cfg", alias: "BrmEn", settings: [
            Setting(name: "BiosRedAssistance", offset: 0, length: 1, label: "BIOS Redundancy Assistance", help: "In case of BIOS boot failure, CSME will configure the platform to boot with backup BIOS using Top Swap. Note: This option is only available when Boot Guard is enabled.", options: [0: "Disabled", 1: "Enabled"]),
        ]),
        File(path: "/home/icc/profsel", alias: "IccProfileSelect", settings: [
            Setting(name: "BootProfile", offset: 0, length: 1, label: "Boot Profile", help: "Profile applied during each boot."),
        ]),
        File(path: "/home/bup/si_features", alias: "KernFixedData", settings: [
            Setting(name: "DbgOverridePreProdSi", offset: 12, length: 4, label: "Debug Override Pre-Production Silicon", help: "Allows the OEM to control FW features to assist with pre-production platform debugging.  This control has no effect if used on production silicon.  Note: Certain options will do not work when the descriptor is locked (See FW Bring-up Guide for setting details).", hex: true),
            Setting(name: "DbgOverrideProdSi", offset: 16, length: 4, label: "Debug Override Production Silicon", help: "Allows the OEM to control FW features to assist with production platform debugging.  Note: Certain options will do not work when the descriptor is locked (See FW Bring-up Guide for setting details).", hex: true),
        ]),
        File(path: "/home/hotham/dbg_dam_req", alias: "Dam", settings: [
            Setting(name: "DelayedAuthMode", offset: 0, length: 1, label: "Delayed Authentication Mode Enabled", help: "This setting enables Delayed Authentication Mode on the platform.", options: [0: "No", 1: "Yes"]),
        ]),
        File(path: "/home/amt/skip_rtfd/ehbc.state", alias: "EhcbState", settings: [
            Setting(name: "EhbcEnable", offset: 0, length: 1, label: "Embedded Host Based Configuration Enabled", help: "This setting allows customers to enable / disable Embedded Host Based Configuration. EHBC is primarily intended for use in embedded systems, please leave this setting disabled for business client systems.", options: [0: "No", 1: "Yes"]),
        ]),
        File(path: "/home/icc/header", alias: "IccProfileCount", settings: [
            Setting(name: "FailsafeBootProfile", offset: 1, length: 1, label: "Failsafe Boot Profile", help: "Boot profile used when system instability is detected."),
            Setting(name: "ProfileChangeable", offset: 3, length: 1, label: "Profile Changeable", help: "True = Allows user to change boot profile via BIOS menu or 3rd party application False = Prevents user from changing boot profile via BIOS or 3rd party application.  Note: When false, Failsafe Boot Profile must be the same as Boot Profile.", options: [0: "false", 1: "true"]),
        ]),
        File(path: "/home/policy/Bist/auto_config", alias: "BistMeAutoBistConfAndStatus", settings: [
            Setting(name: "FwAutoBist", offset: 0, length: 1, label: "Automatic Built in Self Test", help: "This setting enables the firmware Automatic Built in Self Test which is executed during first platform boot after initial image flashing.", bits: 0...0, options: [0: "Disabled", 1: "Enabled"]),
        ]),
        File(path: "/home/fwupdate/fwuoemid", alias: "OEM_ID_STRING", settings: [
            Setting(name: "FwUpdateOemId", offset: 0, length: 16, label: "Firmware Update OEM ID", help: "This setting allows configuration of an OEM unique ID to ensure that customers can only update their platform with images from the OEM of the platform."),
        ]),
        File(path: "/home/pavp/guc_hash", alias: "GucHash", settings: [
            Setting(name: "GucHash", offset: 0, length: 32, label: "GuC Encryption Key", help: "This option is for entering the raw hash 256 bit string for the Graphics uController."),
        ]),
        File(path: "/home/policy/hmrfpo_state", alias: "HMRFPO_OEM_Enabled", settings: [
            Setting(name: "HmrfpoEnable", offset: 0, length: 1, label: "Intel(R) ME Region Flash Protection Override", help: "This setting enables descriptor unlock of the ME Region when the HMRFPO message is sent to firmware prior to BIOS End of POST.", options: [0: "No", 1: "Yes"]),
        ]),
        File(path: "/home/bup/bup_sku/hw_binding", alias: "HwBinding", settings: [
            Setting(name: "HwBindingEn", offset: 0, length: 1, label: "Hardware Binding Enabled", help: "This setting configures the FPF Hardware and RPMC / RPMB binding behavior for the platform image.   \n\n                                                                                                                                             If this setting is enabled FPF Hardware and RPMC / RPMB binding behavior will occur when platform close manufacturing flow is executed with Intel® FPT. \n\n                                                                                                                                             If this setting is disabled FPF Hardware and RPMC / RPMB binding behavior will not take place when close manufacturing flow is executed.\n\n                                                                                                                                             Note: For Revenue parts this setting will be ignored and FPF Hardware and RPMC / RPMB binding behavior will take place when close manufacturing flow is executed.", options: [0: "Disabled", 1: "Enabled"]),
        ]),
        File(path: "/home/amt/rtfd/rsb.state", alias: "KvmScreenBlnk", settings: [
            Setting(name: "KvmScreenBlnkEnable", offset: 0, length: 1, label: "Firmware KVM Screen Blanking", help: "This setting enables KVM Screen blanking capabilities in the firmware image.  Note: This feature is dependent on processor level support.", options: [0: "No", 1: "Yes"]),
        ]),
        File(path: "/home/mctp/device_ports", alias: "MctpDevicePorts", settings: [
            Setting(name: "MctpDevicePortBmc", offset: 3, length: 1, hex: true),
            Setting(name: "MctpDevicePortEc", offset: 0, length: 1, hex: true),
            Setting(name: "MctpDevicePortIsh", offset: 2, length: 1, hex: true),
            Setting(name: "MctpDevicePortSio", offset: 1, length: 1, hex: true),
        ]),
        File(path: "/home/mctp/smt3_devices", alias: "Smt3Devices", settings: [
            Setting(name: "MctpEcAddress", offset: 4, length: 2, label: "MCTP EC Address", help: "Defines the 8-bits MCTP address and 7-bits SMBus address of the EC on SMLink1 bus. This value is needed if EC is using the MCTP protocol. The SMBus (LS byte) must be from 0x01 to 0x7f (and should not overlap with any SMBus address in PCH Strap 11).  The EID (MS byte) must be outside 0x01 through 0x07.", hex: true),
        ]),
        File(path: "/home/mctp/eid_db", alias: "MctpStackConfig", settings: [
            Setting(name: "MctpPcieAddress", offset: 5, length: 1, label: "MCTP PCIe Address", hex: true),
            Setting(name: "MctpStackConfig", offset: 2, length: 3, label: "MCTP Stack Configuration", help: "Defines the ME's 8-bits MCTP Endpoint IDs for each SMBus physical interface (SMBus, SMLink0 and SMLink1). These values are needed for FW to communicate with MCTP end points. For each of these 3 bytes, a value of 0x00 means not used, and values 0xFF or 0x01 - 0x07 or 0x20 - 0x2F are not allowed."),
        ]),
        File(path: "/home/policy/msrmnt_sup", alias: "MeasurmentSupport", settings: [
            Setting(name: "MeMeasuredBootState", offset: 0, length: 1, label: "Intel(R) ME Measured Boot State", help: "When measured boot is enabled firmware will use additional extended registers for all IUPs and Key Manifests that firmware loads and verifies from flash. \nNote: When measured boot is enabled any IUPs or firmware updates will require a global reset", options: [0: "Disabled", 1: "Enabled"]),
        ]),
        File(path: "/home/rbe/MANAGEABILITY_HW_DIS", alias: "MngHwDis", settings: [
            Setting(name: "MngHwStatusEfs", offset: 0, length: 1, label: "Manageability Application Hardware Status EFS", help: "This setting will disable Intel(R) AMT hardware.", options: [0: "Yes", 1: "No"]),
        ]),
        File(path: "/home/mca/manuf_lock", alias: "PostManuf", settings: [
            Setting(name: "NvarPostManUnLckd", offset: 0, length: 1, label: "Post Manufacturing NVAR Configuration Enabled", help: "This setting determines if modifications to Customer configuable NVARs is to be allowed after close of manufacturing.", options: [0: "Yes", 1: "No"]),
        ]),
        File(path: "/home/amt/skip_rtfd/pki.suffix", alias: "PkiSuffix", settings: [
            Setting(name: "PkiDomainSuffix", offset: 0, length: 256, label: "PKI Domain Name Suffix", help: "This setting allows OEMs to pre-configure the Domain Name Suffix used for PKI provisioning in their firmware image.  Note: For normal out-of- box provisioning functionality this setting should be left empty.", text: true),
        ]),
        File(path: "/home/amt/skip_rtfd/pki.sec.sfx", alias: "PkiSecSfx", settings: [
            Setting(name: "PkiDomainSuffix", offset: 0, length: 256, label: "PKI Domain Name Suffix", help: "This setting allows OEMs to pre-configure the Domain Name Suffix used for PKI provisioning in their firmware image.  Note: For normal out-of- box provisioning functionality this setting should be left empty.", text: true),
        ]),
        File(path: "/home/rbe/PreventSMTADisable", alias: "PreventSMTADisable", settings: [
            Setting(name: "PreventSMTADisable", offset: 0, length: 1),
        ]),
        File(path: "/home/amt/rtfd/PrivacyLvl", alias: "PrivacyLevel", settings: [
            Setting(name: "RedirectionPrivSecLevel", offset: 0, length: 1, label: "Redirection Privacy / Security Level", help: "This setting allows customers to configure the Privacy and Security level for redirection operations.  Default enables all redirection ports (User consent is configurable).  Enhanced enables all redirection ports (User consent is required and cannot be disabled).  Extreme disables all redirection capabilities.", options: [1: "Default", 2: "Enhanced", 3: "Extreme"]),
        ]),
        File(path: "/home/ptt/ptt_smx_disable", alias: "PttSmxSupport", settings: [
            Setting(name: "Rsa1KSupport", offset: 0, length: 1, label: "Rsa 1K State", options: [0: "Enabled", 1: "Disabled"]),
            Setting(name: "SmxSupport", offset: 0, length: 1, label: "SMx State", options: [0: "Enabled", 1: "Disabled"]),
        ]),
        File(path: "/home/amt/skip_rtfd/sfx.isSecure", alias: "SfxIsSecure", settings: [
            Setting(name: "SuffixIsSecure", offset: 0, length: 1, options: [0: "false", 1: "true"]),
        ]),
        File(path: "/home/tcss/tcss_ctrl", alias: "TcssControl", settings: [
            Setting(name: "TcssAuthenticateEn", offset: 0, length: 1, options: [0: "Yes", 1: "No"]),
        ]),
        File(path: "/home/fwupdate/fwutcss", alias: "TCSS_PartialUpdate", settings: [
            Setting(name: "TcssPartialUpdateEn", offset: 0, length: 1, label: "Tcss - Partial Update Enabled", help: "This setting enables partial update for TCSS partitions", options: [0: "Disabled", 1: "Enabled"]),
        ]),
        File(path: "/home/amt/skip_rtfd/ncsi", alias: "AmtNetworkConfiguration", settings: [
            Setting(name: "TypeCPort1RetimerI2cAddress", offset: 1, length: 1, label: "Type-C Port1 Re-Timer I2C Address", help: "This setting configures the Intel(R) SMBus I2C Address.\nNote: Input needs to be in HEX format(OEM specific), e.g. 0x12", disabledBy: Condition(name: "vproDockEnabled", value: 0), hex: true),
            Setting(name: "TypeCPort2RetimerI2cAddress", offset: 2, length: 1, label: "Type-C Port2 Re-Timer I2C Address", help: "This setting configures the Intel(R) SMBus I2C Address.\nNote: Input needs to be in HEX format(OEM specific), e.g. 0x12", hex: true),
            Setting(name: "TypeCPort3RetimerI2cAddress", offset: 3, length: 1, label: "Type-C Port3 Re-Timer I2C Address", help: "This setting configures the Intel(R) SMBus I2C Address.\nNote: Input needs to be in HEX format(OEM specific), e.g. 0x12", hex: true),
            Setting(name: "TypeCPort4RetimerI2cAddress", offset: 4, length: 1, label: "Type-C Port4 Re-Timer I2C Address", help: "This setting configures the Intel(R) SMBus I2C Address.\nNote: Input needs to be in HEX format(OEM specific), e.g. 0x12", hex: true),
            Setting(name: "TypeCPortRetimerMCTPSmbusAddr", offset: 6, length: 1, label: "vPro 2.5G Wired LAN on dock slave SMBUS Address", help: "vPro 2.5G Wired LAN slave address\nNote: Input needs to be in HEX format(OEM specific), e.g. 0x12", disabledBy: Condition(name: "vproDockEnabled", value: 0), hex: true),
            Setting(name: "vproDockEnabled", offset: 0, length: 1, label: "vPro Dock Enabled", help: "YES = Enables communication with, vPro supporting NIC, via TBT dock\nNO = No support for vPro dock solution", bits: 1...1, options: [0: "No", 1: "Yes"]),
            Setting(name: "vproNicEnabled", offset: 0, length: 1, label: "Platform vPro 2.5G Wired LAN Enabled", help: "YES = Discrete NIC enabled in platform\nNO = Integrated GBE LAN enabled in platform", bits: 0...0, options: [0: "No", 1: "Yes"]),
            Setting(name: "vproNicSMBusAddress", offset: 5, length: 1, label: "Platform vPro 2.5G Wired LAN SMBUS slave address", help: "Platform discrete NIC slave address\nNote: Input needs to be in HEX format(OEM specific), e.g. 0x12", disabledBy: Condition(name: "vproNicEnabled", value: 0), hex: true),
        ]),
        File(path: "/home/mctp/smt2_devices", alias: "Smt2Devices", settings: [
            Setting(name: "TypeCPortRetimerMCTPSmbusAddr", offset: 2, length: 1, label: "vPro 2.5G Wired LAN on dock slave SMBUS Address", help: "vPro 2.5G Wired LAN slave address\nNote: Input needs to be in HEX format(OEM specific), e.g. 0x12", disabledBy: Condition(name: "vproDockEnabled", value: 0), hex: true),
            Setting(name: "vproNicSMBusAddress", offset: 0, length: 1, label: "Platform vPro 2.5G Wired LAN SMBUS slave address", help: "Platform discrete NIC slave address\nNote: Input needs to be in HEX format(OEM specific), e.g. 0x12", disabledBy: Condition(name: "vproNicEnabled", value: 0), hex: true),
        ]),
        File(path: "/home/upid/platform_id_support", alias: "UpidPlatformIdSupport", settings: [
            Setting(name: "UniquePlatformIdSupportedFeature", offset: 0, length: 1, label: "UPID Supported", help: "This setting allows OEM to create their own unique platform identifier. If this setting is enabled, the below OEM ID must be set.", options: [0: "No", 1: "Yes"]),
        ]),
        ])
}
