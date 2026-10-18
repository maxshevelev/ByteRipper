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
            Setting(name: "MELanPowerWell", offset: 188, length: 1, label: "LAN Power Well", help: "This setting allows the customer to configure the powerwell that will be used by Intel(R) Integrated LAN.  Note: Recommended setting is SLP_LAN#.", bits: 0...2, options: [0: "Core Well", 1: "SUS Well", 2: "ME Well", 3: "SLP_LAN#"]),
            Setting(name: "MEWlanPowerWell", offset: 200, length: 1, label: "WLAN Power Well", help: "This setting allows the customer to configure the powerwell that will be used by Intel(R) Wireless LAN.  Note: Recommended setting is SLP_WLAN#.", bits: 0...7, options: [128: "Disabled", 129: "Core Well || SLP_S3#", 130: "Primary Well || SLP_SUS#", 131: "ME Well || SLP_A#", 134: "SLP_WLAN#"]),
            Setting(name: "MeClinkEnable", offset: 464, length: 1, label: "Intel (R) ME CLINK Signal Enabled", help: "This setting allows customers to enable / disable the Wireless LAN CLINK signal through Intel (R) ME firmware.  Note: For using Intel(R) vPro Wireless solutions this should be set to 'Yes'.", bits: 0...0, options: [0: "No", 1: "Yes"]),
            Setting(name: "NfcEnable", offset: 344, length: 4, label: "Enable Near Field Communication", bits: 31...31, options: [0: "No", 1: "Yes"]),
            Setting(name: "PavpSupported", offset: 344, length: 2, label: "PAVP Supported", help: "This setting determines if the Protected Audio Video Path (PAVP) feature will be permanently disabled in the firmware image.", bits: 12...12, options: [0: "No", 1: "Yes"]),
            Setting(name: "ProcEmulation", offset: 488, length: 1, label: "Processor Emulation", help: "This setting determines processor type to be emulated on pre-production silicon.", bits: 0...3, options: [0: "No Emulation", 1: "EMULATE Intel (R) vPro (TM) capable Processor", 2: "EMULATE Intel (R) Core (TM) branded Processor", 3: "EMULATE Intel (R) Celeron (R) branded Processor", 4: "EMULATE Intel (R) Pentium (R) branded Processor", 5: "EMULATE Intel (R) Xeon (R) branded Processor", 6: "EMULATE Intel (R) Xeon (R) Manageability capable Processor"]),
            Setting(name: "ProcMissingDetect", offset: 212, length: 1, label: "Missing Processor Detection Alert", help: "This setting determines if missing processor detection is enabled on Desktop / Workstation platforms.  Note: This feature will only work if the platform has the appropriate glue logic present.", bits: 0...7, options: [0: "Yes", 255: "No"]),
            Setting(name: "PttPwrUpState", offset: 404, length: 4, label: "Intel(R) PTT initial power-up state", help: "This setting determines if Intel(R) PTT is enabled on platform power-up.", bits: 29...29, options: [0: "Disabled", 1: "Enabled"]),
            Setting(name: "TouchEnabled", offset: 344, length: 1, label: "Intel(R) Precise Touch Technology Enabled", help: "This setting determines whether Intel(R) Precise Touch Technology is enabled.", bits: 4...4, options: [0: "Disabled", 1: "Enabled"]),
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
        File(path: "/home/pavp/lspcon_port", alias: "PavpLspcon", settings: [
            Setting(name: "Lspcon4kdisp", offset: 0, length: 1, label: "LSPCON Internal Display Port 1 - LSPCON / 4K", help: "This setting determines which port for LSPCON will be connected to the HDCP 2.2 bridge adapter Display 1.", options: [0: "None", 2: "PortB", 4: "PortC", 8: "PortD"]),
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
        File(path: "/home/secureboot/txten", alias: "TxtEnabled", settings: [
            Setting(name: "TxtSupported", offset: 0, length: 1, label: "TXT Supported", help: "This setting determines if Intel(R) TXT is enabled on the platform.", options: [0: "No", 1: "Yes"]),
        ]),
        ])
}
