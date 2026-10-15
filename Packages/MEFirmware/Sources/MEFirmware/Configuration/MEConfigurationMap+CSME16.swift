// The CSME 16 map of the ME configuration — curated from Flash Image Tool
// 16.0.15.1662's settings database, the build that wrote the CSME 16 images this
// was verified against, with the paths, offsets and option labels it gives.
//
// A generation's map lives in a file of its own: see `MEConfigurationMap.swift`
// for what a map is and why each generation has its own.

import Foundation

extension MEConfigurationMap {
    /// The ME 16 configuration, as MFIT 16 lays it out. The files stand in the
    /// order a bench reads them: the ME configuration itself first, then the
    /// policy and power settings an edit is usually about.
    public static let csme16 = MEConfigurationMap(
        name: "CSME 16 (Flash Image Tool 16.0.15.1662)",
        files: [
        File(path: "/home/mca/eom_config", alias: "EOM_Config", settings: [
            Setting(name: "EomFirstBootEnabled", offset: 0, length: 2, bits: 0...0),
            Setting(name: "FlexibleEomSettings", offset: 0, length: 2, bits: 1...2,
                    options: [0: "Lock Descriptor and OEM Configs",
                              1: "Lock OEM Configs Only",
                              2: "Lock Descriptor Only",
                              3: "Do not lock Descriptor and OEM Configs"]),
        ]),
        File(path: "/home/mca/eom", alias: "EOM", settings: [
            Setting(name: "EomFirstBootEnabled", offset: 0, length: 1),
        ]),
        File(path: "/home/mca/mca_oem_version", alias: "EOM_VERSION", settings: [
            Setting(name: "OemFwVersion", offset: 0, length: 8, auto: true),
        ]),
        File(path: "/home/pavp/hdcp_ports", alias: "PavpHdcp", settings: [
            Setting(name: "Hdcp5kedisp1", offset: 0, length: 1,
                    options: [0x0: "None", 0x1: "PortA", 0x2: "PortB", 0x4: "PortC"]),
        ]),
        File(path: "/home/smbus/smlink_bus", alias: "SmlinkBus", settings: [
            Setting(name: "SmlinkBusSelection", offset: 0, length: 1,
                    options: [0x0: "SMLink0", 0x1: "SMLink0B"]),
        ]),
        File(path: "/home/iunit/iunit_oem_cfg", alias: "IUnitOemCfg", settings: [
            Setting(name: "SecureTouchCameraMask", offset: 0, length: 4, auto: true),
            Setting(name: "FWSecureMode", offset: 17, length: 1, auto: true),
            Setting(name: "SecureTouch", offset: 18, length: 1, auto: true),
        ]),
        File(path: "/home/policy/cfgmgr/cfg_rules", alias: "ME_CONF_WRK", settings: [
            Setting(name: "HideMEBxFwUpdCtrl", offset: 88, length: 1, bits: 1...1, auto: true),
            Setting(name: "FwUpdEnable", offset: 92, length: 4, bits: 0...0),
            Setting(name: "MELanPowerWell", offset: 188, length: 4, bits: 0...2,
                    options: [0: "Core Well", 1: "SUS Well", 2: "ME Well", 3: "SLP_LAN#"],
                    auto: true),
            Setting(name: "MEWlanPowerWell", offset: 200, length: 4, bits: 0...7,
                    options: [0x80: "Disabled", 0x81: "Core Well || SLP_S3#",
                              0x82: "Primary Well || SLP_SUS#", 0x83: "SLP_A#",
                              0x86: "SLP_WLAN#"],
                    auto: true),
            Setting(name: "ProcMissingDetect", offset: 212, length: 4, bits: 0...7,
                    options: [0xFF: "No", 0x00: "Yes"],
                    auto: true),
            Setting(name: "AmtSupported", offset: 344, length: 4, bits: 0...0),
            Setting(name: "MngAppSupported", offset: 344, length: 4, bits: 2...2),
            Setting(name: "IshSupported", offset: 344, length: 4, bits: 10...10),
            Setting(name: "PavpSupported", offset: 344, length: 4, bits: 12...12),
            Setting(name: "CryptoHwSupport", offset: 344, length: 4, bits: 13...13, auto: true),
            Setting(name: "NetServicesSupported", offset: 344, length: 4, bits: 16...16),
            Setting(name: "KvmSupported", offset: 344, length: 4, bits: 18...18),
            Setting(name: "TlsCryptoSupport", offset: 344, length: 4, bits: 21...21),
            Setting(name: "EnableTDS", offset: 344, length: 4, bits: 25...25, auto: true),
            Setting(name: "PttSupported", offset: 344, length: 4, bits: 29...29),
            Setting(name: "MngAppPowerUpState", offset: 404, length: 4, bits: 2...2),
            Setting(name: "IshPowerUpState", offset: 404, length: 4, bits: 10...10),
            Setting(name: "PttPwrUpState", offset: 404, length: 4, bits: 29...29),
            Setting(name: "MeClinkEnable", offset: 464, length: 4, bits: 0...0, auto: true),
            Setting(name: "ProcEmulation", offset: 488, length: 4, bits: 0...3,
                    options: [0: "No Emulation",
                              1: "EMULATE Intel (R) vPro (TM) capable Processor",
                              2: "EMULATE Intel (R) Core (TM) branded Processor",
                              3: "EMULATE Intel (R) Celeron (R) branded Processor",
                              4: "EMULATE Intel (R) Pentium (R) branded Processor",
                              5: "EMULATE Intel (R) Xeon E (R) branded Processor",
                              6: "EMULATE Intel (R) Xeon W (R) Manageability capable Processor"],
                    auto: true),
            Setting(name: "OemTag", offset: 524, length: 4, auto: true),
        ]),
    ])
}
