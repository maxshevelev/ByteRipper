// The flash descriptor's registers of sunrisePoint, as 11.0 lays them out —
// emitted by `Skills/me-eom-structures/scripts/descriptor_fit_map.py`
// from the tool's own platform documents (spt). Names, places, labels
// and option words are the tool's; nothing here is read out of a dump.
//
// A field is kept only where every document of the platform states it
// identically; a bit they disagree about is left out.

import Foundation

extension DescriptorRegisterMap {
    public static let sunrisePoint = DescriptorRegisterMap(registers: [
        Register(name: "FLMAP1", place: .absolute(0x18), words: 1, fields: [
            Field(name: "DescFlashMasterBaseAddress", bitOffset: 0, count: 8),
            Field(name: "DescNumberOfMasters", bitOffset: 8, count: 3),
            Field(name: "reserved", bitOffset: 11, count: 5),
            Field(name: "DescFlashPchStrapBaseAddress", bitOffset: 16, count: 8),
            Field(name: "DescPchStrapLength", bitOffset: 24, count: 8),
        ]),
        Register(name: "FLMAP2", place: .absolute(0x1C), words: 1, fields: [
            Field(name: "DescFlashProcessorStrapBaseAddress", bitOffset: 0, count: 8),
            Field(name: "DescCpuStrapLength", bitOffset: 8, count: 8),
            Field(name: "DescRegInitBaseAddress", bitOffset: 16, count: 8),
            Field(name: "DescRegInitLength", bitOffset: 24, count: 8),
        ]),
    ])
}

