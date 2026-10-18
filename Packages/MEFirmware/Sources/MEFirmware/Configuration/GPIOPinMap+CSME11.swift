// The GPIO feature pins of CSME 11, as Flash Image Tool 11.0 names them —
// emitted by `Skills/me-eom-structures/scripts/gpio_map.py` from the
// tool's own value classes. The names are Intel's, copied; nothing here
// is read out of a dump.
//
// `/home/gpio/csme_pins` — the file the tool's `MeFeaturePins` class
// writes — carries the pins the image configures, and `GPIOPinReader`
// reads its records through this map. A number the tool has no name for
// is shown as the number.

import Foundation

extension GPIOPinMap {
    /// The values of CSME 11's `GpioCsme*` classes.
    public static let csme11 = GPIOPinMap(
        name: "CSME 11 (Flash Image Tool 11.0)",
        usages: [0: "NFC_RST", 1: "NFC_IRQ", 2: "INTEGRATED_TOUCH_1", 3: "INTEGRATED_TOUCH_2", 4: "MIRROR_PASS_1", 5: "MIRROR_PASS_2", 6: "EYE_RIVER_1", 7: "EYE_RIVER_2", 8: "FWUPDATE", 9: "SKIN_THRM_SNSR_ALERT_N", 10: "CPU_DETECTION", 11: "ME_PG_LED", 12: "PROC_ID_1", 13: "PROC_ID_2"],
        ownerships: [0: "HOST_MODE", 1: "CSME_MODE", 2: "ISH_MODE", 3: "IE_MODE"],
        padModes: [0: "GPIO_MODE", 1: "NATIVE_FUNCTION_1", 2: "NATIVE_FUNCTION_2", 3: "NATIVE_FUNCTION_3", 4: "DEFAULT_MODE"],
        groups: [0: "GPP_A", 1: "GPP_B", 2: "GPP_C", 3: "GPP_D", 4: "GPP_E", 5: "GPP_F", 6: "GPP_G", 7: "GPP_H", 8: "GPP_I", 9: "GPD", 255: "NONE"],
    )
}
