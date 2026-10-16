// The CSME 16 map of the ME configuration — emitted by
// `Skills/me-eom-structures/scripts/mfit_map.py` from Flash Image Tool
// 16.0.15.1662's own settings database, which is the build that wrote the CSME 16
// images this was verified against. Offsets, bits, option labels and the
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
        name: "CSME 16 (Flash Image Tool 16.0.15.1662)",
        files: [
        File(path: "/home/mca/eom_config", alias: "EOM_Config", settings: [
            Setting(name: "EomFirstBootEnabled", offset: 0, length: 2, bits: 0...0, options: [0: "No", 1: "Yes"]),
            Setting(name: "FlexibleEomSettings", offset: 0, length: 2, bits: 1...2, options: [0: "Lock Descriptor and OEM Configs", 1: "Lock OEM Configs Only", 2: "Lock Descriptor Only", 3: "Do not lock Descriptor and OEM Configs"]),
        ]),
        File(path: "/home/mca/eom", alias: "EOM", settings: [
            Setting(name: "EomFirstBootEnabled", offset: 0, length: 1, options: [0: "No", 1: "Yes"]),
        ]),
        File(path: "/home/mca/mca_oem_version", alias: "EOM_VERSION", settings: [
            Setting(name: "OemFwVersion", offset: 0, length: 8, auto: true, hex: true),
        ]),
        File(path: "/home/pavp/hdcp_ports", alias: "PavpHdcp", settings: [
            Setting(name: "Hdcp5kedisp1", offset: 0, length: 1, options: [0: "None", 1: "PortA", 2: "PortB", 4: "PortC"]),
        ]),
        File(path: "/home/smbus/smlink_bus", alias: "SmlinkBus", settings: [
            Setting(name: "SmlinkBusSelection", offset: 0, length: 1, options: [0: "SMLink0", 1: "SMLink0B"]),
        ]),
        File(path: "/home/iunit/iunit_oem_cfg", alias: "IUnitOemCfg", settings: [
            Setting(name: "SecureTouch", offset: 18, length: 1, options: [0: "Disabled", 1: "Enabled"], auto: true),
            Setting(name: "FWSecureMode", offset: 17, length: 1, options: [0: "Disabled", 1: "Enabled"], auto: true),
            Setting(name: "SecureTouchCameraMask", offset: 0, length: 4, auto: true, hex: true),
            Setting(name: "RomTraceEnable", offset: 16, length: 1, options: [0: "Disabled", 1: "Enabled"], auto: true),
            Setting(name: "PortConfigurationFor8LSBLanes", offset: 4, length: 4, auto: true, hex: true),
            Setting(name: "PortConfigurationFor8MSBLanes", offset: 8, length: 4, auto: true, hex: true),
        ]),
        File(path: "/home/iunit/iunit_privacy_mode", alias: "IunitPrivacyControl", settings: [
            Setting(name: "PrivacyFeatureControlDisabled", offset: 0, length: 1, auto: true),
        ]),
        File(path: "/home/policy/cfgmgr/cfg_rules", alias: "ME_CONF_WRK", settings: [
            Setting(name: "PavpSupported", offset: 344, length: 4, bits: 12...12, options: [0: "No", 1: "Yes"]),
            Setting(name: "IshSupported", offset: 344, length: 4, bits: 10...10, options: [0: "No", 1: "Yes"]),
            Setting(name: "MEDynAppLoad", offset: 344, length: 4, bits: 20...20, options: [0: "Disabled", 1: "Enabled"]),
            Setting(name: "ProcEmulation", offset: 488, length: 4, bits: 0...3, options: [0: "No Emulation", 1: "EMULATE Intel (R) vPro (TM) capable Processor", 2: "EMULATE Intel (R) Core (TM) branded Processor", 3: "EMULATE Intel (R) Celeron (R) branded Processor", 4: "EMULATE Intel (R) Pentium (R) branded Processor", 5: "EMULATE Intel (R) Xeon E (R) branded Processor", 6: "EMULATE Intel (R) Xeon W (R) Manageability capable Processor"], auto: true),
            Setting(name: "HideMEBxFwUpdCtrl", offset: 88, length: 1, bits: 1...1, options: [0: "No", 1: "Yes"], auto: true),
            Setting(name: "FwUpdEnable", offset: 92, length: 4, bits: 0...0, options: [0: "No", 1: "Yes"]),
            Setting(name: "AmtSupported", offset: 344, length: 4, bits: 0...0, options: [0: "No", 1: "Yes"]),
            Setting(name: "NetServicesSupported", offset: 344, length: 4, bits: 16...16, options: [0: "Yes", 1: "No"]),
            Setting(name: "MngAppSupported", offset: 344, length: 4, bits: 2...2, options: [0: "No", 1: "Yes"]),
            Setting(name: "MngAppPowerUpState", offset: 404, length: 4, bits: 2...2, options: [0: "Disabled", 1: "Enabled"]),
            Setting(name: "KvmSupported", offset: 344, length: 4, bits: 18...18, options: [0: "No", 1: "Yes"]),
            Setting(name: "TlsCryptoSupport", offset: 344, length: 4, bits: 21...21, options: [0: "No", 1: "Yes"]),
            Setting(name: "MeClinkEnable", offset: 464, length: 4, bits: 0...0, options: [0: "No", 1: "Yes"], auto: true),
            Setting(name: "MEWlanPowerWell", offset: 200, length: 4, bits: 0...7, options: [128: "Disabled", 129: "Core Well || SLP_S3#", 130: "Primary Well || SLP_SUS#", 131: "SLP_A#", 134: "SLP_WLAN#"], auto: true),
            Setting(name: "MELanPowerWell", offset: 188, length: 4, bits: 0...2, options: [0: "Core Well", 1: "SUS Well", 2: "ME Well", 3: "SLP_LAN#"], auto: true),
            Setting(name: "PttSupported", offset: 344, length: 4, bits: 29...29, options: [0: "No", 1: "Yes"]),
            Setting(name: "PttPwrUpState", offset: 404, length: 4, bits: 29...29, options: [0: "Disabled", 1: "Enabled"]),
            Setting(name: "IshPowerUpState", offset: 404, length: 4, bits: 10...10, options: [0: "Disabled", 1: "Enabled"]),
            Setting(name: "CryptoHwSupport", offset: 344, length: 4, bits: 13...13, options: [0: "Yes", 1: "No"], auto: true),
            Setting(name: "EnableTDS", offset: 344, length: 4, bits: 25...25, options: [0: "No", 1: "Yes"], auto: true),
            Setting(name: "OemTag", offset: 524, length: 4, auto: true, hex: true),
            Setting(name: "ProcMissingDetect", offset: 212, length: 4, bits: 0...7, options: [0: "Yes", 255: "No"], auto: true),
        ]),
        File(path: "/home/policy/msrmnt_sup", alias: "MeasurmentSupport", settings: [
            Setting(name: "MeMeasuredBootState", offset: 0, length: 1, options: [0: "Disabled", 1: "Enabled"], auto: true),
        ]),
        File(path: "/home/fwupdate/fwuoemid", alias: "OEM_ID_STRING", settings: [
            Setting(name: "FwUpdateOemId", offset: 0, length: 16, auto: true),
        ]),
        File(path: "/home/mctp/eid_db", alias: "MctpStackConfig", settings: [
            Setting(name: "MctpStackConfig", offset: 2, length: 3, auto: true, hex: true),
            Setting(name: "MctpPcieAddress", offset: 5, length: 1, auto: true, hex: true),
        ]),
        File(path: "/home/mctp/device_ports", alias: "MctpDevicePorts", settings: [
            Setting(name: "MctpDevicePortEc", offset: 0, length: 1, auto: true, hex: true),
            Setting(name: "MctpDevicePortSio", offset: 1, length: 1, auto: true, hex: true),
            Setting(name: "MctpDevicePortIsh", offset: 2, length: 1, auto: true, hex: true),
            Setting(name: "MctpDevicePortBmc", offset: 3, length: 1, auto: true, hex: true),
        ]),
        File(path: "/home/mctp/smt2_devices", alias: "Smt2Devices", settings: [
            Setting(name: "vproNicSMBusAddress", offset: 0, length: 1, hex: true),
            Setting(name: "TypeCPortRetimerMCTPSmbusAddr", offset: 2, length: 1, hex: true),
            Setting(name: "MctpEcAddress", offset: 4, length: 2, hex: true),
        ]),
        File(path: "/home/mctp/espi_en", alias: "EspiEn", settings: [
            Setting(name: "EspiEnabled", offset: 0, length: 1, options: [0: "No", 1: "Yes"]),
        ]),
        File(path: "/home/mctp/espi_devices", alias: "EspiDevices", settings: [
            Setting(name: "MctpEcAddress", offset: 4, length: 2, hex: true),
        ]),
        File(path: "/home/amt/rtfd/rsb.state", alias: "KvmScreenBlnk", settings: [
            Setting(name: "KvmScreenBlnkEnable", offset: 0, length: 1, options: [0: "No", 1: "Yes"], auto: true),
        ]),
        File(path: "/home/amt/skip_rtfd/pki.suffix", alias: "PkiSuffix", settings: [
            Setting(name: "PkiDomainSuffix", offset: 0, length: 256, text: true),
        ]),
        File(path: "/home/amt/skip_rtfd/pki.sec.sfx", alias: "PkiSecSfx", settings: [
            Setting(name: "PkiDomainSuffix", offset: 0, length: 256, text: true),
        ]),
        File(path: "/home/amt/skip_rtfd/sfx.isSecure", alias: "SfxIsSecure", settings: [
            Setting(name: "SuffixIsSecure", offset: 0, length: 1),
        ]),
        File(path: "/home/bup/si_features", alias: "KernFixedData", settings: [
            Setting(name: "DbgOverridePreProdSi", offset: 12, length: 4, auto: true, hex: true),
            Setting(name: "DbgOverrideProdSi", offset: 16, length: 4, auto: true, hex: true),
        ]),
        File(path: "/home/amt/skip_rtfd/ncsi", alias: "AmtNetworkConfiguration", settings: [
            Setting(name: "vproNicSMBusAddress", offset: 5, length: 1, hex: true),
            Setting(name: "vproNicEnabled", offset: 0, length: 1, bits: 0...0, options: [0: "No", 1: "Yes"], auto: true),
            Setting(name: "vproDockEnabled", offset: 0, length: 1, bits: 1...1, options: [0: "No", 1: "Yes"], auto: true),
            Setting(name: "TypeCPortRetimerMCTPSmbusAddr", offset: 6, length: 1, hex: true),
            Setting(name: "ThunderboltPort1SMBUSAddress", offset: 1, length: 1, hex: true),
            Setting(name: "ThunderboltPort2SMBUSAddress", offset: 2, length: 1, hex: true),
            Setting(name: "ThunderboltPort3SMBUSAddress", offset: 3, length: 1, hex: true),
            Setting(name: "ThunderboltPort4SMBUSAddress", offset: 4, length: 1, hex: true),
        ]),
        File(path: "/home/mca/icps", alias: "icps", settings: [
        ]),
        File(path: "/home/policy/Bist/auto_config", alias: "BistMeAutoBistConfAndStatus", settings: [
            Setting(name: "FwAutoBist", offset: 0, length: 4, bits: 0...0, options: [0: "Disabled", 1: "Enabled"], auto: true),
        ]),
        File(path: "/home/ptt/ptt_smx_disable", alias: "PttSmxSupport", settings: [
            Setting(name: "SmxSupport", offset: 0, length: 1, bits: 0...0, options: [0: "Enabled", 1: "Disabled"], auto: true),
            Setting(name: "Rsa1KSupport", offset: 0, length: 1, bits: 1...1, options: [0: "Enabled", 1: "Disabled"], auto: true),
        ]),
        File(path: "/home/upid/platform_id_support", alias: "UpidPlatformIdSupport", settings: [
            Setting(name: "UniquePlatformIdSupportedFeature", offset: 0, length: 1, bits: 0...0, options: [0: "No", 1: "Yes"], auto: true),
        ]),
        File(path: "/home/mctp/smt3_devices", alias: "Smt3Devices", settings: [
            Setting(name: "MctpEcAddress", offset: 4, length: 2, hex: true),
        ]),
        ])
}
