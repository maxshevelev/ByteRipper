// The CSME 13 map of the ME configuration — emitted by
// `Skills/me-eom-structures/scripts/fit_map.py` from Flash Image Tool 13.0's
// own layout documents (the icl_lp platform of ME 13).
// Offsets, bits, the tool's own name for each setting (`label`), its option
// labels and the file paths are FIT's, copied out of its
// `ProcessNvar` bindings and value dictionaries; nothing here is read out of a
// dump. FIT 13.0 marks no setting `Auto` — it has no such attribute — so no
// setting here carries that mark.
//
// A generation's map lives in a file of its own: see `MEConfigurationMap.swift`
// for what a map is and why each generation has its own.

import Foundation

extension MEConfigurationMap {
    /// The ME 13 configuration, as FIT 13.0 lays it out. The files stand in the
    /// order a bench reads them, and the rest in the tool's own order.
    public static let csme13 = MEConfigurationMap(
        name: "CSME 13 (Flash Image Tool 13.0)",
        files: [
        File(path: "/home/mca/eom_config", alias: "EOM_Config", settings: [
            Setting(name: "EomFirstBootEnabled", offset: 0, length: 1, label: "EOM on First Boot Enabled", bits: 0...0, options: [0: "No", 1: "Yes"]),
            Setting(name: "FlexibleEomSettings", offset: 0, length: 1, label: "Flexible EOM setting options", bits: 1...2, options: [0: "Lock Descriptor and OEM Configs", 1: "Lock OEM Configs Only", 2: "Lock Descriptor Only", 3: "Do not lock Descriptor and OEM Configs"]),
        ]),
        File(path: "/home/mca/eom", alias: "EOM", settings: [
            Setting(name: "EOM", offset: 0, length: 1, hex: true),
            Setting(name: "EomFirstBootEnabled", offset: 0, length: 1, label: "EOM on First Boot Enabled", options: [0: "No", 1: "Yes"]),
        ]),
        File(path: "/home/policy/cfgmgr/cfg_rules", alias: "ME_CONF_WRK", settings: [
            Setting(name: "AmtSupported", offset: 344, length: 1, label: "Intel(R) AMT Supported", bits: 0...0, options: [0: "No", 1: "Yes"]),
            Setting(name: "CryptoHwSupport", offset: 344, length: 2, label: "Crypto HW Support", bits: 13...13, options: [0: "Yes", 1: "No"]),
            Setting(name: "EnableTDS", offset: 344, length: 4, label: "Enable TDS Capabilities", bits: 25...25, options: [0: "No", 1: "Yes"]),
            Setting(name: "FID_INT_TOUCH", offset: 344, length: 1, bits: 4...4, options: [0: "No", 1: "Yes"]),
            Setting(name: "FID_ISH", offset: 344, length: 2, bits: 10...10, options: [0: "No", 1: "Yes"]),
            Setting(name: "FID_MEDAL", offset: 344, length: 3, bits: 20...20, options: [0: "Disabled", 1: "Enabled"]),
            Setting(name: "FID_PAV", offset: 344, length: 2, bits: 12...12, options: [0: "No", 1: "Yes"]),
            Setting(name: "IshPowerUpState", offset: 404, length: 2, label: "Integrated Sensor Hub Initial Power State", bits: 10...10, options: [0: "Disabled", 1: "Enabled"]),
            Setting(name: "MELanPowerWell", offset: 188, length: 1, label: "LAN Power Well", bits: 0...2, options: [0: "Core Well", 1: "SUS Well", 2: "ME Well", 3: "SLP_LAN#"]),
            Setting(name: "MEWlanPowerWell", offset: 200, length: 1, label: "WLAN Power Well", bits: 0...7, options: [128: "Disabled", 129: "Core Well || SLP_S3#", 130: "Primary Well || SLP_SUS#", 131: "ME Well || SLP_A#", 134: "SLP_WLAN#"]),
            Setting(name: "MeClinkEnable", offset: 464, length: 1, label: "Intel(R) ME CLINK Signal Enabled", bits: 0...0, options: [0: "No", 1: "Yes"]),
            Setting(name: "MngAppPowerUpState", offset: 404, length: 1, label: "Manageability Application initial power-up state", bits: 2...2, options: [0: "Disabled", 1: "Enabled"]),
            Setting(name: "MngAppSupported", offset: 344, length: 1, label: "Manageability Application Supported", bits: 2...2, options: [0: "No", 1: "Yes"]),
            Setting(name: "NetServicesSupported", offset: 344, length: 3, label: "Intel(R) ME Network Services Supported", bits: 16...16, options: [0: "Yes", 1: "No"]),
            Setting(name: "ProcEmulation", offset: 488, length: 1, label: "Processor Emulation", bits: 0...3, options: [0: "No Emulation", 1: "EMULATE Intel (R) vPro (TM) capable Processor", 2: "EMULATE Intel (R) Core (TM) branded Processor", 3: "EMULATE Intel (R) Celeron (R) branded Processor", 4: "EMULATE Intel (R) Pentium (R) branded Processor", 5: "EMULATE Intel (R) Xeon (R) branded Processor", 6: "EMULATE Intel (R) Xeon (R) Manageability capable Processor"]),
            Setting(name: "PttPwrUpState", offset: 404, length: 4, label: "Intel(R) PTT initial power-up state", bits: 29...29, options: [0: "Disabled", 1: "Enabled"]),
            Setting(name: "PttSupported", offset: 344, length: 4, label: "Intel(R) PTT Supported", bits: 29...29, options: [0: "No", 1: "Yes"]),
            Setting(name: "TouchEnabled", offset: 344, length: 1, label: "Intel(R) Precise Touch and Stylus Enabled", bits: 4...4, options: [0: "No", 1: "Yes"]),
        ]),
        File(path: "/home/bup/si_features", alias: "KernFixedData", settings: [
            Setting(name: "DbgOverridePreProdSi", offset: 12, length: 4, label: "Debug Override Pre-Production Silicon", hex: true),
            Setting(name: "DbgOverrideProdSi", offset: 16, length: 4, label: "Debug Override Production Silicon", hex: true),
        ]),
        File(path: "/home/iunit/sec_ctl", alias: "IUnitSecCtl", settings: [
            Setting(name: "FWSecureMode", offset: 1, length: 1, label: "FW Secure Mode", options: [0: "Disabled", 1: "Enabled"]),
            Setting(name: "RomTraceEnable", offset: 0, length: 1, label: "IPU Debugging Enabled", options: [0: "Disabled", 1: "Enabled"]),
        ]),
        File(path: "/home/loadmgr/arben", alias: "BootGuardArb", settings: [
            Setting(name: "IomArbEnable", offset: 0, length: 1, label: "IO Manageability Engine Manifest Anti-Rollback Enabled", bits: 6...6, options: [0: "No", 1: "Yes"]),
            Setting(name: "NphyPhyArbEnable", offset: 0, length: 1, label: "NPHY Manifest Anti-Rollback Enabled", bits: 7...7, options: [0: "No", 1: "Yes"]),
            Setting(name: "TbtArbEnable", offset: 0, length: 2, label: "Thunderbolt(TM) Manifest Anti-Rollback Enabled ", bits: 8...8, options: [0: "No", 1: "Yes"]),
        ]),
        File(path: "/home/mctp/smt2_devices", alias: "Smt2Devices", settings: [
            Setting(name: "MctpEcAddress", offset: 4, length: 2, label: "MCTP EC Address", hex: true),
        ]),
        File(path: "/home/iunit/port_cfg", alias: "IUnitPortCfg", settings: [
            Setting(name: "PortConfigurationFor8LSBLanes", offset: 0, length: 2, label: "Port Configuration For 8 LSB Lanes", hex: true),
            Setting(name: "PortConfigurationFor8MSBLanes", offset: 4, length: 2, label: "Port Configuration For 8 MSB Lanes", hex: true),
            Setting(name: "SWDriverControlsPortConfiguration", offset: 8, length: 1, label: "SW Driver Controls Port Configuration ", options: [0: "Disabled", 1: "Enabled"]),
        ]),
        File(path: "/home/iunit/sec_touch", alias: "IUnitSecTouch", settings: [
            Setting(name: "SecureTouch", offset: 0, length: 1, label: "Secure Touch", options: [0: "Disabled", 1: "Enabled"]),
        ]),
        File(path: "/home/iunit/camera_mask", alias: "IUnitCameraMask", settings: [
            Setting(name: "SecureTouchCameraMask", offset: 0, length: 1, label: "Secure Touch and Camera Mask", hex: true),
        ]),
        ])
}
