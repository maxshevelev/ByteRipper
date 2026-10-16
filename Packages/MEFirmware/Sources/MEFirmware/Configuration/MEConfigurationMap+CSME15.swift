// The CSME 15 map of the ME configuration — emitted by
// `Skills/me-eom-structures/scripts/fit_map.py` from Flash Image Tool 15.0's
// own layout documents (the tgp_lp platform of ME 15).
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
    public static let csme15 = MEConfigurationMap(
        name: "CSME 15 (Flash Image Tool 15.0)",
        files: [
        File(path: "/home/mca/eom_config", alias: "EOM_Config", settings: [
            Setting(name: "EomFirstBootEnabled", offset: 0, length: 1, label: "EOM on First Boot Enabled", help: "This setting detremines if End of Manufacturing will be triggered on first boot of the platform after flashing.\nNote: When this setting is enabled Intel(R) CSME will enter End of Manufacturing regardless of the descriptor settings.", bits: 0...0, options: [0: "No", 1: "Yes"]),
            Setting(name: "FlexibleEomSettings", offset: 0, length: 1, label: "Flexible EOM setting options", help: "This setting deteremines which settings will be automatically commited during End of Manufacturing flows.\nNote: The FPFs, RPMB / RPMC and set manufacturing mode settings are mandatory and cannot be overridden revenue parts. Simulation can be done on non-revenue part with the Hardware binding set to disabled.", bits: 1...2, options: [0: "Lock Descriptor and OEM Configs", 1: "Lock OEM Configs Only", 2: "Lock Descriptor Only", 3: "Do not lock Descriptor and OEM Configs"]),
        ]),
        File(path: "/home/mca/eom", alias: "EOM", settings: [
            Setting(name: "EomFirstBootEnabled", offset: 0, length: 1, label: "EOM on First Boot Enabled", help: "This setting detremines if End of Manufacturing will be triggered on first boot of the platform after flashing.\nNote: When this setting is enabled Intel(R) CSME will enter End of Manufacturing regardless of the descriptor settings.", options: [0: "No", 1: "Yes"]),
        ]),
        File(path: "/home/smbus/smlink_bus", alias: "SmlinkBus", settings: [
            Setting(name: "SmlinkBusSelection", offset: 0, length: 1, label: "Bus Selection", help: "Grasslake transport layer", options: [0: "SMLink0", 1: "SMLink0B"]),
        ]),
        File(path: "/home/iunit/iunit_oem_cfg", alias: "IUnitOemCfg", settings: [
            Setting(name: "FWSecureMode", offset: 17, length: 1, label: "FW Secure Mode", help: "If enabled, access blockers in IS and PS are enabled, and FW is read from IMR. Must be enabled for FW authentication flow and execution of authenticated FW.", options: [0: "Disabled", 1: "Enabled"]),
            Setting(name: "PortConfigurationFor8LSBLanes", offset: 4, length: 4, label: "Port Configuration For 8 LSB Lanes", help: "When CSI2_CNL.CR_OVRD  is cleared this determines the port configuration mapping between the lower 8 MIPI lanes and the CSI receiver ports the lanes can connect to:\n\n        Bits[3:0] determine the configuration of Port A:\n\n         0x0: port is disabled \n\n         0x4: X1 (ICL only)\n\n         0x5: X2 (ICL only)\n\n         Others: reserved \n\n         Bits[8:4] determine the configuration of Port B: \n\n         0x0: port is disabled \n\n         Others: reserved \n\n        Bits[10:9] determine the configuration of Port C: \n\n         0x0: port is disabled \n\n         0x2: X1 \n\n         Others: reserved \n\n        Bits[13:11] determine the configuration of Port D: \n\n         0x0: port is disabled \n\n         0x5: X2 \n\n         0x7: X4 \n\n         Others: reserved", hex: true),
            Setting(name: "PortConfigurationFor8MSBLanes", offset: 8, length: 4, label: "Port Configuration For 8 MSB Lanes", help: "When CSI2_CNL.CR_OVRD  is cleared this determines the port configuration mapping between the upper 8 MIPI lanes and the CSI receiver ports the lanes can connect to: \n\n        Bits[3:0] determine the configuration of Port A: \n\n         0x0: port is disabled \n\n         0x4: X1 \n\n         0x5: X2 \n\n         Others: reserved \n\n        Bits[8:4] determine the configuration of Port B: \n\n         0x0: port is disabled \n\n         0x9: X2 \n\n         Others: reserved \n\n        Bits[10:9] determine the configuration of Port C: \n\n         0x0: port is disabled \n\n         0x2: X1 \n\n         Others: reserved \n\n        Bits[13:11] determine the configuration of Port D: \n\n         0x0: port is disabled \n\n         0x5: X2 \n\n         0x7: X4 \n\n         Others: reserved", hex: true),
            Setting(name: "RomTraceEnable", offset: 16, length: 1, label: "IPU Debugging Enabled", help: "If enabled, IPU Debugging is enabled, otherwise internal setup is checked to see if the IPU Debugging feature should be enabled or not.", options: [0: "Disabled", 1: "Enabled"]),
            Setting(name: "SecureTouch", offset: 8, length: 1, label: "Secure Touch", help: "When set, CAMERA_MASK register bits per CSI port are used to mask the data of cameras. When cleared, camera data is not masked. ", options: [0: "Disabled", 1: "Enabled"]),
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
            Setting(name: "FwUpdEnable", offset: 92, length: 1, label: "Hide MEBx Firmware Update Control", bits: 0...0, options: [0: "No", 1: "Yes"]),
            Setting(name: "HideMEBxFwUpdCtrl", offset: 88, length: 1, label: "Hide MEBx Firmware Update Control", help: "This setting allows customers to hide the Firmware Update option in the MEBx interface.", bits: 1...1, options: [0: "No", 1: "Yes"]),
            Setting(name: "IshPowerUpState", offset: 404, length: 2, label: "Integrated Sensor Hub Initial Power State", help: "This setting allows customers to determine the power up state for ISH.", bits: 10...10, options: [0: "Disabled", 1: "Enabled"]),
            Setting(name: "KvmSupported", offset: 344, length: 3, label: "KVM Redirection Supported", help: "This setting allows customers to enable / disable the KVM Redirection capabilities of the firmware.  Note: If this setting have been set to disabled it cannot be re-enabled once the descriptor has been locked.", bits: 18...18, options: [0: "No", 1: "Yes"]),
            Setting(name: "MELanPowerWell", offset: 188, length: 1, label: "LAN Power Well", help: "This setting allows the customer to configure the powerwell that will be used by Intel(R) Integrated LAN.  Note: Recommended setting is SLP_LAN#.", bits: 0...2, options: [0: "Core Well", 1: "SUS Well", 2: "ME Well", 3: "SLP_LAN#"]),
            Setting(name: "MEWlanPowerWell", offset: 200, length: 1, label: "WLAN Power Well", bits: 0...7, options: [128: "Disabled", 129: "Core Well || SLP_S3#", 130: "Primary Well || SLP_SUS#", 131: "ME Well || SLP_A#", 134: "SLP_WLAN#"]),
            Setting(name: "MeClinkEnable", offset: 464, length: 1, label: "Intel(R) ME CLINK Signal Enabled", help: "This setting allows customers to enable / disable the Wireless LAN CLINK signal through Intel(R) ME firmware.  Note: For using Intel(R) vPro Wireless solutions this should be set to Yes.", bits: 0...0, options: [0: "No", 1: "Yes"]),
            Setting(name: "MngAppPowerUpState", offset: 404, length: 1, label: "Manageability Application initial power-up state", help: "This setting allows customers to determine the power up state for Intel(R) AMT or Standard Manageability.  Note: If this setting is disabled Intel(R) AMT or Standard Manageability can still be re-enabled through the MEBx interface.", bits: 2...2, options: [0: "Disabled", 1: "Enabled"]),
            Setting(name: "MngAppSupported", offset: 344, length: 1, label: "Manageability Application Supported", help: "This setting allows customers to permenantly disable Intel(R) AMT and Standard Manageability mode on the platform.", bits: 2...2, options: [0: "No", 1: "Yes"]),
            Setting(name: "NetServicesSupported", offset: 344, length: 3, label: "Intel(R) ME Network Services Supported", help: "This setting allows customers to enable / disable Intel(R) ME Network Services on the platform.  Note: If this setting is disabled Intel(R) AMT will also be disabled.", bits: 16...16, options: [0: "Yes", 1: "No"]),
            Setting(name: "ProcEmulation", offset: 488, length: 1, label: "Processor Emulation", bits: 0...3, options: [0: "No Emulation", 1: "EMULATE Intel (R) vPro (TM) capable Processor", 2: "EMULATE Intel (R) Core (TM) branded Processor", 3: "EMULATE Intel (R) Celeron (R) branded Processor", 4: "EMULATE Intel (R) Pentium (R) branded Processor", 5: "EMULATE Intel (R) Xeon E (R) branded Processor", 6: "EMULATE Intel (R) Xeon W (R) Manageability capable Processor"]),
            Setting(name: "PttPwrUpState", offset: 404, length: 4, label: "Intel(R) PTT initial power-up state", bits: 29...29, options: [0: "Disabled", 1: "Enabled"]),
            Setting(name: "PttSupported", offset: 344, length: 4, label: "Intel(R) PTT Supported", help: "This setting permanently disables Intel(R) PTT in the firmware image.", bits: 29...29, options: [0: "No", 1: "Yes"]),
            Setting(name: "TlsCryptoSupport", offset: 344, length: 3, label: "Transport Layer Security crypto support", help: "This setting allows customers to enable/ disable FW Transport Layer Security algorithm crypto fuse.  Note: if this is disabled, TLS is still operational but without crypto.", bits: 21...21, options: [0: "No", 1: "Yes"]),
        ]),
        File(path: "/home/bup/si_features", alias: "KernFixedData", settings: [
            Setting(name: "DbgOverridePreProdSi", offset: 12, length: 4, label: "Debug Override Pre-Production Silicon", help: "Allows the OEM to control FW features to assist with pre-production platform debugging.  This control has no effect if used on production silicon.  Note: Certain options will do not work when the descriptor is locked (See FW Bring-up Guide for setting details).", hex: true),
            Setting(name: "DbgOverrideProdSi", offset: 16, length: 4, label: "Debug Override Production Silicon", help: "Allows the OEM to control FW features to assist with production platform debugging.  Note: Certain options will do not work when the descriptor is locked (See FW Bring-up Guide for setting details).", hex: true),
        ]),
        File(path: "/home/amt/skip_rtfd/ehbc.state", alias: "EhcbState", settings: [
            Setting(name: "EhbcEnable", offset: 0, length: 1, label: "Embedded Host Based Configuration Enabled", help: "This setting allows customers to enable / disable Embedded Host Based Configuration. EHBC is primarily intended for use in embedded systems, please leave this setting disabled for business client systems.", options: [0: "No", 1: "Yes"]),
        ]),
        File(path: "/home/fwupdate/fwuoemid", alias: "OEM_ID_STRING", settings: [
            Setting(name: "FwUpdateOemId", offset: 0, length: 16, label: "Firmware Update OEM ID", help: "This setting allows configuration of an OEM unique ID to ensure that customers can only update their platform with images from the OEM of the platform."),
        ]),
        File(path: "/home/pavp/guc_hash", alias: "GucHash", settings: [
            Setting(name: "GucHash", offset: 0, length: 32, label: "GuC Encryption Key", help: "This option is for entering the raw hash 256 bit string for the Graphics uController."),
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
        File(path: "/home/mctp/eid_db", alias: "MctpStackConfig", settings: [
            Setting(name: "MctpPcieAddress", offset: 5, length: 1, label: "MCTP PCIe Address", hex: true),
            Setting(name: "MctpStackConfig", offset: 2, length: 3, label: "MCTP Stack Configuration", help: "Defines the ME's 8-bits MCTP Endpoint IDs for each SMBus physical interface (SMBus, SMLink0 and SMLink1). These values are needed for FW to communicate with MCTP end points. For each of these 3 bytes, a value of 0x00 means not used, and values 0xFF or 0x01 - 0x07 or 0x20 - 0x2F are not allowed."),
        ]),
        File(path: "/home/policy/msrmnt_sup", alias: "MeasurmentSupport", settings: [
            Setting(name: "MeMeasuredBootState", offset: 0, length: 1, label: "Intel(R) ME Measured Boot State", help: "When measured boot is enabled firmware will use additional extended registers for all IUPs and Key Manifests that firmware loads and verifies from flash. \nNote: When measured boot is enabled any IUPs or firmware updates will require a global reset", options: [0: "Disabled", 1: "Enabled"]),
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
        File(path: "/home/iunit/iunit_privacy_mode", alias: "iunitPrivacyMode", settings: [
            Setting(name: "PrivacyFeatureControlDisabled", offset: 0, length: 1, label: "Camera privacy feature control disabled", help: "This NVAR enables/disables the camera privacy. Enabling this NVAR means that the Camera privacy GPIO Pin value is used to mask/unmask all cameras’ data from being used", options: [0: "false", 1: "true"]),
        ]),
        File(path: "/home/amt/skip_rtfd/sfx.isSecure", alias: "SfxIsSecure", settings: [
            Setting(name: "SuffixIsSecure", offset: 0, length: 1, options: [0: "false", 1: "true"]),
        ]),
        File(path: "/home/amt/skip_rtfd/ncsi", alias: "AmtNetworkConfiguration", settings: [
            Setting(name: "TypeCPort1RetimerI2cAddress", offset: 1, length: 1, label: "Type-C Port1 Re-Timer I2C Address", help: "This setting configures the Intel(R) SMBus I2C Address.\nNote: Input needs to be in HEX format(OEM specific), e.g. 0x12", hex: true),
            Setting(name: "TypeCPort2RetimerI2cAddress", offset: 2, length: 1, label: "Type-C Port2 Re-Timer I2C Address", help: "This setting configures the Intel(R) SMBus I2C Address.\nNote: Input needs to be in HEX format(OEM specific), e.g. 0x12", hex: true),
            Setting(name: "TypeCPort3RetimerI2cAddress", offset: 3, length: 1, label: "Type-C Port3 Re-Timer I2C Address", help: "This setting configures the Intel(R) SMBus I2C Address.\nNote: Input needs to be in HEX format(OEM specific), e.g. 0x12", hex: true),
            Setting(name: "TypeCPort4RetimerI2cAddress", offset: 4, length: 1, label: "Type-C Port4 Re-Timer I2C Address", help: "This setting configures the Intel(R) SMBus I2C Address.\nNote: Input needs to be in HEX format(OEM specific), e.g. 0x12", hex: true),
            Setting(name: "TypeCPortRetimerMCTPSmbusAddr", offset: 6, length: 1, label: "vPro 2.5G Wired LAN on dock slave SMBUS Address", help: "vPro 2.5G Wired LAN slave address\nNote: Input needs to be in HEX format(OEM specific), e.g. 0x12", hex: true),
            Setting(name: "vproDockEnabled", offset: 0, length: 1, label: "vPro Dock Enabled", help: "YES = Enables communication with, vPro supporting NIC, via TBT dock\nNO = No support for vPro dock solution", bits: 1...1, options: [0: "No", 1: "Yes"]),
            Setting(name: "vproNicEnabled", offset: 0, length: 1, label: "Platform vPro 2.5G Wired LAN Enabled", help: "YES = Discrete NIC enabled in platform\nNO = Integrated GBE LAN enabled in platform", bits: 0...0, options: [0: "No", 1: "Yes"]),
            Setting(name: "vproNicSMBusAddress", offset: 5, length: 1, label: "Platform vPro 2.5G Wired LAN SMBUS slave address", help: "Platform discrete NIC slave address\nNote: Input needs to be in HEX format(OEM specific), e.g. 0x12", hex: true),
        ]),
        File(path: "/home/mctp/smt2_devices", alias: "Smt2Devices", settings: [
            Setting(name: "TypeCPortRetimerMCTPSmbusAddr", offset: 2, length: 1, label: "vPro 2.5G Wired LAN on dock slave SMBUS Address", help: "vPro 2.5G Wired LAN slave address\nNote: Input needs to be in HEX format(OEM specific), e.g. 0x12", hex: true),
            Setting(name: "vproNicSMBusAddress", offset: 0, length: 1, label: "Platform vPro 2.5G Wired LAN SMBUS slave address", help: "Platform discrete NIC slave address\nNote: Input needs to be in HEX format(OEM specific), e.g. 0x12", hex: true),
        ]),
        File(path: "/home/mctp/espi_en", alias: "eSpiEnabled", settings: [
            Setting(name: "eSpiEnabled", offset: 0, length: 1, label: "eSPI Enabled", help: "Enable Grasslake HW layer over eSPI", options: [0: "No", 1: "Yes"]),
        ]),
        ])
}
