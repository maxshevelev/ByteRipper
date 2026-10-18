// The PCH soft straps of ibexPeak, as Intel's SPI Programming Guide
// lays them out — emitted by
// `Skills/me-eom-structures/scripts/intel_strap_map.py` from flashrom's `include/ich_descriptors.h`.
// Names, bits, labels and option words are the guide's; nothing here is
// read out of a dump.
//
// A field the guide calls reserved is not here: it has no name, and the
// panel shows the word's raw value where a word names no field.

import Foundation

extension DescriptorStrapMap {
    /// The 16-word PCH strap section.
    public static let pch16 = DescriptorStrapMap(
        name: "flashrom's `include/ich_descriptors.h`",
        words: 16,
        fields: [
            Field(name: "PCHSTRP0_cs_ss2", word: 0, bits: 1...1),
            Field(name: "PCHSTRP0_SMB_EN", word: 0, bits: 7...7, label: "Intel ME SMBus Select", options: [0: "Disabled", 1: "Enabled"]),
            Field(name: "PCHSTRP0_SML0_EN", word: 0, bits: 8...8, label: "SMLink0 Enable", options: [0: "Disabled", 1: "Enabled"]),
            Field(name: "PCHSTRP0_SML1_EN", word: 0, bits: 9...9, label: "SMLink1 Enable", options: [0: "Disabled", 1: "Enabled"]),
            Field(name: "PCHSTRP0_SML1FRQ", word: 0, bits: 10...11, label: "SMLink1 Frequency", options: [1: "100 kHz"]),
            Field(name: "PCHSTRP0_SMB0FRQ", word: 0, bits: 12...13, label: "Intel ME SMBus Frequency", options: [1: "100 kHz"]),
            Field(name: "PCHSTRP0_SML0FRQ", word: 0, bits: 14...15, label: "SMLink0 Frequency", options: [1: "100 kHz", 3: "Fast Mode"]),
            Field(name: "PCHSTRP0_LANPHYPC_GP12_SEL", word: 0, bits: 20...20, label: "LAN PHY Power Control GPIO12 Select", options: [0: "General purpose output", 1: "LAN_PHY_PWR_CTRL"]),
            Field(name: "PCHSTRP0_cs_ss1", word: 0, bits: 21...21),
            Field(name: "PCHSTRP0_DMI_REQID_DIS", word: 0, bits: 24...24, label: "DMI RequesterID Check Disable", options: [0: "Checks enabled", 1: "Checks disabled"]),
            Field(name: "PCHSTRP0_BBBS", word: 0, bits: 29...30, label: "BIOS Boot-Block Size", options: [0: "64 KB", 1: "128 KB", 2: "256 KB"]),
            Field(name: "PCHSTRP1_cs_ss3", word: 1, bits: 0...3),
            Field(name: "PCHSTRP2_MESMASDEN", word: 2, bits: 8...8, label: "Intel ME SMBus ASD Address Enable"),
            Field(name: "PCHSTRP2_MESMASDA", word: 2, bits: 9...15, label: "Intel ME SMBus ASD Address"),
            Field(name: "PCHSTRP2_MESMI2CEN", word: 2, bits: 24...24, label: "Intel ME SMBus I2C Address Enable"),
            Field(name: "PCHSTRP2_MESMI2CA", word: 2, bits: 25...31, label: "Intel ME SMBus I2C Address"),
            Field(name: "PCHSTRP4_PHYCON", word: 4, bits: 0...1, label: "PHY Connectivity", options: [0: "No PHY connected", 2: "PHY on SMLink0"]),
            Field(name: "PCHSTRP4_GBEMAC_SMBUS_ADDR_EN", word: 4, bits: 8...8, label: "GbE MAC SMBus Address Enable"),
            Field(name: "PCHSTRP4_GBEMAC_SMBUS_ADDR", word: 4, bits: 9...15, label: "GbE MAC SMBus Address"),
            Field(name: "PCHSTRP4_GBEPHY_SMBUS_ADDR", word: 4, bits: 17...23, label: "GbE PHY SMBus Address"),
            Field(name: "PCHSTRP7_MESMA2UDID_VENDOR", word: 7, bits: 0...15, label: "Intel ME SMBus Subsystem Vendor ID"),
            Field(name: "PCHSTRP7_MESMA2UDID_DEVICE", word: 7, bits: 16...31, label: "Intel ME SMBus Subsystem Device ID"),
            Field(name: "PCHSTRP9_PCIEPCS1", word: 9, bits: 0...1, label: "PCI Express Port Configuration Strap 1", options: [0: "4 x1 ports", 1: "1 x2 and 2 x1 ports", 2: "2 x2 ports", 3: "1 x4 port"]),
            Field(name: "PCHSTRP9_PCIEPCS2", word: 9, bits: 2...3, label: "PCI Express Port Configuration Strap 2", options: [0: "4 x1 ports", 1: "1 x2 and 2 x1 ports", 2: "2 x2 ports", 3: "1 x4 port"]),
            Field(name: "PCHSTRP9_PCIELR1", word: 9, bits: 4...4, label: "PCIe Lane Reversal 1"),
            Field(name: "PCHSTRP9_PCIELR2", word: 9, bits: 5...5, label: "PCIe Lane Reversal 2"),
            Field(name: "PCHSTRP9_DMILR", word: 9, bits: 6...6, label: "DMI Lane Reversal"),
            Field(name: "PCHSTRP9_PHY_PCIEPORTSEL", word: 9, bits: 8...10, label: "Default PHY PCIe Port"),
            Field(name: "PCHSTRP9_PHY_PCIE_EN", word: 9, bits: 11...11, label: "Integrated MAC/PHY Communication over PCIe", options: [0: "Disabled", 1: "Enabled"]),
            Field(name: "PCHSTRP10_ME_BOOT_FLASH", word: 10, bits: 1...1, label: "ME Boot from Flash", options: [0: "ROM, then flash", 1: "From flash"]),
            Field(name: "PCHSTRP10_cs_ss5", word: 10, bits: 2...2),
            Field(name: "PCHSTRP10_VE_EN", word: 10, bits: 3...3),
            Field(name: "PCHSTRP10_MMDDE", word: 10, bits: 8...8),
            Field(name: "PCHSTRP10_MMADDR", word: 10, bits: 9...15),
            Field(name: "PCHSTRP10_cs_ss7", word: 10, bits: 16...16),
            Field(name: "PCHSTRP10_ICC_SEL", word: 10, bits: 18...20, label: "Integrated Clocking Configuration"),
            Field(name: "PCHSTRP10_MER_CL1", word: 10, bits: 21...21, label: "ME Reset Capture on CL_RST1#"),
            Field(name: "PCHSTRP11_SML1GPAEN", word: 11, bits: 0...0, label: "SMLink1 GP Address Enable"),
            Field(name: "PCHSTRP11_SML1GPA", word: 11, bits: 1...7, label: "SMLink1 General Purpose Target Address"),
            Field(name: "PCHSTRP11_SML1I2CAEN", word: 11, bits: 24...24, label: "SMLink1 I2C Target Address Enable"),
            Field(name: "PCHSTRP11_SML1I2CA", word: 11, bits: 25...31, label: "SMLink1 I2C Target Address"),
            Field(name: "PCHSTRP14_VE_EN2", word: 14, bits: 8...8),
            Field(name: "PCHSTRP14_VE_BOOT_FLASH", word: 14, bits: 14...14),
            Field(name: "PCHSTRP14_BW_SSD", word: 14, bits: 16...16),
            Field(name: "PCHSTRP14_NVMHCI_EN", word: 14, bits: 17...17),
            Field(name: "PCHSTRP15_cs_ss6", word: 15, bits: 3...4),
            Field(name: "PCHSTRP15_IWL_EN", word: 15, bits: 6...6, label: "Integrated Wired LAN Enabled", options: [0: "Disabled", 1: "Enabled"]),
            Field(name: "PCHSTRP15_t209min", word: 15, bits: 8...9),
        ])
}
