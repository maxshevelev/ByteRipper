// The CSME 18 map of the ME configuration — emitted by
// `Skills/me-eom-structures/scripts/mfit18_map.py` from Flash Image Tool
// 18.1's rewritten database: `<nvar>` places and `<ui_item>` words,
// nothing here is read out of a dump. See `MEConfigurationMap.swift`
// for what a map is and why each generation has its own.

import Foundation

extension MEConfigurationMap {
    /// The ME 18 configuration, as MFIT 18 lays it out.
    public static let csme18 = MEConfigurationMap(
        name: "CSME 18 (Flash Image Tool 18.1)",
        files: [
        File(path: "/home/mca/eom_config", alias: "eom_config", settings: [
            Setting(name: "EomFirstBootEnabled_eom_config", offset: 0, length: 2, label: "EOM on First Boot Enabled", help: "This setting determines if End of Manufacturing will be triggered on first boot of the platform after flashing.\nNote: When this setting is enabled Intel(R) CSME will enter End of Manufacturing regardless of the descriptor settings.", bits: 0...0, options: [0: "No", 1: "Yes"]),
            Setting(name: "FlexibleEomSettings", offset: 0, length: 2, label: "Flexible EOM setting options", help: "This setting deteremines which settings will be automatically commited during End of Manufacturing flows.\nNote: The FPFs, RPMB / RPMC and set manufacturing mode settings are mandatory and cannot be overridden revenue parts. Simulation can be done on non-revenue part with the Hardware binding set to disabled.", bits: 1...2, options: [0: "Lock Descriptor and OEM Configs", 1: "Lock OEM Configs Only", 2: "Lock Descriptor Only", 3: "Do not lock Descriptor and OEM Configs"]),
        ]),
        File(path: "/home/mca/eom", alias: "MCA_EOM", settings: [
            Setting(name: "EomFirstBootEnabled_eom", offset: 0, length: 1, label: "EOM on First Boot Enabled", help: "This setting determines if End of Manufacturing will be triggered on first boot of the platform after flashing.\nNote: When this setting is enabled Intel(R) CSME will enter End of Manufacturing regardless of the descriptor settings.", options: [0: "No", 1: "Yes"]),
        ]),
        File(path: "/home/smbus/smlink_bus", alias: "SMLINK_BUS_SELECTION", settings: [
            Setting(name: "MctpEcAddress", offset: 1, length: 2, label: "MCTP EC Address", help: "Defines the 8-bits MCTP address and 7-bits SMBus address of the EC on SMLink0 or SMLink0b or eSPI bus. This value is needed if EC is using the MCTP protocol. The SMBus (LS byte) must be from 0x01 to 0x7f (and should not overlap with any SMBus address in PCH Strap 11).  The EID (MS byte) must be outside 0x01 through 0x07.", hex: true),
        ]),
        File(path: "/home/iunit/iunit_oem_cfg", alias: "iunit_oem_cfg", settings: [
            Setting(name: "FWSecureMode", offset: 0, length: 1, label: "FW Secure Mode", help: "Debug feature for pre-production platforms only, can be edited only via the config XML. If enabled, access blockers in IS and PS are enabled, and FW is read from IMR. Must be enabled for FW authentication flow and execution of authenticated FW.", options: [0: "Disabled", 1: "Enabled"]),
        ]),
        File(path: "/home/iunit/iunit_privacy_mode", alias: "IUNIT_PRIVACY_MODE", settings: [
            Setting(name: "PrivacyFeatureControlDisabled", offset: 0, length: 1, label: "Camera privacy feature control disabled", help: "This NVAR enables/disables the camera privacy. Enabling this NVAR means that the Camera privacy GPIO Pin value is used to mask/unmask all cameras' data from being used"),
        ]),
        File(path: "/home/policy/cfgmgr/cfg_rules", alias: "POLICY_CFG_RULES", settings: [
            Setting(name: "HideMEBxFwUpdCtrl", offset: 88, length: 1, label: "Hide MEBx Firmware Update Control", help: "This setting allows customers to hide the Firmware Update option in the MEBx interface.", bits: 1...1, options: [0: "No", 1: "Yes"]),
            Setting(name: "MELanPowerWell", offset: 188, length: 4, label: "LAN Power Well", help: "This setting allows the customer to configure the powerwell that will be used by Intel(R) Integrated LAN.  Note: Recommended setting is SLP_LAN#.", bits: 0...2, options: [0: "Core Well", 1: "SUS Well", 2: "ME Well", 3: "SLP_LAN#"]),
            Setting(name: "MEWlanPowerWell", offset: 200, length: 4, label: "WLAN Power Well", help: "This setting allow the customer to configure the powerwell that will be used by Intel(R) wireless lan. note: recommended setting is slp_wlan#", bits: 0...7, options: [128: "Disabled", 129: "Core Well || SLP_S3#", 130: "Primary Well || SLP_SUS#", 131: "SLP_A#", 134: "SLP_WLAN#"]),
            Setting(name: "OCRSupported", offset: 344, length: 4, label: "Intel(R) One Click Recovery supported", help: "This setting enables the One Click Recovery capability", bits: 3...3, options: [0: "No", 1: "Yes"]),
            Setting(name: "RPESupported", offset: 344, length: 4, label: "Intel(R) Remote Platform Erase supported", help: "This setting enables the Remote Platform Erase capability", bits: 4...4, options: [0: "No", 1: "Yes"]),
            Setting(name: "PRTCM", offset: 344, length: 4, bits: 15...15, options: [0: "Disabled", 1: "Enabled"]),
            Setting(name: "vproDockEnabled", offset: 344, length: 4, label: "vPro Over Thunderbolt Dock State", help: "YES = Enables communication with, vPro supporting NIC, via TBT dock\nNO = No support for vPro dock solution", bits: 27...27, options: [0: "No", 1: "Yes"]),
            Setting(name: "FidoSupported", offset: 404, length: 4, label: "Fast identity online device onboarding state", help: "This setting allows customers to enable / disable the Fast identity online device onboarding (FIDO) state of the firmware.", bits: 31...31, options: [0: "Disabled", 1: "Enabled"]),
            Setting(name: "MeClinkEnable", offset: 464, length: 4, label: "Intel(R) ME CLINK Signal Enabled", help: "This setting allows customers to enable / disable the Wireless LAN CLINK signal through Intel(R) ME firmware.  Note: For using Intel(R) vPro Wireless solutions this should be set to Yes.", bits: 0...0, options: [0: "No", 1: "Yes"]),
            Setting(name: "ProcEmulation", offset: 488, length: 4, label: "Processor Emulation", help: "This setting determines processor type to be emulated on pre-production silicon.", bits: 0...3, options: [0: "No Emulation", 1: "EMULATE Intel (R) vPro (TM) capable Processor", 2: "EMULATE Intel (R) Core (TM) branded Processor", 3: "EMULATE Intel (R) Celeron (R) branded Processor", 4: "EMULATE Intel (R) Pentium (R) branded Processor", 5: "EMULATE Intel (R) Xeon E (R) branded Processor", 6: "EMULATE Intel (R) Xeon W (R) Manageability capable Processor"]),
            Setting(name: "PSRSupported", offset: 344, length: 4, label: "Platform Service Record supported", help: "This setting enables the Platform Support Record capability", bits: 5...5, options: [0: "No", 1: "Yes"]),
            Setting(name: "CryptoHwSupport", offset: 344, length: 4, label: "Crypto HW Support", help: "This setting can be used to disable crypto funtionality. This settings disables all crypto dependent features.", bits: 13...13, options: [0: "Yes", 1: "No"]),
            Setting(name: "OemTag", offset: 524, length: 4, label: "OEM Tag", help: "This is a free form 32bit field that allows the OEM to configure their own unique identifier in the firmware image.", hex: true),
            Setting(name: "FwUpdEnable", offset: 92, length: 4, label: "Hide MEBx Firmware Update Control", bits: 0...0, options: [0: "No", 1: "Yes"]),
            Setting(name: "AmtSupported", offset: 344, length: 4, label: "Intel(R) AMT Supported", help: "This setting allows customers to disable Intel(R) AMT on the platform.\nNote: Either Intel(R) AMT or Intel(R) ISM can be enabled as manageability application", bits: 0...0, options: [0: "No", 1: "Yes"]),
            Setting(name: "ISMSupported", offset: 344, length: 4, label: "Intel(R) Standard Manageability", help: "Intel(R) Standard Manageability is a manageability mode that supports a subset of the Intel(R) Active Management Technology (Intel(R) AMT).\nNote: Either Intel(R) AMT or Intel(R) ISM can be enabled as manageability application", bits: 1...1, options: [0: "No", 1: "Yes"]),
            Setting(name: "MngAppSupported", offset: 344, length: 4, label: "Manageability Application Supported", help: "This setting allows customers to permenantly disable Intel(R) AMT and Standard Manageability mode on the platform.", bits: 2...2, options: [0: "No", 1: "Yes"]),
            Setting(name: "MngAppPowerUpState", offset: 404, length: 4, label: "Manageability Application initial power-up state", help: "This setting allows customers to determine the power up state for Intel(R) AMT or Standard Manageability.  Note: If this setting is disabled Intel(R) AMT or Standard Manageability can still be re-enabled through the MEBx interface.", bits: 2...2, options: [0: "Disabled", 1: "Enabled"]),
            Setting(name: "KvmSupported", offset: 344, length: 4, label: "KVM Redirection Supported", help: "This setting allows customers to enable / disable the KVM Redirection capabilities of the firmware.  Note: If this setting have been set to disabled it cannot be re-enabled once the descriptor has been locked.", bits: 18...18, options: [0: "No", 1: "Yes"]),
            Setting(name: "TlsCryptoSupport", offset: 344, length: 4, label: "Transport Layer Security Crypto Support", help: "This setting allows customers to enable / disable firmware Transport Layer Security support.  Note: If this is disabled TLS will be permanently disabled in the firmware image.", bits: 21...21, options: [0: "No", 1: "Yes"]),
            Setting(name: "IshPowerUpState", offset: 404, length: 4, label: "Integrated Sensor Hub Initial Power Up State", help: "This setting allows customers to determine the power up state for ISH.", bits: 10...10, options: [0: "Disabled", 1: "Enabled"]),
            Setting(name: "PttSupported", offset: 344, length: 4, label: "Intel(R) PTT Supported", help: "This setting permanently disables Intel(R) PTT in the firmware image.", bits: 29...29, options: [0: "No", 1: "Yes"]),
            Setting(name: "PttPwrUpState", offset: 404, length: 4, label: "Intel(R) PTT initial power-up state", help: "This setting determines if Intel(R) PTT is enabled on platform power-up.", bits: 29...29, options: [0: "Disabled", 1: "Enabled"]),
        ]),
        File(path: "/home/amt/rtfd/PrivacyLvl", alias: "PRIVACY_LEVEL_FILE", settings: [
            Setting(name: "RedirectionPrivSecLevel", offset: 0, length: 1, label: "Redirection Privacy / Security Level", help: "This setting allows customers to configure the Privacy and Security level for redirection operations.  Default enables all redirection ports (User consent is configurable).  Enhanced enables all redirection ports (User consent is required and cannot be disabled).  Extreme disables all redirection capabilities.", options: [1: "Default", 2: "Enhanced", 3: "Extreme"]),
        ]),
        File(path: "/home/amt/rtfd/WDResetState", alias: "AMT_WD_RESET_STATE", settings: [
            Setting(name: "AmtWdAutoReset", offset: 0, length: 1, label: "Watchdog Automatic Reset Enabled", help: "This setting allows customers to enable the Intel (R) ME firmware to trigger an automatic platform reset if either the MEI or Agent Presence are in a hung state.  Note: This feature only allows one reset at a time when the watchdog expires.  After this feature has triggered a reset it must be re-armed for re-use via management console.", options: [0: "No", 1: "Yes"]),
        ]),
        File(path: "/home/amt/rtfd/amt.wol", alias: "PCR_AMT_IDLE_TIMEOUT", settings: [
            Setting(name: "AmtIdleTimeout", offset: 0, length: 2, label: "Idle Timeout", help: "This setting configures the idle timeout value before Manageability app enters into an off state.", hex: true),
        ]),
        File(path: "/home/amt/rtfd/rsb.state", alias: "RSB_FITC_STATE_NVAR", settings: [
            Setting(name: "KvmScreenBlnkEnable", offset: 0, length: 1, label: "Firmware KVM Screen Blanking", help: "This setting enables KVM Screen blanking capabilities in the firmware image.  Note: This feature is dependent on processor level support.", options: [0: "No", 1: "Yes"]),
        ]),
        File(path: "/home/amt/skip_rtfd/ncsi", alias: "NCSI_LAN_SETTINGS_FILE", settings: [
            Setting(name: "vproNicEnabled", offset: 0, length: 1, label: "Platform vPro 2.5G Wired LAN Enabled", help: "YES = Discrete NIC enabled in platform\nNO = Integrated GBE LAN enabled in platform", bits: 0...0, options: [0: "No", 1: "Yes"]),
            Setting(name: "vproNicSMBusAddress", offset: 5, length: 1, label: "Platform vPro 2.5G Wired LAN SMBUS slave address", help: "Platform discrete NIC slave address\nNote: Input needs to be in HEX format(OEM specific), e.g. 0x12", hex: true),
            Setting(name: "TypeCPortRetimerMCTPSmbusAddr_ncsi", offset: 6, length: 1, label: "vPro 2.5G Wired LAN on dock slave SMBUS Address", help: "Dock NIC slave address\nNote: Input needs to  be in HEX format(OEM specific), e.g. 0x12", hex: true),
            Setting(name: "ThunderboltPort1SMBUSAddress", offset: 1, length: 1, label: "Thunderbolt Port1 SMBUS Address", help: "This setting configures the Intel(R) SMBus I2C Address.\nNote: Input needs to be in HEX format(OEM specific), e.g. 0x12", hex: true),
            Setting(name: "ThunderboltPort2SMBUSAddress", offset: 2, length: 1, label: "Thunderbolt Port2 SMBUS Address", help: "This setting configures the Intel(R) SMBus I2C Address.\nNote: Input needs to be in HEX format(OEM specific), e.g. 0x12", hex: true),
            Setting(name: "ThunderboltPort3SMBUSAddress", offset: 3, length: 1, label: "Thunderbolt Port3 SMBUS Address", help: "This setting configures the Intel(R) SMBus I2C Address.\nNote: Input needs to be in HEX format(OEM specific), e.g. 0x12", hex: true),
            Setting(name: "ThunderboltPort4SMBUSAddress", offset: 4, length: 1, label: "Thunderbolt Port4 SMBUS Address", help: "This setting configures the Intel(R) SMBus I2C Address.\nNote: Input needs to be in HEX format(OEM specific), e.g. 0x12", hex: true),
        ]),
        File(path: "/home/amt/skip_rtfd/sfx.isSecure", alias: "PROV_PKI_FQDN_SUFFIX_IS_SECURE", settings: [
            Setting(name: "SuffixIsSecure", offset: 0, length: 1),
        ]),
        File(path: "/home/bup/bup_sku/hw_binding", alias: "HW_BINDING_ENABLED", settings: [
            Setting(name: "HwBindingEn", offset: 0, length: 1, label: "Hardware Binding Enabled", help: "This setting configures the FPF Hardware and RPMC / RPMB binding behavior for the platform image.\nIf this setting is enabled FPF Hardware and RPMC / RPMB binding behavior will occur when platform close manufacturing flow is executed with Intel(R) FPT. \nIf this setting is disabled FPF Hardware and RPMC / RPMB binding behavior will not take place when close manufacturing flow is executed.\nNote: For Revenue parts this setting will be ignored and FPF Hardware and RPMC / RPMB binding behavior will take place when close manufacturing flow is executed.", options: [0: "Disabled", 1: "Enabled"]),
        ]),
        File(path: "/home/bup/si_features", alias: "BUP_SI_FEATURES", settings: [
            Setting(name: "DbgOverridePreProdSi", offset: 12, length: 4, label: "Debug Override Pre-Production Silicon", help: "Allows the OEM to control FW features to assist with pre-production platform debugging.  This control has no effect if used on production silicon.  Note: Certain options will do not work when the descriptor is locked (See FW Bring-up Guide for setting details).  Important: Due to an HW issue, this setting should be set temporarily to 0x400107 to prevent boot issues.", hex: true),
            Setting(name: "DbgOverrideProdSi", offset: 16, length: 4, label: "Debug Override Production Silicon", help: "Allows the OEM to control FW features to assist with production platform debugging.  Note: Certain options will do not work when the descriptor is locked (See FW Bring-up Guide for setting details).", hex: true),
        ]),
        File(path: "/home/hotham/dbg_dam_req", alias: "HOTHAM_DAM_EN", settings: [
            Setting(name: "DelayedAuthMode", offset: 0, length: 1, label: "Delayed Authentication Mode Enabled", help: "This setting enables Delayed Authentication Mode on the platform.", options: [0: "No", 1: "Yes"]),
        ]),
        File(path: "/home/mca/host_sw_sqnc_mode", alias: "HOST_SW_SEQUENCING_MODE", settings: [
            Setting(name: "SpiSwSeqEnable", offset: 0, length: 1, label: "SPI Software Sequencing Enabled", help: "IoTG configuration. This setting will enable SPI software sequencing, in order to allow the host to write PCH binding information. Note: This setting is disabled b default and can be enabeled until EOM.", bits: 0...0, options: [0: "No", 1: "Yes"]),
        ]),
        File(path: "/home/mca/icps", alias: "SKU_MGR_REQUESTED_BRAND_ENTITLEMENTS", settings: [
            Setting(name: "PlatformBrandIdentity", offset: 0, length: 4, label: "System Brand", bits: 1...4, options: [0: "Not selected", 1: "Intel vPro(TM) Enterprise", 2: "Intel vPro(TM) Essentials", 8: "Intel-based PC"]),
        ]),
        File(path: "/home/mctp/device_ports", alias: "MCTP_DEVICE_PORTS", settings: [
            Setting(name: "MctpDevicePortEc", offset: 0, length: 1, hex: true),
            Setting(name: "MctpDevicePortSio", offset: 1, length: 1, hex: true),
            Setting(name: "MctpDevicePortIsh", offset: 2, length: 1, hex: true),
            Setting(name: "MctpDevicePortBmc", offset: 3, length: 1, hex: true),
        ]),
        File(path: "/home/mctp/ec_oob_smbus_addr", alias: "EC_OOB_SMBUS_ADDR", settings: [
            Setting(name: "ECOOBSmbusAddr", offset: 0, length: 1, label: "eSPI OOB EC SMBUs Address", help: "This setting determines the SMBUS address for eSPI OOB to be handled by EC.", hex: true),
        ]),
        File(path: "/home/mctp/opaque_en", alias: "opaque_en", settings: [
            Setting(name: "EspiEnabled", offset: 0, length: 1, label: "Opaque Supported", help: "This setting enables the 'WSMAN Opaque' interface. OEM ID must be set (under UPID). 'eSPI OOB EC SMBus address' is set in the new 'eSPI OOB' section under 'Intel ME Kernel' that is shared with eRPMC", options: [0: "No", 1: "Yes"]),
        ]),
        File(path: "/home/mctp/smt2_devices", alias: "MCTP_SMT2_DEVICES", settings: [
            Setting(name: "vproNicSMBusAddress_sm2_devices", offset: 0, length: 1, label: "Platform vPro 2.5G Wired LAN SMBUS slave address", help: "Platform discrete NIC slave address\nNote: Input needs to be in HEX format(OEM specific), e.g. 0x12", hex: true),
            Setting(name: "TypeCPortRetimerMCTPSmbusAddr_smt2", offset: 2, length: 1, label: "vPro 2.5G Wired LAN on dock slave SMBUS Address", help: "Dock NIC slave address\nNote: Input needs to  be in HEX format(OEM specific), e.g. 0x12", hex: true),
        ]),
        File(path: "/home/policy/Bist/auto_config", alias: "POLICY_BIST_AUTO_CONFIG", settings: [
            Setting(name: "FwAutoBist", offset: 0, length: 4, label: "Automatic Built in Self Test", help: "This setting enables the firmware Automatic Built in Self Test which is executed during first platform boot after initial image flashing.", bits: 0...0, options: [0: "Disabled", 1: "Enabled"]),
        ]),
        File(path: "/home/policy/hmrfpo_state", alias: "POLICY_HMRFPO_STATE", settings: [
            Setting(name: "HmrfpoEnable", offset: 0, length: 1, label: "Intel(R) ME Region Flash Protection Override", help: "This setting enables descriptor unlock of the ME Region when the HMRFPO message is sent to firmware prior to BIOS End of POST.", options: [0: "No", 1: "Yes"]),
        ]),
        File(path: "/home/policy/msrmnt_sup", alias: "POLICY_MSRMT_SUPPORT", settings: [
            Setting(name: "MeMeasuredBootState", offset: 0, length: 1, label: "Intel(R) ME Measured Boot State", help: "When measured boot is enabled firmware will use additional extended registers for all IUPs and Key Manifests that firmware loads and verifies from flash. \nNote: When measured boot is enabled any IUPs or firmware updates will require a global reset", options: [0: "Disabled", 1: "Enabled"]),
        ]),
        File(path: "/home/ptt/ptt_smx_disable", alias: "PTT_SMX_DISABLE", settings: [
            Setting(name: "SmxSupport", offset: 0, length: 1, label: "SMx State", bits: 0...0, options: [0: "Enabled", 1: "Disabled"]),
            Setting(name: "Rsa1KSupport", offset: 0, length: 1, label: "Rsa 1K State", bits: 1...1, options: [0: "Enabled", 1: "Disabled"]),
        ]),
        File(path: "/home/rbe/MANAGEABILITY_HW_DIS", alias: "DISABLE_MANAGEABILITY_HW", settings: [
            Setting(name: "MngHwStatusEfs", offset: 0, length: 1, label: "Manageability Application Hardware Status EFS", help: "This setting will disable Intel(R) AMT hardware.", options: [0: "Yes", 1: "No"]),
        ]),
        File(path: "/home/rbe/binding_sig_type", alias: "BINDING_SIGNATURE_TYPE", settings: [
            Setting(name: "BindingSigType", offset: 0, length: 1, label: "Binding Signature Type", help: "IoTG Configuration. Defines the type of the Binding Signature that will be supported by FW.", bits: 0...0, options: [0: "PCH Based Signature", 1: "IFP based Signature"]),
        ]),
        File(path: "/home/secureboot/brm_cfg", alias: "SECUREBOOT_BRM_CONFIG", settings: [
            Setting(name: "BiosRedAssistance", offset: 0, length: 4, label: "BIOS Redundancy Assistance", help: "In case of BIOS boot failure, CSME will configure the platform to boot with backup BIOS using Top Swap. Note: This option is only available when Boot Guard is enabled.", options: [0: "Disabled", 1: "Enabled"]),
        ]),
        File(path: "/home/stp/stp_enabled", alias: "STP_ENABLED", settings: [
            Setting(name: "StpEnabled", offset: 0, length: 1, label: "STP Enabled", help: "Enable/disable STP on the target platform", options: [0: "No", 1: "Yes"]),
        ]),
        File(path: "/home/stp/stp_smlink_selection", alias: "STP_SMLINK_SELECTION", settings: [
            Setting(name: "StpSmlinkSelection", offset: 0, length: 1, label: "STP SMLink selection", help: "Select which SMLink is to be used for STP.", options: [0: "SMLink0", 1: "SMLink1", 255: "Not Selected"]),
        ]),
        File(path: "/home/tcss/tcss_ctrl", alias: "tcss_tcss_ctrl", settings: [
            Setting(name: "TcssAuthenticateEn", offset: 0, length: 1, label: "Type-C SubSystem Authentication Enabled", help: "This setting enables / disables firmware authentication for the Type-C Subsystem on power-up", options: [0: "Yes", 1: "No"]),
        ]),
        File(path: "/home/upid/platform_id_support", alias: "UPID_PLATFORM_ID_SUPPORT", settings: [
            Setting(name: "UniquePlatformIdSupportedFeature", offset: 0, length: 1, label: "UPID Supported", help: "This setting allows OEM to create their own unique platform identifier. If this setting is enabled, the below OEM ID should be set.", bits: 0...0, options: [0: "No", 1: "Yes"]),
        ]),
        ])
}

