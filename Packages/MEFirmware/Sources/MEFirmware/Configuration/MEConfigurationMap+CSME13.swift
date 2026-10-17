// The CSME 13 map of the ME configuration — emitted by
// `Skills/me-eom-structures/scripts/fit_map.py` from Flash Image Tool 13.0's
// own layout documents (the icl_lp platform of ME 13).
//
// The family is the tool's own name for the platform half: `_lp`/`_p` is
// the mobile one and `_h`/`_s` the desktop one, and a dump is read with
// the one its descriptor's strap section length names
// (`MEConfigurationMap.forME(major:family:)`).
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
        name: "CSME 13 (Flash Image Tool 13.0, icl_lp)",
        files: [
        File(path: "/home/mca/eom_config", alias: "EOM_Config", settings: [
            Setting(name: "EomFirstBootEnabled", offset: 0, length: 1, label: "EOM on First Boot Enabled", help: "This setting detremines if End of Manufacturing will be triggered on first boot of the platform after flashing.\nNote: When this setting is enabled Intel(R) CSME will enter End of Manufacturing regardless of the descriptor settings.", bits: 0...0, options: [0: "No", 1: "Yes"]),
            Setting(name: "FlexibleEomSettings", offset: 0, length: 1, label: "Flexible EOM setting options", help: "This setting deteremines which settings will be automatically commited during End of Manufacturing flows.\nNote: The FPFs, RPMB / RPMC and set manufacturing mode settings are mandatory and cannot be overridden revenue parts. Simulation can be done on non-revenue part with the Hardware binding set to disabled.", bits: 1...2, options: [0: "Lock Descriptor and OEM Configs", 1: "Lock OEM Configs Only", 2: "Lock Descriptor Only", 3: "Do not lock Descriptor and OEM Configs"]),
        ]),
        File(path: "/home/mca/eom", alias: "EOM", settings: [
            Setting(name: "EOM", offset: 0, length: 1, hex: true),
            Setting(name: "EomFirstBootEnabled", offset: 0, length: 1, label: "EOM on First Boot Enabled", help: "This setting detremines if End of Manufacturing will be triggered on first boot of the platform after flashing.\nNote: When this setting is enabled Intel(R) CSME will enter End of Manufacturing regardless of the descriptor settings.", options: [0: "No", 1: "Yes"]),
        ]),
        File(path: "/home/policy/cfgmgr/cfg_rules", alias: "ME_CONF_WRK", settings: [
            Setting(name: "AmtSupported", offset: 344, length: 1, label: "Intel(R) AMT Supported", help: "This setting allows customers to disable Intel(R) AMT on the platform and force the platform into Standard Manageability mode.  Note: This setting is only applies to Desktop and Workstation platforms.", bits: 0...0, options: [0: "No", 1: "Yes"]),
            Setting(name: "CryptoHwSupport", offset: 344, length: 2, label: "Crypto HW Support", help: "This setting can be used to disable crypto funtionality. This settings disables all crypto dependent features.", bits: 13...13, options: [0: "Yes", 1: "No"]),
            Setting(name: "EnableTDS", offset: 344, length: 4, label: "Enable TDS Capabilities", help: "This setting enables Intel(R) Trusted Device Setup on the platform", bits: 25...25, options: [0: "No", 1: "Yes"]),
            Setting(name: "FID_INT_TOUCH", offset: 344, length: 1, bits: 4...4, options: [0: "No", 1: "Yes"]),
            Setting(name: "FID_ISH", offset: 344, length: 2, bits: 10...10, options: [0: "No", 1: "Yes"]),
            Setting(name: "FID_MEDAL", offset: 344, length: 3, bits: 20...20, options: [0: "Disabled", 1: "Enabled"]),
            Setting(name: "FID_PAV", offset: 344, length: 2, bits: 12...12, options: [0: "No", 1: "Yes"]),
            Setting(name: "IshPowerUpState", offset: 404, length: 2, label: "Integrated Sensor Hub Initial Power State", help: "This setting allows customers to determine the power up state for ISH.", disabledBy: Condition(name: "IshSupported", value: 1), bits: 10...10, options: [0: "Disabled", 1: "Enabled"]),
            Setting(name: "MELanPowerWell", offset: 188, length: 1, label: "LAN Power Well", help: "This setting allows the customer to configure the powerwell that will be used by Intel(R) Integrated LAN.  Note: Recommended setting is SLP_LAN#.", bits: 0...2, options: [0: "Core Well", 1: "SUS Well", 2: "ME Well", 3: "SLP_LAN#"]),
            Setting(name: "MEWlanPowerWell", offset: 200, length: 1, label: "WLAN Power Well", bits: 0...7, options: [128: "Disabled", 129: "Core Well || SLP_S3#", 130: "Primary Well || SLP_SUS#", 131: "ME Well || SLP_A#", 134: "SLP_WLAN#"]),
            Setting(name: "MeClinkEnable", offset: 464, length: 1, label: "Intel(R) ME CLINK Signal Enabled", help: "This setting allows customers to enable / disable the Wireless LAN CLINK signal through Intel(R) ME firmware.  Note: For using Intel(R) vPro Wireless solutions this should be set to Yes.", bits: 0...0, options: [0: "No", 1: "Yes"]),
            Setting(name: "MngAppPowerUpState", offset: 404, length: 1, label: "Manageability Application initial power-up state", help: "This setting allows customers to determine the power up state for Intel(R) AMT or Standard Manageability.  Note: If this setting is disabled Intel(R) AMT or Standard Manageability can still be re-enabled through the MEBx interface.", bits: 2...2, options: [0: "Disabled", 1: "Enabled"]),
            Setting(name: "MngAppSupported", offset: 344, length: 1, label: "Manageability Application Supported", help: "This setting allows customers to permenantly disable Intel(R) AMT and Standard Manageability mode on the platform.", bits: 2...2, options: [0: "No", 1: "Yes"]),
            Setting(name: "NetServicesSupported", offset: 344, length: 3, label: "Intel(R) ME Network Services Supported", help: "This setting allows customers to enable / disable Intel(R) ME Network Services on the platform.  Note: If this setting is disabled Intel(R) AMT will also be disabled.", bits: 16...16, options: [0: "Yes", 1: "No"]),
            Setting(name: "ProcEmulation", offset: 488, length: 1, label: "Processor Emulation", bits: 0...3, options: [0: "No Emulation", 1: "EMULATE Intel (R) vPro (TM) capable Processor", 2: "EMULATE Intel (R) Core (TM) branded Processor", 3: "EMULATE Intel (R) Celeron (R) branded Processor", 4: "EMULATE Intel (R) Pentium (R) branded Processor", 5: "EMULATE Intel (R) Xeon (R) branded Processor", 6: "EMULATE Intel (R) Xeon (R) Manageability capable Processor"]),
            Setting(name: "PttPwrUpState", offset: 404, length: 4, label: "Intel(R) PTT initial power-up state", disabledBy: Condition(name: "PttSupported", value: 0), bits: 29...29, options: [0: "Disabled", 1: "Enabled"]),
            Setting(name: "PttSupported", offset: 344, length: 4, label: "Intel(R) PTT Supported", help: "This setting permanently disables Intel(R) PTT in the firmware image.", bits: 29...29, options: [0: "No", 1: "Yes"]),
            Setting(name: "TouchEnabled", offset: 344, length: 1, label: "Intel(R) Precise Touch and Stylus Enabled", help: "This setting enables Intel(R) Precise Touch and Stylus on the platform,", bits: 4...4, options: [0: "No", 1: "Yes"]),
        ]),
        File(path: "/home/amt/rtfd/amt.wol", alias: "amt.wol", settings: [
            Setting(name: "AmtIdleTimeout", offset: 0, length: 2, label: "Intel(R) AMT Idle Timeout", help: "This setting configures the idle timeout value before Intel(R) AMT enters into an off state.", hex: true),
        ]),
        File(path: "/home/amt/rtfd/WDResetState", alias: "AmtWdTimer", settings: [
            Setting(name: "AmtWdAutoReset", offset: 0, length: 1, label: "Intel(R) AMT Watchdog Automatic Reset Enabled", help: "This setting allows customers to enable the Intel (R) ME firmware to trigger an automatic platform reset if either the MEI or Agent Presence are in a hung state.  Note: This feature only allows one reset at a time when the watchdog expires.  After this feature has triggered a reset it must be re-armed for re-use via management console.", options: [0: "No", 1: "Yes"]),
        ]),
        File(path: "/home/bup/si_features", alias: "KernFixedData", settings: [
            Setting(name: "DbgOverridePreProdSi", offset: 12, length: 4, label: "Debug Override Pre-Production Silicon", help: "Allows the OEM to control FW features to assist with pre-production platform debugging.  This control has no effect if used on production silicon.  Note: Certain options will do not work when the descriptor is locked (See FW Bring-up Guide for setting details).", hex: true),
            Setting(name: "DbgOverrideProdSi", offset: 16, length: 4, label: "Debug Override Production Silicon", help: "Allows the OEM to control FW features to assist with production platform debugging.  Note: Certain options will do not work when the descriptor is locked (See FW Bring-up Guide for setting details).", hex: true),
        ]),
        File(path: "/home/iunit/sec_ctl", alias: "IUnitSecCtl", settings: [
            Setting(name: "FWSecureMode", offset: 1, length: 1, label: "FW Secure Mode", help: "If enabled, access blockers in IS and PS are enabled, and FW is read from IMR. Must be enabled for FW authentication flow and execution of authenticated FW.", options: [0: "Disabled", 1: "Enabled"]),
            Setting(name: "RomTraceEnable", offset: 0, length: 1, label: "IPU Debugging Enabled", help: "If enabled, IPU Debugging is enabled, otherwise internal setup is checked to see if the IPU Debugging feature should be enabled or not.", options: [0: "Disabled", 1: "Enabled"]),
        ]),
        File(path: "/home/bup/bup_sku/hw_binding", alias: "HwBinding", settings: [
            Setting(name: "HwBindingEn", offset: 0, length: 1, label: "Hardware Binding Enabled", help: "This setting configures the FPF Hardware and RPMC / RPMB binding behavior for the platform image.   \n\n                                                                                                                                             If this setting is enabled FPF Hardware and RPMC / RPMB binding behavior will occur when platform close manufacturing flow is executed with Intel® FPT. \n\n                                                                                                                                             If this setting is disabled FPF Hardware and RPMC / RPMB binding behavior will not take place when close manufacturing flow is executed.\n\n                                                                                                                                             Note: For Revenue parts this setting will be ignored and FPF Hardware and RPMC / RPMB binding behavior will take place when close manufacturing flow is executed.", options: [0: "Disabled", 1: "Enabled"]),
        ]),
        File(path: "/home/loadmgr/arben", alias: "BootGuardArb", settings: [
            Setting(name: "IomArbEnable", offset: 0, length: 1, label: "IO Manageability Engine Manifest Anti-Rollback Enabled", help: "This setting enables Anti-Roll back for the Type-C Subsystem IO Manageability Engine binary.", bits: 6...6, options: [0: "No", 1: "Yes"]),
            Setting(name: "NphyPhyArbEnable", offset: 0, length: 1, label: "NPHY Manifest Anti-Rollback Enabled", help: "This setting enables Anti-Roll back for the Type-C Subsystem NPHY binary.", bits: 7...7, options: [0: "No", 1: "Yes"]),
            Setting(name: "TbtArbEnable", offset: 0, length: 2, label: "Thunderbolt(TM) Manifest Anti-Rollback Enabled ", help: "This setting enables Anti-Roll back for the Type-C Subsystem Thunderbolt(TM) binary.", bits: 8...8, options: [0: "No", 1: "Yes"]),
        ]),
        File(path: "/home/mctp/smt2_devices", alias: "Smt2Devices", settings: [
            Setting(name: "MctpEcAddress", offset: 4, length: 2, label: "MCTP EC Address", help: "Defines the 8-bits MCTP address and 7-bits SMBus address of the EC on SMLink1 bus. This value is needed if EC is using the MCTP protocol. The SMBus (LS byte) must be from 0x01 to 0x7f (and should not overlap with any SMBus address in PCH Strap 11).  The EID (MS byte) must be outside 0x01 through 0x07.", hex: true),
        ]),
        File(path: "/home/iunit/port_cfg", alias: "IUnitPortCfg", settings: [
            Setting(name: "PortConfigurationFor8LSBLanes", offset: 0, length: 2, label: "Port Configuration For 8 LSB Lanes", help: "When SW DRIVER CONTROLS PORT CONFIGURATION is cleared this determines the port configuration mapping between the lower 8 MIPI lanes and the CSI receiver ports the lanes can connect to.:\n\n      Bits[3:0] determine the configuration of Port A:\n\n       0x0: port is disabled \n\n       0x4: X1 (ICL only)\n\n       0x5: X2 (ICL only)\n\n       Others: reserved \n\n       Bits[8:4] determine the configuration of Port B: \n\n       0x0: port is disabled \n\n       Others: reserved \n\n      Bits[10:9] determine the configuration of Port C: \n\n       0x0: port is disabled \n\n       0x2: X1 \n\n       Others: reserved \n\n      Bits[13:11] determine the configuration of Port D: \n\n       0x0: port is disabled \n\n       0x5: X2 \n\n       0x7: X4 \n\n       Others: reserved", hex: true),
            Setting(name: "PortConfigurationFor8MSBLanes", offset: 4, length: 2, label: "Port Configuration For 8 MSB Lanes", help: "When SW DRIVER CONTROLS PORT CONFIGURATION is cleared this determines the port configuration mapping between the upper 8 MIPI lanes and the CSI receiver ports the lanes can connect to.: \n\n      Bits[3:0] determine the configuration of Port A: \n\n       0x0: port is disabled \n\n       0x4: X1 \n\n       0x5: X2 \n\n       Others: reserved \n\n      Bits[8:4] determine the configuration of Port B: \n\n       0x0: port is disabled \n\n       0x9: X2 \n\n       Others: reserved \n\n      Bits[10:9] determine the configuration of Port C: \n\n       0x0: port is disabled \n\n       0x2: X1 \n\n       Others: reserved \n\n      Bits[13:11] determine the configuration of Port D: \n\n       0x0: port is disabled \n\n       0x5: X2 \n\n       0x7: X4 \n\n       Others: reserved", hex: true),
            Setting(name: "SWDriverControlsPortConfiguration", offset: 8, length: 1, label: "SW Driver Controls Port Configuration ", help: "When set, port config is taken from the value IPU driver configures in IPU. When cleared, port config is taken from: CSI2_PORT_CONFIG_MSB.PORT_ID and CSI2_PORT_CONFIG_LSB.PORT_ID", options: [0: "Disabled", 1: "Enabled"]),
        ]),
        File(path: "/home/iunit/sec_touch", alias: "IUnitSecTouch", settings: [
            Setting(name: "SecureTouch", offset: 0, length: 1, label: "Secure Touch", help: "When set, CAMERA_MASK register bits per CSI port are used to mask the data of cameras. When cleared, camera data is not masked. ", options: [0: "Disabled", 1: "Enabled"]),
        ]),
        File(path: "/home/iunit/camera_mask", alias: "IUnitCameraMask", settings: [
            Setting(name: "SecureTouchCameraMask", offset: 0, length: 1, label: "Secure Touch and Camera Mask", help: "Camera mask bits per CSI port. When SECURE_TOUCH is set each set bit masks a CSI port for secure touch. When SECURE_TOUCH is cleared this register has no impact on the CSI ports.", hex: true),
        ]),
        File(path: "/home/tcss/tcss_ctrl", alias: "TcssControl", settings: [
            Setting(name: "TcssAuthenticateEn", offset: 0, length: 1, options: [0: "Yes", 1: "No"]),
        ]),
        File(path: "/home/fwupdate/fwutcss", alias: "TCSS_PartialUpdate", settings: [
            Setting(name: "TcssPartialUpdateEn", offset: 0, length: 1, label: "Tcss - Partial Update Enabled", help: "This setting enables partial update for TCSS partitions", options: [0: "Disabled", 1: "Enabled"]),
        ]),
        ])
}
