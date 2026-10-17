// The CSME 16 map of the ME configuration — emitted by
// `Skills/me-eom-structures/scripts/mfit_map.py` from the settings
// databases of Flash Image Tool 16.1.42, 16.1.25.2091, 16.0.15.1662,
// merged as one: the offsets, bits, the tool's own name for
// each setting (`label`), its option labels and the
// `Auto` marks are Intel's, copied; nothing here is read out of a dump.
//
// A generation's map lives in a file of its own: see `MEConfigurationMap.swift`
// for what a map is and why each generation has its own.

import Foundation

extension MEConfigurationMap {
    /// The ME 16 configuration, as MFIT 16 lays it out. The files stand in the
    /// order a bench reads them — the ME configuration itself first, then the
    /// policy and the settings an edit is usually about — and the rest in
    /// MFIT's own order, which is the order to diff a new build against.
    public static let csme16 = MEConfigurationMap(
        name: "CSME 16 (Flash Image Tool 16.1.42, 16.1.25.2091, 16.0.15.1662)",
        files: [
        File(path: "/home/mca/eom_config", alias: "EOM_Config", settings: [
            Setting(name: "EomFirstBootEnabled", offset: 0, length: 2, label: "EOM on First Boot Enabled", help: "This setting determines if End of Manufacturing will be triggered on first boot of the platform after flashing.\nNote: When this setting is enabled Intel(R) CSME will enter End of Manufacturing regardless of the descriptor settings.", bits: 0...0, options: [0: "No", 1: "Yes"]),
            Setting(name: "FlexibleEomSettings", offset: 0, length: 2, label: "Flexible EOM setting options", help: "This setting deteremines which settings will be automatically commited during End of Manufacturing flows.\nNote: The FPFs, RPMB / RPMC and set manufacturing mode settings are mandatory and cannot be overridden revenue parts. Simulation can be done on non-revenue part with the Hardware binding set to disabled.", bits: 1...2, options: [0: "Lock Descriptor and OEM Configs", 1: "Lock OEM Configs Only", 2: "Lock Descriptor Only", 3: "Do not lock Descriptor and OEM Configs"]),
        ]),
        File(path: "/home/mca/eom", alias: "EOM", settings: [
            Setting(name: "EomFirstBootEnabled", offset: 0, length: 1, label: "EOM on First Boot Enabled", help: "This setting determines if End of Manufacturing will be triggered on first boot of the platform after flashing.\nNote: When this setting is enabled Intel(R) CSME will enter End of Manufacturing regardless of the descriptor settings.", options: [0: "No", 1: "Yes"]),
        ]),
        File(path: "/home/mca/mca_oem_version", alias: "EOM_VERSION", settings: [
            Setting(name: "OemFwVersion", offset: 0, length: 8, label: "OEM FW Version", help: "This setting contains the OEM IP version", auto: true, hex: true),
        ]),
        File(path: "/home/pavp/hdcp_ports", alias: "PavpHdcp", settings: [
            Setting(name: "Hdcp5kedisp1", offset: 0, length: 1, label: "HDCP Internal Display Port 1 - 5K", help: "This setting determines which port is connected to internal display 1", options: [0: "None", 1: "PortA", 2: "PortB", 4: "PortC"]),
        ]),
        File(path: "/home/smbus/smlink_bus", alias: "SmlinkBus", settings: [
            Setting(name: "SmlinkBusSelection", offset: 0, length: 1, label: "Bus Selection", help: "Additional SMLink configuration transport layer", options: [0: "SMLink0", 1: "SMLink0B"]),
        ]),
        File(path: "/home/iunit/iunit_oem_cfg", alias: "IUnitOemCfg", settings: [
            Setting(name: "SecureTouch", offset: 18, length: 1, label: "Secure Touch", help: "When set, CAMERA_MASK register bits per CSI port are used to mask the data of cameras. When cleared, camera data is not masked. ", options: [0: "Disabled", 1: "Enabled"], auto: true),
            Setting(name: "FWSecureMode", offset: 17, length: 1, label: "FW Secure Mode", help: "If enabled, access blockers in IS and PS are enabled, and FW is read from IMR. Must be enabled for FW authentication flow and execution of authenticated FW.", options: [0: "Disabled", 1: "Enabled"], auto: true),
            Setting(name: "SecureTouchCameraMask", offset: 0, length: 4, label: "Secure Touch and Camera Mask", help: "Camera mask bits per CSI port. When SECURE_TOUCH is set each set bit masks a CSI port for secure touch. When SECURE_TOUCH is cleared this register has no impact on the CSI ports.", auto: true, hex: true),
            Setting(name: "RomTraceEnable", offset: 16, length: 1, label: "IPU Debugging Enabled", help: "If enabled, IPU Debugging is enabled, otherwise internal setup is checked to see if the IPU Debugging feature should be enabled or not.", options: [0: "Disabled", 1: "Enabled"], auto: true),
            Setting(name: "PortConfigurationFor8LSBLanes", offset: 4, length: 4, label: "Port Configuration For 8 LSB Lanes", help: "When SW DRIVER CONTROLS PORT CONFIGURATION is cleared this determines the port configuration mapping between the lower 8 MIPI lanes and the CSI receiver ports the lanes can connect to.: \n\n               Bits[3:0] determine the configuration of Port A:\n\n                0x0: port is disabled \n\n                0x4: X1 (ICL only)\n\n                0x5: X2 (ICL only)\n\n                Others: reserved \n\n                Bits[8:4] determine the configuration of Port B: \n\n                0x0: port is disabled \n\n                Others: reserved \n\n               Bits[10:9] determine the configuration of Port C: \n\n                0x0: port is disabled \n\n                0x2: X1 \n\n                Others: reserved \n\n               Bits[13:11] determine the configuration of Port D: \n\n                0x0: port is disabled \n\n                0x5: X2 \n\n                0x7: X4 \n\n                Others: reserved", auto: true, hex: true),
            Setting(name: "PortConfigurationFor8MSBLanes", offset: 8, length: 4, label: "Port Configuration For 8 MSB Lanes", help: "When SW DRIVER CONTROLS PORT CONFIGURATION is cleared this determines the port configuration mapping between the upper 8 MIPI lanes and the CSI receiver ports the lanes can connect to.: \n\n               Bits[3:0] determine the configuration of Port A: \n\n                0x0: port is disabled \n\n                0x4: X1 \n\n                0x5: X2 \n\n                Others: reserved \n\n               Bits[8:4] determine the configuration of Port B: \n\n                0x0: port is disabled \n\n                0x9: X2 \n\n                Others: reserved \n\n               Bits[10:9] determine the configuration of Port C: \n\n                0x0: port is disabled \n\n                0x2: X1 \n\n                Others: reserved \n\n               Bits[13:11] determine the configuration of Port D: \n\n                0x0: port is disabled \n\n                0x5: X2 \n\n                0x7: X4 \n\n                Others: reserved", auto: true, hex: true),
        ]),
        File(path: "/home/iunit/iunit_privacy_mode", alias: "IunitPrivacyControl", settings: [
            Setting(name: "PrivacyFeatureControlDisabled", offset: 0, length: 1, label: "Camera privacy feature control disabled", help: "This NVAR enables/disables the camera privacy. Enabling this NVAR means that the Camera privacy GPIO Pin value is used to mask/unmask all cameras' data from being used", auto: true),
        ]),
        File(path: "/home/policy/cfgmgr/cfg_rules", alias: "ME_CONF_WRK", settings: [
            Setting(name: "PavpSupported", offset: 344, length: 4, label: "PAVP Supported", help: "This setting determines if the Protected Audio Video Path (PAVP) feature will be permanently disabled in the FW image.", bits: 12...12, options: [0: "No", 1: "Yes"]),
            Setting(name: "IshSupported", offset: 344, length: 4, label: "Integrated Sensor Hub Supported", help: "This setting allows customers to enable / disable ISH on the platform.", bits: 10...10, options: [0: "No", 1: "Yes"]),
            Setting(name: "MEDynAppLoad", offset: 344, length: 4, label: "Firmware Dynamic Application Loader", help: "This setting enables the Dynamic Application Loader capability of the Intel(R) ME Firmware.", bits: 20...20, options: [0: "Disabled", 1: "Enabled"]),
            Setting(name: "ProcEmulation", offset: 488, length: 4, label: "Processor Emulation", help: "This setting determines processor type to be emulated on pre-production silicon.", bits: 0...3, options: [0: "No Emulation", 1: "EMULATE Intel (R) vPro (TM) capable Processor", 2: "EMULATE Intel (R) Core (TM) branded Processor", 3: "EMULATE Intel (R) Celeron (R) branded Processor", 4: "EMULATE Intel (R) Pentium (R) branded Processor", 5: "EMULATE Intel (R) Xeon E (R) branded Processor", 6: "EMULATE Intel (R) Xeon W (R) Manageability capable Processor"], auto: true),
            Setting(name: "HideMEBxFwUpdCtrl", offset: 88, length: 1, label: "Hide MEBx Firmware Update Control", help: "This setting allows customers to hide the Firmware Update option in the MEBx interface.", bits: 1...1, options: [0: "No", 1: "Yes"], auto: true),
            Setting(name: "FwUpdEnable", offset: 92, length: 4, label: "Hide MEBx Firmware Update Control", bits: 0...0, options: [0: "No", 1: "Yes"]),
            Setting(name: "AmtSupported", offset: 344, length: 4, label: "Intel(R) AMT Supported", help: "This setting allows customers to disable Intel(R) AMT on the platform and force the platform into Standard Manageability mode.", bits: 0...0, options: [0: "No", 1: "Yes"]),
            Setting(name: "NetServicesSupported", offset: 344, length: 4, label: "Intel(R) ME Network Services Supported", help: "This setting allows customers to enable / disable Intel(R) ME Network Services on the platform.  Note: If this setting is disabled Intel(R) AMT will also be disabled.", bits: 16...16, options: [0: "Yes", 1: "No"]),
            Setting(name: "MngAppSupported", offset: 344, length: 4, label: "Manageability Application Supported", help: "This setting allows customers to permenantly disable Intel(R) AMT and Standard Manageability mode on the platform.", bits: 2...2, options: [0: "No", 1: "Yes"]),
            Setting(name: "MngAppPowerUpState", offset: 404, length: 4, label: "Manageability Application initial power-up state", help: "This setting allows customers to determine the power up state for Intel(R) AMT or Standard Manageability.  Note: If this setting is disabled Intel(R) AMT or Standard Manageability can still be re-enabled through the MEBx interface.", bits: 2...2, options: [0: "Disabled", 1: "Enabled"]),
            Setting(name: "KvmSupported", offset: 344, length: 4, label: "KVM Redirection Supported", help: "This setting allows customers to enable / disable the KVM Redirection capabilities of the firmware.  Note: If this setting have been set to disabled it cannot be re-enabled once the descriptor has been locked.", bits: 18...18, options: [0: "No", 1: "Yes"]),
            Setting(name: "TlsCryptoSupport", offset: 344, length: 4, label: "Transport Layer Security Crypto Support", help: "This setting allows customers to enable / disable firmware Transport Layer Security support.  Note: If this is disabled TLS will be permanently disabled in the firmware image.", bits: 21...21, options: [0: "No", 1: "Yes"]),
            Setting(name: "MeClinkEnable", offset: 464, length: 4, label: "Intel(R) ME CLINK Signal Enabled", help: "This setting allows customers to enable / disable the Wireless LAN CLINK signal through Intel(R) ME firmware.  Note: For using Intel(R) vPro Wireless solutions this should be set to Yes.", bits: 0...0, options: [0: "No", 1: "Yes"], auto: true),
            Setting(name: "MEWlanPowerWell", offset: 200, length: 4, label: "WLAN Power Well", help: "This setting allow the customer to configure the powerwell that will be used by Intel(R) wireless lan. note: recommended setting is slp_wlan#", bits: 0...7, options: [128: "Disabled", 129: "Core Well || SLP_S3#", 130: "Primary Well || SLP_SUS#", 131: "SLP_A#", 134: "SLP_WLAN#"], auto: true),
            Setting(name: "MELanPowerWell", offset: 188, length: 4, label: "LAN Power Well", help: "This setting allows the customer to configure the powerwell that will be used by Intel(R) Integrated LAN.  Note: Recommended setting is SLP_LAN#.", bits: 0...2, options: [0: "Core Well", 1: "SUS Well", 2: "ME Well", 3: "SLP_LAN#"], auto: true),
            Setting(name: "PttSupported", offset: 344, length: 4, label: "Intel(R) PTT Supported", help: "This setting permanently disables Intel(R) PTT in the firmware image.", bits: 29...29, options: [0: "No", 1: "Yes"]),
            Setting(name: "PttPwrUpState", offset: 404, length: 4, label: "Intel(R) PTT initial power-up state", help: "This setting determines if Intel(R) PTT is enabled on platform power-up.", bits: 29...29, options: [0: "Disabled", 1: "Enabled"]),
            Setting(name: "IshPowerUpState", offset: 404, length: 4, label: "Integrated Sensor Hub Initial Power Up State", help: "This setting allows customers to determine the power up state for ISH.", bits: 10...10, options: [0: "Disabled", 1: "Enabled"]),
            Setting(name: "CryptoHwSupport", offset: 344, length: 4, label: "Crypto HW Support", help: "This setting can be used to disable crypto funtionality. This settings disables all crypto dependent features.", bits: 13...13, options: [0: "Yes", 1: "No"], auto: true),
            Setting(name: "EnableTDS", offset: 344, length: 4, label: "Enable TDS Capabilities", help: "This setting enables Intel(R) Trusted Device Setup on the platform", bits: 25...25, options: [0: "No", 1: "Yes"], auto: true),
            Setting(name: "OemTag", offset: 524, length: 4, label: "OEM Tag", help: "This is a free form 32bit field that allows the OEM to configure their own unique identifier in the firmware image.", auto: true, hex: true),
            Setting(name: "PSRSupported", offset: 344, length: 4, label: "Platform Service Record supported", help: "This setting enables the Platform Support Record capability", options: [0: "No", 1: "Yes"], auto: true),
            Setting(name: "ProcMissingDetect", offset: 212, length: 4, label: "Missing Processor Detection Alert", help: "This setting determines if missing processor detection is enabled on Desktop / Workstation platforms.  Note: This feature will only work if the platform has the appropriate glue logic present.", bits: 0...7, options: [0: "Yes", 255: "No"], auto: true),
        ]),
        File(path: "/home/policy/msrmnt_sup", alias: "MeasurmentSupport", settings: [
            Setting(name: "MeMeasuredBootState", offset: 0, length: 1, label: "Intel(R) ME Measured Boot State", help: "When measured boot is enabled firmware will use additional extended registers for all IUPs and Key Manifests that firmware loads and verifies from flash. \nNote: When measured boot is enabled any IUPs or firmware updates will require a global reset", options: [0: "Disabled", 1: "Enabled"], auto: true),
        ]),
        File(path: "/home/fwupdate/fwuoemid", alias: "OEM_ID_STRING", settings: [
            Setting(name: "FwUpdateOemId", offset: 0, length: 16, label: "Firmware Update OEM ID", help: "This setting allows configuration of an OEM unique ID to ensure that customers can only update their platform with images from the OEM of the platform.", auto: true),
        ]),
        File(path: "/home/policy/hmrfpo_state", alias: "HMRFPO_OEM_Enabled", settings: [
            Setting(name: "HmrfpoEnable", offset: 0, length: 1, label: "Intel(R) ME Region Flash Protection Override", help: "This setting enables descriptor unlock of the ME Region when the HMRFPO message is sent to firmware prior to BIOS End of POST.", options: [0: "No", 1: "Yes"]),
        ]),
        File(path: "/home/mctp/eid_db", alias: "MctpStackConfig", settings: [
            Setting(name: "MctpStackConfig", offset: 2, length: 3, label: "MCTP Stack Configuration", help: "Defines the ME's 8-bits MCTP Endpoint IDs for each SMBus physical interface (SMBus, SMLink0 and SMLink1). These values are needed for FW to communicate with MCTP end points. For each of these 3 bytes, a value of 0x00 means not used, and values 0xFF or 0x01 - 0x07 or 0x20 - 0x2F are not allowed.", auto: true, hex: true),
            Setting(name: "MctpPcieAddress", offset: 5, length: 1, label: "MCTP PCIe Address", auto: true, hex: true),
        ]),
        File(path: "/home/mctp/device_ports", alias: "MctpDevicePorts", settings: [
            Setting(name: "MctpDevicePortEc", offset: 0, length: 1, auto: true, hex: true),
            Setting(name: "MctpDevicePortSio", offset: 1, length: 1, auto: true, hex: true),
            Setting(name: "MctpDevicePortIsh", offset: 2, length: 1, auto: true, hex: true),
            Setting(name: "MctpDevicePortBmc", offset: 3, length: 1, auto: true, hex: true),
        ]),
        File(path: "/home/mctp/smt2_devices", alias: "Smt2Devices", settings: [
            Setting(name: "vproNicSMBusAddress", offset: 0, length: 1, label: "Platform vPro 2.5G Wired LAN SMBUS slave address", help: "Platform discrete NIC slave address\nNote:\n             Input needs to be in HEX format(OEM specific), e.g. 0x12", hex: true),
            Setting(name: "TypeCPortRetimerMCTPSmbusAddr", offset: 2, length: 1, label: "vPro 2.5G Wired LAN on dock slave SMBUS Address", help: "Dock NIC slave address\nNote: Input needs to\n             be in HEX format(OEM specific), e.g. 0x12", hex: true),
            Setting(name: "MctpEcAddress", offset: 4, length: 2, label: "MCTP EC Address", help: "Defines the 8-bits MCTP address and 7-bits SMBus address of the EC on SMLink0 or SMLink0b or eSPI bus. This value is needed if EC is using the MCTP protocol. The SMBus (LS byte) must be from 0x01 to 0x7f (and should not overlap with any SMBus address in PCH Strap 11).  The EID (MS byte) must be outside 0x01 through 0x07.", hex: true),
        ]),
        File(path: "/home/mctp/espi_en", alias: "EspiEn", settings: [
            Setting(name: "EspiEnabled", offset: 0, length: 1, label: "eSPI Enabled", help: "Enable Management Link over eSPI OOB. Note: in order to enable eSPI, OEM ID must be set.", options: [0: "No", 1: "Yes"]),
        ]),
        File(path: "/home/mctp/espi_devices", alias: "EspiDevices", settings: [
            Setting(name: "MctpEcAddress", offset: 4, length: 2, label: "MCTP EC Address", help: "Defines the 8-bits MCTP address and 7-bits SMBus address of the EC on SMLink0 or SMLink0b or eSPI bus. This value is needed if EC is using the MCTP protocol. The SMBus (LS byte) must be from 0x01 to 0x7f (and should not overlap with any SMBus address in PCH Strap 11).  The EID (MS byte) must be outside 0x01 through 0x07.", hex: true),
        ]),
        File(path: "/home/rbe/MANAGEABILITY_HW_DIS", alias: "MngHwDis", settings: [
            Setting(name: "MngHwStatusEfs", offset: 0, length: 1, label: "Manageability Application Hardware Status EFS", help: "This setting will disable Intel(R) AMT hardware.", options: [0: "Yes", 1: "No"]),
        ]),
        File(path: "/home/amt/rtfd/amt.wol", alias: "amt.wol", settings: [
            Setting(name: "AmtIdleTimeout", offset: 0, length: 2, label: "Intel(R) AMT Idle Timeout", help: "This setting configures the idle timeout value before Intel(R) AMT enters into an off state.", auto: true, hex: true),
        ]),
        File(path: "/home/amt/rtfd/WDResetState", alias: "AmtWdTimer", settings: [
            Setting(name: "AmtWdAutoReset", offset: 0, length: 1, label: "Intel(R) AMT Watchdog Automatic Reset Enabled", help: "This setting allows customers to enable the Intel (R) ME firmware to trigger an automatic platform reset if either the MEI or Agent Presence are in a hung state.  Note: This feature only allows one reset at a time when the watchdog expires.  After this feature has triggered a reset it must be re-armed for re-use via management console.", options: [0: "No", 1: "Yes"], auto: true),
        ]),
        File(path: "/home/amt/rtfd/rsb.state", alias: "KvmScreenBlnk", settings: [
            Setting(name: "KvmScreenBlnkEnable", offset: 0, length: 1, label: "Firmware KVM Screen Blanking", help: "This setting enables KVM Screen blanking capabilities in the firmware image.  Note: This feature is dependent on processor level support.", options: [0: "No", 1: "Yes"], auto: true),
        ]),
        File(path: "/home/amt/skip_rtfd/pki.suffix", alias: "PkiSuffix", settings: [
            Setting(name: "PkiDomainSuffix", offset: 0, length: 256, label: "PKI Domain Name Suffix", help: "This setting allows OEMs to pre-configure the Domain Name Suffix used for PKI provisioning in their firmware image.  Note: For normal out-of- box provisioning functionality this setting should be left empty.", text: true),
        ]),
        File(path: "/home/amt/skip_rtfd/pki.sec.sfx", alias: "PkiSecSfx", settings: [
            Setting(name: "PkiDomainSuffix", offset: 0, length: 256, label: "PKI Domain Name Suffix", help: "This setting allows OEMs to pre-configure the Domain Name Suffix used for PKI provisioning in their firmware image.  Note: For normal out-of- box provisioning functionality this setting should be left empty.", text: true),
        ]),
        File(path: "/home/amt/skip_rtfd/sfx.isSecure", alias: "SfxIsSecure", settings: [
            Setting(name: "SuffixIsSecure", offset: 0, length: 1),
        ]),
        File(path: "/home/amt/rtfd/PrivacyLvl", alias: "PrivacyLevel", settings: [
            Setting(name: "RedirectionPrivSecLevel", offset: 0, length: 1, label: "Redirection Privacy / Security Level", help: "This setting allows customers to configure the Privacy and Security level for redirection operations.  Default enables all redirection ports (User consent is configurable).  Enhanced enables all redirection ports (User consent is required and cannot be disabled).  Extreme disables all redirection capabilities.", options: [1: "Default", 2: "Enhanced", 3: "Extreme"]),
        ]),
        File(path: "/home/bup/si_features", alias: "KernFixedData", settings: [
            Setting(name: "DbgOverridePreProdSi", offset: 12, length: 4, label: "Debug Override Pre-Production Silicon", help: "Allows the OEM to control FW features to assist with pre-production platform debugging.  This control has no effect if used on production silicon.  Note: Certain options will do not work when the descriptor is locked (See FW Bring-up Guide for setting details).", auto: true, hex: true),
            Setting(name: "DbgOverrideProdSi", offset: 16, length: 4, label: "Debug Override Production Silicon", help: "Allows the OEM to control FW features to assist with production platform debugging.  Note: Certain options will do not work when the descriptor is locked (See FW Bring-up Guide for setting details).", auto: true, hex: true),
        ]),
        File(path: "/home/secureboot/brm_cfg", alias: "BrmEn", settings: [
            Setting(name: "BiosRedAssistance", offset: 0, length: 1, label: "BIOS Redundancy Assistance", help: "In case of BIOS boot failure, CSME will configure the platform to boot with backup BIOS using Top Swap. Note: This option is only available when Boot Guard is enabled.", options: [0: "Disabled", 1: "Enabled"], auto: true),
        ]),
        File(path: "/home/fwupdate/fwutcss", alias: "TCSS_PartialUpdate", settings: [
            Setting(name: "TcssPartialUpdateEn", offset: 0, length: 1, label: "Tcss - Partial Update Enabled", help: "This setting enables partial update for TCSS partitions", options: [0: "Disabled", 1: "Enabled"], auto: true),
        ]),
        File(path: "/home/tcss/tcss_ctrl", alias: "TcssControl", settings: [
            Setting(name: "TcssAuthenticateEn", offset: 0, length: 1, label: "Type-C SubSystem Authentication Enabled", help: "This setting enables / disables firmware authentication for the Type-C Subsystem on power-up", options: [0: "Yes", 1: "No"], auto: true),
        ]),
        File(path: "/home/amt/skip_rtfd/ncsi", alias: "AmtNetworkConfiguration", settings: [
            Setting(name: "vproNicSMBusAddress", offset: 5, length: 1, label: "Platform vPro 2.5G Wired LAN SMBUS slave address", help: "Platform discrete NIC slave address\nNote: Input needs to be in HEX format(OEM specific), e.g. 0x12", hex: true),
            Setting(name: "vproNicEnabled", offset: 0, length: 1, label: "Platform vPro 2.5G Wired LAN Enabled", help: "YES = Discrete NIC enabled in platform\nNO = Integrated GBE LAN enabled in platform", bits: 0...0, options: [0: "No", 1: "Yes"], auto: true),
            Setting(name: "vproDockEnabled", offset: 0, length: 1, label: "vPro Over Thunderbolt Dock Enabled", help: "YES = Enables communication with, vPro supporting NIC, via TBT dock\nNO = No support for vPro dock solution", bits: 1...1, options: [0: "No", 1: "Yes"], auto: true),
            Setting(name: "TypeCPortRetimerMCTPSmbusAddr", offset: 6, length: 1, label: "vPro 2.5G Wired LAN on dock slave SMBUS Address", help: "Dock NIC slave address\nNote: Input needs to be in HEX format(OEM specific), e.g. 0x12", hex: true),
            Setting(name: "ThunderboltPort1SMBUSAddress", offset: 1, length: 1, label: "Thunderbolt Port1 SMBUS Address", help: "This setting configures the Intel(R) SMBus I2C Address.\nNote: Input needs to be in HEX format(OEM specific), e.g. 0x12", hex: true),
            Setting(name: "ThunderboltPort2SMBUSAddress", offset: 2, length: 1, label: "Thunderbolt Port2 SMBUS Address", help: "This setting configures the Intel(R) SMBus I2C\n             Address.\nNote: Input needs to be in HEX format(OEM specific), e.g. 0x12", hex: true),
            Setting(name: "ThunderboltPort3SMBUSAddress", offset: 3, length: 1, label: "Thunderbolt Port3 SMBUS Address", help: "This setting configures the Intel(R) SMBus I2C Address.\nNote: Input needs to be in HEX format(OEM specific), e.g. 0x12", hex: true),
            Setting(name: "ThunderboltPort4SMBUSAddress", offset: 4, length: 1, label: "Thunderbolt Port4 SMBUS Address", help: "This setting configures the Intel(R) SMBus I2C\n             Address.\nNote: Input needs to be in HEX format(OEM specific), e.g. 0x12", hex: true),
        ]),
        File(path: "/home/bup/bup_sku/hw_binding", alias: "HwBinding", settings: [
            Setting(name: "HwBindingEn", offset: 0, length: 1, label: "Hardware Binding Enabled", help: "This setting configures the FPF Hardware and RPMC / RPMB binding behavior for the platform image.\nIf this setting is enabled FPF Hardware and RPMC / RPMB binding behavior will occur when platform close manufacturing flow is executed with Intel(R) FPT. \nIf this setting is disabled FPF Hardware and RPMC / RPMB binding behavior will not take place when close manufacturing flow is executed.\nNote: For Revenue parts this setting will be ignored and FPF Hardware and RPMC / RPMB binding behavior will take place when close manufacturing flow is executed.", options: [0: "Disabled", 1: "Enabled"], auto: true),
        ]),
        File(path: "/home/mca/icps", alias: "icps", settings: [
            Setting(name: "icpsSwSkuing", offset: 0, length: 8, label: "Intel(R) ICPS SW SKUing Eligible", help: "Set to enabled when Intel Connectivity Performance Suite is licensed on this platform", bits: 0...0, options: [0: "No", 1: "Yes"], auto: true),
            Setting(name: "icmEntitlement", offset: 0, length: 8, label: "Intel(R) ICM Entitlement", help: "Set to enabled when Intel Connectivity Performance Suite is licensed on this platform.", bits: 31...31, options: [0: "No", 1: "Yes"]),
        ]),
        File(path: "/home/policy/Bist/auto_config", alias: "BistMeAutoBistConfAndStatus", settings: [
            Setting(name: "FwAutoBist", offset: 0, length: 4, label: "Automatic Built in Self Test", help: "This setting enables the firmware Automatic Built in Self Test which is executed during first platform boot after initial image flashing.", bits: 0...0, options: [0: "Disabled", 1: "Enabled"], auto: true),
        ]),
        File(path: "/home/hotham/dbg_dam_req", alias: "Dam", settings: [
            Setting(name: "DelayedAuthMode", offset: 0, length: 1, label: "Delayed Authentication Mode Enabled", help: "This setting enables Delayed Authentication Mode on the platform.", options: [0: "No", 1: "Yes"], auto: true),
        ]),
        File(path: "/home/ptt/ptt_smx_disable", alias: "PttSmxSupport", settings: [
            Setting(name: "SmxSupport", offset: 0, length: 1, label: "SMx State", bits: 0...0, options: [0: "Enabled", 1: "Disabled"], auto: true),
            Setting(name: "Rsa1KSupport", offset: 0, length: 1, label: "Rsa 1K State", bits: 1...1, options: [0: "Enabled", 1: "Disabled"], auto: true),
        ]),
        File(path: "/home/upid/platform_id_support", alias: "UpidPlatformIdSupport", settings: [
            Setting(name: "UniquePlatformIdSupportedFeature", offset: 0, length: 1, label: "UPID Supported", help: "This setting allows OEM to create their own unique platform identifier. If this setting is enabled, the below OEM ID should be set.", bits: 0...0, options: [0: "No", 1: "Yes"], auto: true),
        ]),
        File(path: "/home/rbe/binding_sig_type", alias: "BINDING_SIG_TYPE", settings: [
            Setting(name: "BindingSigType", offset: 0, length: 1, label: "Binding Signature Type", help: "Defines the type of the Binding Signature that will be supported by FW.", bits: 0...0, options: [0: "PCH Based Signature", 1: "IFP based Signature"], auto: true),
        ]),
        File(path: "/home/mca/host_sw_sqnc_mode", alias: "HostSwSequencingMode", settings: [
            Setting(name: "SpiSwSeqEnable", offset: 0, length: 1, label: "SPI Software Sequencing Enabled", help: "This setting will enable SPI software sequencing, in order to allow the host to write PCH binding information. Note: This setting is disabled b default and can be enabled until EOM.", bits: 0...0, options: [0: "No", 1: "Yes"], auto: true),
        ]),
        File(path: "/home/psr/genesis_info", alias: "psr_genesis_info", settings: [
            Setting(name: "OEMInfo", offset: 4, length: 64, label: "OEM Name", help: "Genesis Record should include the OEM information feed from OEM specified information during manufacturing", auto: true, text: true),
            Setting(name: "OEMMakeInfo", offset: 68, length: 64, label: "OEM Make", help: "Genesis Record should include the OEM Make information feed from OEM specified information during manufacturing", auto: true, text: true),
            Setting(name: "OEMModelInfo", offset: 132, length: 64, label: "OEM Model", help: "Genesis Record should include the OEM Model information feed from OEM specified information during manufacturing", auto: true, text: true),
            Setting(name: "MfgCountryOfOrigin", offset: 196, length: 64, label: "Country of Manufacturer", help: "Genesis Record should include the Manufacturing Country of Origin feed from OEM specified information", auto: true, text: true),
            Setting(name: "OEMDataStore", offset: 260, length: 1024, label: "OEM Data", help: "Genesis Record should include the OEM Data Store binary for OEM defined information", auto: true),
        ]),
        File(path: "/home/mctp/ec_oob_smbus_addr", alias: "mctp_ec_oob_smbus_addr", settings: [
            Setting(name: "ECOOBSmbusAddr", offset: 0, length: 1, label: "eSPI OOB EC SMBUs Address", help: "This setting determines the SMBUS address for eSPI OOB to be handled by EC.", auto: true, hex: true),
        ]),
        File(path: "/home/mctp/smt3_devices", alias: "Smt3Devices", settings: [
            Setting(name: "MctpEcAddress", offset: 4, length: 2, label: "MCTP EC Address", help: "Defines the 8-bits MCTP address and 7-bits SMBus address of the EC on SMLink2 or eSPI bus. This value is needed if EC is using the MCTP protocol. The SMBus (LS byte) must be from 0x01 to 0x7f (and should not overlap with any SMBus address in PCH Strap 11).  The EID (MS byte) must be outside 0x01 through 0x07.", hex: true),
        ]),
        ])
}
