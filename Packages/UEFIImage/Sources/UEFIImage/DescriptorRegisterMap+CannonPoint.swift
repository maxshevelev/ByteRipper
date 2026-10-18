// The flash descriptor's registers of cannonPoint, as 12.0 lays them out —
// emitted by `Skills/me-eom-structures/scripts/descriptor_fit_map.py`
// from the tool's own platform documents (cnp). Names, places, labels
// and option words are the tool's; nothing here is read out of a dump.
//
// A field is kept only where every document of the platform states it
// identically; a bit they disagree about is left out.

import Foundation

extension DescriptorRegisterMap {
    public static let cannonPoint = DescriptorRegisterMap(registers: [
        Register(name: "FLMAP1", place: .absolute(0x18), words: 1, fields: [
            Field(name: "Flmap1_Flash_Master_Base_Address", bitOffset: 0, count: 8),
            Field(name: "Flmap1_Number_Of_Masters", bitOffset: 8, count: 3),
            Field(name: "Flmap1_RSVD_15_11", bitOffset: 11, count: 5),
            Field(name: "Flmap1_Flash_PCH_Strap_Base_Address", bitOffset: 16, count: 8),
            Field(name: "Flmap1_PCH_Strap_Length", bitOffset: 24, count: 8),
        ]),
        Register(name: "FLCOMP", place: .flashComponent(offset: 0x0), words: 1, fields: [
            Field(name: "Flcomp_Component_0_Density", bitOffset: 0, count: 4, label: "Flash component 1 Size", options: [0: "512KB", 1: "1MB", 2: "2MB", 3: "4MB", 4: "8MB", 5: "16MB", 6: "32MB", 7: "64MB", 15: "8MB"]),
            Field(name: "Flcomp_Component_1_Density", bitOffset: 4, count: 4, label: "Flash component 2 Size", options: [0: "512KB", 1: "1MB", 2: "2MB", 3: "4MB", 4: "8MB", 5: "16MB", 6: "32MB", 7: "64MB", 15: "8MB"]),
            Field(name: "Flcomp_Fast_Read_Support", bitOffset: 20, count: 1, label: "Fast Read Supported", options: [0: "No", 1: "Yes"]),
            Field(name: "Flcomp_Fast_Read_Clock_Frequency", bitOffset: 21, count: 3, label: "Fast Read Clock Frequency", options: [0: "100MHz", 1: "50MHz", 2: "48MHz", 3: "33MHz", 4: "25MHz", 5: "20MHz", 6: "14MHZ"]),
            Field(name: "Flcomp_Write_Erase_Clock_Frequency", bitOffset: 24, count: 3, label: "Write and Erase Clock Frequency", options: [0: "100MHz", 1: "50MHz", 2: "48MHz", 3: "33MHz", 4: "25MHz", 5: "20MHz", 6: "14MHZ"]),
            Field(name: "Flcomp_Read_ID_Read_Status_Clock_Frequency", bitOffset: 27, count: 3, label: "Read ID and Read Status Clock Frequency", options: [2: "48MHz", 4: "30MHz", 6: "17MHz"]),
            Field(name: "Flcomp_RSVD_31_30", bitOffset: 30, count: 2),
        ]),
    ])
}

