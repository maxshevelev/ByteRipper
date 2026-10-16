// The CSME 15 map of the ME configuration — emitted by
// `Skills/me-eom-structures/scripts/fit_map.py` from Flash Image Tool 15.0's
// own layout documents (the tgp_lp platform of ME 15).
// Offsets, bits, option labels and file paths are FIT's, copied out of its
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
            Setting(name: "EomFirstBootEnabled", offset: 0, length: 1, bits: 0...0, options: [0: "No", 1: "Yes"]),
            Setting(name: "FlexibleEomSettings", offset: 0, length: 1, bits: 1...2, options: [0: "Lock Descriptor and OEM Configs", 1: "Lock OEM Configs Only", 2: "Lock Descriptor Only", 3: "Do not lock Descriptor and OEM Configs"]),
        ]),
        File(path: "/home/mca/eom", alias: "EOM", settings: [
            Setting(name: "EomFirstBootEnabled", offset: 0, length: 1, options: [0: "No", 1: "Yes"]),
        ]),
        File(path: "/home/smbus/smlink_bus", alias: "SmlinkBus", settings: [
            Setting(name: "SmlinkBusSelection", offset: 0, length: 1, options: [0: "SMLink0", 1: "SMLink0B"]),
        ]),
        File(path: "/home/iunit/iunit_oem_cfg", alias: "IUnitOemCfg", settings: [
            Setting(name: "FWSecureMode", offset: 17, length: 1, options: [0: "Disabled", 1: "Enabled"]),
            Setting(name: "PortConfigurationFor8LSBLanes", offset: 4, length: 4, hex: true),
            Setting(name: "PortConfigurationFor8MSBLanes", offset: 8, length: 4, hex: true),
            Setting(name: "RomTraceEnable", offset: 16, length: 1, options: [0: "Disabled", 1: "Enabled"]),
            Setting(name: "SecureTouch", offset: 8, length: 1, options: [0: "Disabled", 1: "Enabled"]),
            Setting(name: "SecureTouchCameraMask", offset: 0, length: 4, hex: true),
        ]),
        File(path: "/home/policy/cfgmgr/cfg_rules", alias: "ME_CONF_WRK", settings: [
            Setting(name: "AmtSupported", offset: 344, length: 1, bits: 0...0, options: [0: "No", 1: "Yes"]),
            Setting(name: "CryptoHwSupport", offset: 344, length: 2, bits: 13...13, options: [0: "Yes", 1: "No"]),
            Setting(name: "EnableTDS", offset: 344, length: 4, bits: 25...25, options: [0: "No", 1: "Yes"]),
            Setting(name: "FID_INT_TOUCH", offset: 344, length: 1, bits: 4...4, options: [0: "No", 1: "Yes"]),
            Setting(name: "FID_ISH", offset: 344, length: 2, bits: 10...10, options: [0: "No", 1: "Yes"]),
            Setting(name: "FID_MEDAL", offset: 344, length: 3, bits: 20...20, options: [0: "Disabled", 1: "Enabled"]),
            Setting(name: "FID_PAV", offset: 344, length: 2, bits: 12...12, options: [0: "No", 1: "Yes"]),
            Setting(name: "FwUpdEnable", offset: 92, length: 1, bits: 0...0, options: [0: "No", 1: "Yes"]),
            Setting(name: "HideMEBxFwUpdCtrl", offset: 88, length: 1, bits: 1...1, options: [0: "No", 1: "Yes"]),
            Setting(name: "IshPowerUpState", offset: 404, length: 2, bits: 10...10, options: [0: "Disabled", 1: "Enabled"]),
            Setting(name: "KvmSupported", offset: 344, length: 3, bits: 18...18, options: [0: "No", 1: "Yes"]),
            Setting(name: "MELanPowerWell", offset: 188, length: 1, bits: 0...2, options: [0: "Core Well", 1: "SUS Well", 2: "ME Well", 3: "SLP_LAN#"]),
            Setting(name: "MEWlanPowerWell", offset: 200, length: 1, bits: 0...7, options: [128: "Disabled", 129: "Core Well || SLP_S3#", 130: "Primary Well || SLP_SUS#", 131: "ME Well || SLP_A#", 134: "SLP_WLAN#"]),
            Setting(name: "MeClinkEnable", offset: 464, length: 1, bits: 0...0, options: [0: "No", 1: "Yes"]),
            Setting(name: "MngAppPowerUpState", offset: 404, length: 1, bits: 2...2, options: [0: "Disabled", 1: "Enabled"]),
            Setting(name: "MngAppSupported", offset: 344, length: 1, bits: 2...2, options: [0: "No", 1: "Yes"]),
            Setting(name: "NetServicesSupported", offset: 344, length: 3, bits: 16...16, options: [0: "Yes", 1: "No"]),
            Setting(name: "ProcEmulation", offset: 488, length: 1, bits: 0...3, options: [0: "No Emulation", 1: "EMULATE Intel (R) vPro (TM) capable Processor", 2: "EMULATE Intel (R) Core (TM) branded Processor", 3: "EMULATE Intel (R) Celeron (R) branded Processor", 4: "EMULATE Intel (R) Pentium (R) branded Processor", 5: "EMULATE Intel (R) Xeon E (R) branded Processor", 6: "EMULATE Intel (R) Xeon W (R) Manageability capable Processor"]),
            Setting(name: "PttPwrUpState", offset: 404, length: 4, bits: 29...29, options: [0: "Disabled", 1: "Enabled"]),
            Setting(name: "PttSupported", offset: 344, length: 4, bits: 29...29, options: [0: "No", 1: "Yes"]),
            Setting(name: "TlsCryptoSupport", offset: 344, length: 3, bits: 21...21, options: [0: "No", 1: "Yes"]),
        ]),
        File(path: "/home/bup/si_features", alias: "KernFixedData", settings: [
            Setting(name: "DbgOverridePreProdSi", offset: 12, length: 4, hex: true),
            Setting(name: "DbgOverrideProdSi", offset: 16, length: 4, hex: true),
        ]),
        File(path: "/home/amt/skip_rtfd/ehbc.state", alias: "EhcbState", settings: [
            Setting(name: "EhbcEnable", offset: 0, length: 1, options: [0: "No", 1: "Yes"]),
        ]),
        File(path: "/home/fwupdate/fwuoemid", alias: "OEM_ID_STRING", settings: [
            Setting(name: "FwUpdateOemId", offset: 0, length: 16),
        ]),
        File(path: "/home/pavp/guc_hash", alias: "GucHash", settings: [
            Setting(name: "GucHash", offset: 0, length: 32),
        ]),
        File(path: "/home/amt/rtfd/rsb.state", alias: "KvmScreenBlnk", settings: [
            Setting(name: "KvmScreenBlnkEnable", offset: 0, length: 1, options: [0: "No", 1: "Yes"]),
        ]),
        File(path: "/home/mctp/device_ports", alias: "MctpDevicePorts", settings: [
            Setting(name: "MctpDevicePortBmc", offset: 3, length: 1, hex: true),
            Setting(name: "MctpDevicePortEc", offset: 0, length: 1, hex: true),
            Setting(name: "MctpDevicePortIsh", offset: 2, length: 1, hex: true),
            Setting(name: "MctpDevicePortSio", offset: 1, length: 1, hex: true),
        ]),
        File(path: "/home/mctp/eid_db", alias: "MctpStackConfig", settings: [
            Setting(name: "MctpPcieAddress", offset: 5, length: 1, hex: true),
            Setting(name: "MctpStackConfig", offset: 2, length: 3),
        ]),
        File(path: "/home/policy/msrmnt_sup", alias: "MeasurmentSupport", settings: [
            Setting(name: "MeMeasuredBootState", offset: 0, length: 1, options: [0: "Disabled", 1: "Enabled"]),
        ]),
        File(path: "/home/amt/skip_rtfd/pki.suffix", alias: "PkiSuffix", settings: [
            Setting(name: "PkiDomainSuffix", offset: 0, length: 256, text: true),
        ]),
        File(path: "/home/amt/skip_rtfd/pki.sec.sfx", alias: "PkiSecSfx", settings: [
            Setting(name: "PkiDomainSuffix", offset: 0, length: 256, text: true),
        ]),
        File(path: "/home/rbe/PreventSMTADisable", alias: "PreventSMTADisable", settings: [
            Setting(name: "PreventSMTADisable", offset: 0, length: 1),
        ]),
        File(path: "/home/iunit/iunit_privacy_mode", alias: "iunitPrivacyMode", settings: [
            Setting(name: "PrivacyFeatureControlDisabled", offset: 0, length: 1, options: [0: "false", 1: "true"]),
        ]),
        File(path: "/home/amt/skip_rtfd/sfx.isSecure", alias: "SfxIsSecure", settings: [
            Setting(name: "SuffixIsSecure", offset: 0, length: 1, options: [0: "false", 1: "true"]),
        ]),
        File(path: "/home/amt/skip_rtfd/ncsi", alias: "AmtNetworkConfiguration", settings: [
            Setting(name: "TypeCPort1RetimerI2cAddress", offset: 1, length: 1, hex: true),
            Setting(name: "TypeCPort2RetimerI2cAddress", offset: 2, length: 1, hex: true),
            Setting(name: "TypeCPort3RetimerI2cAddress", offset: 3, length: 1, hex: true),
            Setting(name: "TypeCPort4RetimerI2cAddress", offset: 4, length: 1, hex: true),
            Setting(name: "TypeCPortRetimerMCTPSmbusAddr", offset: 6, length: 1, hex: true),
            Setting(name: "vproDockEnabled", offset: 0, length: 1, bits: 1...1, options: [0: "No", 1: "Yes"]),
            Setting(name: "vproNicEnabled", offset: 0, length: 1, bits: 0...0, options: [0: "No", 1: "Yes"]),
            Setting(name: "vproNicSMBusAddress", offset: 5, length: 1, hex: true),
        ]),
        File(path: "/home/mctp/smt2_devices", alias: "Smt2Devices", settings: [
            Setting(name: "TypeCPortRetimerMCTPSmbusAddr", offset: 2, length: 1, hex: true),
            Setting(name: "vproNicSMBusAddress", offset: 0, length: 1, hex: true),
        ]),
        File(path: "/home/mctp/espi_en", alias: "eSpiEnabled", settings: [
            Setting(name: "eSpiEnabled", offset: 0, length: 1, options: [0: "No", 1: "Yes"]),
        ]),
        ])
}
