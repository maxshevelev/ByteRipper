// The flash descriptor's registers of elkhartLake, as fit-13.0 lays them out —
// emitted by `Skills/me-eom-structures/scripts/descriptor_fit_map.py`
// from the tool's own platform documents (ehl). Names, places, labels
// and option words are the tool's; nothing here is read out of a dump.
//
// A field is kept only where every document of the platform states it
// identically; a bit they disagree about is left out.

import Foundation

extension DescriptorRegisterMap {
    public static let elkhartLake = DescriptorRegisterMap(registers: [
        Register(name: "FLMAP0", place: .absolute(0x14), words: 1, fields: [
            Field(name: "Flmap0_Flash_Component_Base_Address", bitOffset: 0, count: 8),
            Field(name: "Flmap0_Number_Of_Components", bitOffset: 8, count: 2, label: "Number of Flash Components", options: [0: "1", 1: "2", 3: "0"]),
            Field(name: "Flmap0_Touch_on_shared_flash", bitOffset: 10, count: 1),
            Field(name: "Flmap0_Touch_on_dedicated_SPI_bus", bitOffset: 11, count: 1),
            Field(name: "Flmap0_Fingerprint_sensor_on_shared_flash", bitOffset: 12, count: 1),
            Field(name: "Flmap0_RSVD_15_13", bitOffset: 13, count: 3),
            Field(name: "Flmap0_Flash_Region_Base_Address", bitOffset: 16, count: 8),
            Field(name: "Flmap0_RSVD_26_24", bitOffset: 24, count: 3),
            Field(name: "Flmap0_RSVD_31_27", bitOffset: 27, count: 5),
        ]),
        Register(name: "FLMAP1", place: .absolute(0x18), words: 1, fields: [
            Field(name: "Flmap1_Flash_Master_Base_Address", bitOffset: 0, count: 8),
            Field(name: "Flmap1_Number_Of_Masters", bitOffset: 8, count: 3),
            Field(name: "Flmap1_RSVD_15_11", bitOffset: 11, count: 5),
            Field(name: "Flmap1_Flash_PCH_Strap_Base_Address", bitOffset: 16, count: 8),
            Field(name: "Flmap1_PCH_Strap_Length", bitOffset: 24, count: 8),
        ]),
        Register(name: "FLMAP2", place: .absolute(0x1C), words: 1, fields: [
            Field(name: "Flmap2_RSVD_1_0", bitOffset: 0, count: 2),
            Field(name: "Flmap2_CPU_Softstrap_Offset_from_PMC_Base", bitOffset: 2, count: 10),
            Field(name: "Flmap2_RSVD_15_12", bitOffset: 12, count: 4),
            Field(name: "Flmap2_CPU_Softstrap_Length", bitOffset: 16, count: 8),
            Field(name: "Flmap2_RSVD_31_24", bitOffset: 24, count: 8),
        ]),
        Register(name: "FLCOMP", place: .flashComponent(offset: 0x0), words: 1, fields: [
            Field(name: "Flcomp_Component_0_Density", bitOffset: 0, count: 4, label: "Flash component 1 Size", options: [0: "512KB", 1: "1MB", 2: "2MB", 3: "4MB", 4: "8MB", 5: "16MB", 6: "32MB", 7: "64MB", 15: "8MB"]),
            Field(name: "Flcomp_Component_1_Density", bitOffset: 4, count: 4, label: "Flash component 2 Size", options: [0: "512KB", 1: "1MB", 2: "2MB", 3: "4MB", 4: "8MB", 5: "16MB", 6: "32MB", 7: "64MB", 15: "8MB"]),
            Field(name: "Flcomp_RSVD_8", bitOffset: 8, count: 1),
            Field(name: "Flcomp_SPI_Voltage_Select", bitOffset: 9, count: 1),
            Field(name: "Flcomp_RSVD_11_10", bitOffset: 10, count: 2),
            Field(name: "Flcomp_Dual_Output_Read_Enable", bitOffset: 12, count: 1, label: "Dual Output Read Enable", options: [0: "No", 1: "Yes"]),
            Field(name: "Flcomp_Dual_IO_Read_Enable", bitOffset: 13, count: 1, label: "Dual I/O Read Enable", options: [0: "No", 1: "Yes"]),
            Field(name: "Flcomp_Quad_Output_Read_Enable", bitOffset: 14, count: 1, label: "Quad Output Read Enable", options: [0: "No", 1: "Yes"]),
            Field(name: "Flcomp_Quad_IO_Read_Enable", bitOffset: 15, count: 1, label: "Quad I/O Read Enable", options: [0: "No", 1: "Yes"]),
            Field(name: "Flcomp_RSVD_19_16", bitOffset: 16, count: 4),
            Field(name: "Flcomp_Fast_Read_Support", bitOffset: 20, count: 1, label: "Fast Read Supported", options: [0: "No", 1: "Yes"]),
            Field(name: "Flcomp_Fast_Read_Clock_Frequency", bitOffset: 21, count: 3, label: "Fast Read Clock Frequency", options: [0: "100MHz", 1: "50MHz", 2: "48MHz", 3: "33MHz", 4: "25MHz", 5: "20MHz", 6: "14MHZ"]),
            Field(name: "Flcomp_Write_Erase_Clock_Frequency", bitOffset: 24, count: 3, label: "Write and Erase Clock Frequency", options: [0: "100MHz", 1: "50MHz", 2: "48MHz", 3: "33MHz", 4: "25MHz", 5: "20MHz", 6: "14MHZ"]),
            Field(name: "Flcomp_Read_ID_Read_Status_Clock_Frequency", bitOffset: 27, count: 3, label: "Read ID and Read Status Clock Frequency", options: [0: "100MHz", 1: "50MHz", 2: "48MHz", 3: "33MHz", 4: "25MHz", 5: "20MHz", 6: "14MHZ"]),
            Field(name: "Flcomp_RSVD_31_30", bitOffset: 30, count: 2),
        ]),
        Register(name: "FLMSTR3", place: .flashMaster(offset: 0x8), words: 1, fields: [
            Field(name: "Flmstr3_Extended_Region_Read_Access_GBE", bitOffset: 0, count: 4),
            Field(name: "Flmstr3_Extended_Region_Write_Access_GBE", bitOffset: 4, count: 4),
            Field(name: "Flmstr3_Master_Region_Read_Access_GBE", bitOffset: 8, count: 12),
            Field(name: "Flmstr3_Master_Region_Write_Access_GBE", bitOffset: 20, count: 12),
        ]),
        Register(name: "FLMSTR5", place: .flashMaster(offset: 0x10), words: 1, fields: [
            Field(name: "Flmstr5_Extended_Region_Read_Access_EC", bitOffset: 0, count: 4),
            Field(name: "Flmstr5_Extended_Region_Write_Access_EC", bitOffset: 4, count: 4),
            Field(name: "Flmstr5_Master_Region_Read_Access_EC", bitOffset: 8, count: 12),
            Field(name: "Flmstr5_Master_Region_Write_Access_EC", bitOffset: 20, count: 12),
        ]),
    ])
}

