// The flash descriptor's registers, as Flash Image Tool 18.1 lays them out —
// emitted by `Skills/me-eom-structures/scripts/descriptor18_map.py` from
// the tool's own harness documents. Names, places, labels and option
// words are the tool's; nothing here is read out of a dump.
//
// A register is placed absolutely in the descriptor (FLMAP0/1/2,
// FLDRPLCY, FLUMAP1) or at a base the descriptor states (FLCOMP/FLIL at
// `FCBA << 4`, FLMSTR at `FMBA << 4`). A field's place is a bit range of
// the register.

import Foundation

extension DescriptorRegisterMap {
    /// The registers, as the tool lays them out.
    public static let csme18 = DescriptorRegisterMap(
        registers: [
            Register(name: "FLMAP0", place: Place.absolute(0x14), words: 1, fields: [
                Field(name: "FLMAP0_Flash_Component_Base_Address", bitOffset: 0, count: 8),
                Field(name: "FLMAP0_Number_Of_Subdivisions", bitOffset: 8, count: 2),
                Field(name: "FLMAP0_Touch_on_shared_flash", bitOffset: 10, count: 1),
                Field(name: "FLMAP0_Touch_on_dedicated_SPI_bus", bitOffset: 11, count: 1),
                Field(name: "FLMAP0_Fingerprint_sensor_on_shared_flash", bitOffset: 12, count: 1),
                Field(name: "FLMAP0_RSVD_15_13", bitOffset: 13, count: 3),
                Field(name: "FLMAP0_Flash_Region_Base_Address", bitOffset: 16, count: 8),
                Field(name: "FLMAP0_RSVD_26_24", bitOffset: 24, count: 3),
                Field(name: "FLMAP0_RSVD_31_27", bitOffset: 27, count: 5),
            ]),
            Register(name: "FLMAP1", place: Place.absolute(0x18), words: 1, fields: [
                Field(name: "FLMAP1_Flash_Master_Base_Address", bitOffset: 0, count: 8),
                Field(name: "FLMAP1_Number_Of_Masters", bitOffset: 8, count: 3),
                Field(name: "FLMAP1_RSVD_15_11", bitOffset: 11, count: 5),
                Field(name: "FLMAP1_Flash_SoC_Strap_Base_Address", bitOffset: 16, count: 8),
                Field(name: "FLMAP1_SoC_Strap_Length", bitOffset: 24, count: 8),
            ]),
            Register(name: "FLMAP2", place: Place.absolute(0x1C), words: 1, fields: [
                Field(name: "FLMAP2_RSVD_1", bitOffset: 0, count: 2),
                Field(name: "FLMAP2_CPU_Softstrap_Offset_from_PMC_Base", bitOffset: 2, count: 10),
                Field(name: "FLMAP2_RSVD_15_12", bitOffset: 12, count: 4),
                Field(name: "FLMAP2_CPU_Softstrap_Length", bitOffset: 16, count: 8),
                Field(name: "FLMAP2_RSVD_31_24", bitOffset: 24, count: 8),
            ]),
            Register(name: "FLCOMP", place: Place.flashComponent(offset: 0x0), words: 1, fields: [
                Field(name: "FLCOMP_ImageSubdivisionsSizes1", bitOffset: 0, count: 4),
                Field(name: "FLCOMP_ImageSubdivisionsSizes2", bitOffset: 4, count: 4),
                Field(name: "FLCOMP_RSVD_8", bitOffset: 8, count: 1),
                Field(name: "FLCOMP_SPI_Voltage_Select", bitOffset: 9, count: 1),
                Field(name: "FLCOMP_RSVD_11_10", bitOffset: 10, count: 2),
                Field(name: "FLCOMP_Dual_Output_Read_Enable", bitOffset: 12, count: 1, label: "Dual Output Read Enable", options: [0: "No", 1: "Yes"]),
                Field(name: "FLCOMP_Dual_IO_Read_Enable", bitOffset: 13, count: 1, label: "Dual I/O Read Enable", options: [0: "No", 1: "Yes"]),
                Field(name: "FLCOMP_Quad_Output_Read_Enable", bitOffset: 14, count: 1, label: "Quad Output Read Enable", options: [0: "No", 1: "Yes"]),
                Field(name: "FLCOMP_Quad_IO_Read_Enable", bitOffset: 15, count: 1, label: "Quad I/O Read Enable", options: [0: "No", 1: "Yes"]),
                Field(name: "FLCOMP_RSVD_19_16", bitOffset: 16, count: 4),
                Field(name: "FLCOMP_Fast_Read_Support", bitOffset: 20, count: 1, label: "Fast Read Supported", options: [0: "No", 1: "Yes"]),
                Field(name: "FLCOMP_Fast_Read_Clock_Frequency", bitOffset: 21, count: 3, label: "Fast Read Clock Frequency", options: [0: "100MHz", 1: "50MHz", 3: "33MHz", 4: "25MHz", 6: "14MHZ"]),
                Field(name: "FLCOMP_Write_Erase_Clock_Frequency", bitOffset: 24, count: 3, label: "Write and Erase Clock Frequency", options: [0: "100MHz", 1: "50MHz", 3: "33MHz", 4: "25MHz", 6: "14MHZ"]),
                Field(name: "FLCOMP_Read_ID_Read_Status_Clock_Frequency", bitOffset: 27, count: 3, label: "Read ID and Read Status Clock Frequency", options: [0: "100MHz", 1: "50MHz", 3: "33MHz", 4: "25MHz", 6: "14MHZ"]),
                Field(name: "FLCOMP_RSVD_30", bitOffset: 30, count: 1),
                Field(name: "FLCOMP_Dis_GPIO_Out_En_TX_Phase", bitOffset: 31, count: 1),
            ]),
            Register(name: "FLIL", place: Place.flashComponent(offset: 0x4), words: 2, fields: [
                Field(name: "FLILL_Invalid_Instruction_0", bitOffset: 0, count: 8, label: "Invalid Instruction 0"),
                Field(name: "FLILL_Invalid_Instruction_1", bitOffset: 8, count: 8, label: "Invalid Instruction 1"),
                Field(name: "FLILL_Invalid_Instruction_2", bitOffset: 16, count: 8, label: "Invalid Instruction 2"),
                Field(name: "FLILL_Invalid_Instruction_3", bitOffset: 24, count: 8, label: "Invalid Instruction 3"),
                Field(name: "FLILL_Invalid_Instruction_4", bitOffset: 32, count: 8, label: "Invalid Instruction 4"),
                Field(name: "FLILL_Invalid_Instruction_5", bitOffset: 40, count: 8, label: "Invalid Instruction 5"),
                Field(name: "FLILL_Invalid_Instruction_6", bitOffset: 48, count: 8, label: "Invalid Instruction 6"),
                Field(name: "FLILL_Invalid_Instruction_7", bitOffset: 56, count: 8, label: "Invalid Instruction 7"),
            ]),
            Register(name: "FLMSTR", place: Place.flashMaster(offset: 0x0), words: 6, fields: [
                Field(name: "FLMSTR1_Extended_Region_Read_Access_Bios", bitOffset: 0, count: 4),
                Field(name: "FLMSTR1_Extended_Region_Write_Access_Bios", bitOffset: 4, count: 4),
                Field(name: "FLMSTR1_Master_Region_Read_Access_Bios", bitOffset: 8, count: 12),
                Field(name: "FLMSTR1_Master_Region_Write_Access_Bios", bitOffset: 20, count: 12),
                Field(name: "FLMSTR2_Extended_Region_Read_Access_ME", bitOffset: 32, count: 4),
                Field(name: "FLMSTR2_Extended_Region_Write_Access_ME", bitOffset: 36, count: 4),
                Field(name: "FLMSTR2_Master_Region_Read_Access_ME", bitOffset: 40, count: 12),
                Field(name: "FLMSTR2_Master_Region_Write_Access_ME", bitOffset: 52, count: 12),
                Field(name: "FLMSTR3_Extended_Region_Read_Access_GBE", bitOffset: 64, count: 4),
                Field(name: "FLMSTR3_Extended_Region_Write_Access_GBE", bitOffset: 68, count: 4),
                Field(name: "FLMSTR3_Master_Region_Read_Access_GBE", bitOffset: 72, count: 12),
                Field(name: "FLMSTR3_Master_Region_Write_Access_GBE", bitOffset: 84, count: 12),
                Field(name: "FLMSTR4_Extended_Region_Read_Access_RSVD", bitOffset: 96, count: 4),
                Field(name: "FLMSTR4_Extended_Region_Write_Access_RSVD", bitOffset: 100, count: 4),
                Field(name: "FLMSTR4_Master_Region_Read_Access_RSVD", bitOffset: 104, count: 12),
                Field(name: "FLMSTR4_Master_Region_Write_Access_RSVD", bitOffset: 116, count: 12),
                Field(name: "FLMSTR5_Extended_Region_Read_Access_EC", bitOffset: 128, count: 4),
                Field(name: "FLMSTR5_Extended_Region_Write_Access_EC", bitOffset: 132, count: 4),
                Field(name: "FLMSTR5_Master_Region_Read_Access_EC", bitOffset: 136, count: 12),
                Field(name: "FLMSTR5_Master_Region_Write_Access_EC", bitOffset: 148, count: 12),
                Field(name: "FLMSTR6_Extended_Region_Read_Access_ESE", bitOffset: 160, count: 4),
                Field(name: "FLMSTR6_Extended_Region_Write_Access_ESE", bitOffset: 164, count: 4),
                Field(name: "FLMSTR6_Master_Region_Read_Access_ESE", bitOffset: 168, count: 12),
                Field(name: "FLMSTR6_Master_Region_Write_Access_ESE", bitOffset: 180, count: 12),
            ]),
            Register(name: "FLDRPLCY", place: Place.absolute(0x340), words: 1, fields: [
                Field(name: "FLDRPLCY_Descriptor_Recovery_Policy_27_0", bitOffset: 0, count: 28),
                Field(name: "FLDRPLCY_Check_Main_Descriptor_Only", bitOffset: 28, count: 1),
                Field(name: "FLDRPLCY_Descriptor_Recovery_Policy_Config", bitOffset: 29, count: 3),
            ]),
            Register(name: "FLUMAP1", place: Place.absolute(0xEFC), words: 1, fields: [
                Field(name: "FLUMAP1_ME_VSCC_Table_Base_Address", bitOffset: 0, count: 8),
                Field(name: "FLUMAP1_ME_VSCC_Table_Length", bitOffset: 8, count: 8),
                Field(name: "FLUMAP1_RSVD_23_16", bitOffset: 16, count: 8),
                Field(name: "FLUMAP1_MIP_Descriptor_Table_Base_Address", bitOffset: 24, count: 8),
            ]),
        ])
}

