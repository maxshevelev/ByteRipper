import HelpBook
import UEFIImage

/// Which glossary entry explains the node the reader is looking at.
///
/// The panel names structures nobody meets outside a firmware bench — a VSS
/// store, a pad file, a flash descriptor — and the `?` beside the detail list
/// answers "what *is* this row" for the node in focus. That mapping is a
/// function of the node's kind and subtype, so it lives in the pure target and
/// is tested by `swift test` rather than being decided in a view.
///
/// Nil for a node the glossary has nothing to say about beyond what its own
/// row already says. The panel then draws no button, which is the honest
/// answer: a `?` that opens a page saying "a section is a section" is worse
/// than no `?` at all.
public enum UEFIHelpTerms {
    public static func term(for node: UEFINode) -> HelpTermID? {
        switch node.kind {
        case .capsule: return HelpTermID("capsule")
        case .intelImage, .uefiImage: return HelpTermID("dump")
        case .flashDescriptor: return HelpTermID("flash-descriptor")
        case .region: return region(node.subtype)
        case .volume: return HelpTermID("volume")
        // A pad file is a file only in the sense that every slot in a volume
        // has a header. Naming it as one would send the reader to the page
        // about files, which is not what they are looking at.
        case .file: return node.subtype == 0xF0 ? HelpTermID("pad-file") : HelpTermID("ffs-file")
        case .section: return HelpTermID("section")
        case .microcode: return HelpTermID("microcode")
        // The Startup AP data lives in a pad file and is why that pad file
        // must stay where it is; the page about pad files says so.
        case .startupApData: return HelpTermID("pad-file")
        case .padding: return HelpTermID("padding")
        case .freeSpace: return HelpTermID("free-space")
        case .nonUEFIData: return HelpTermID("non-uefi-data")
        case .slicData: return HelpTermID("slic")
        // Every NVRAM store and every entry in one goes to the same pair of
        // entries: what NVRAM is, and what a variable store holds. The formats
        // differ by vendor and the difference is not what a reader on a bench
        // is asking about.
        case .vssStore, .vss2Store, .ftwStore, .fdcStore, .sysFStore,
             .flashMapStore, .evsaStore, .cmdbStore:
            return HelpTermID("vss")
        case .vssEntry, .sysFEntry, .evsaEntry, .flashMapEntry:
            return HelpTermID("vss")
        // Insyde's map holds no variables: it lays out the chip.
        case .flashDeviceMapStore, .flashDeviceMapEntry:
            return HelpTermID("flash-device-map")
        case .flashDeviceMapRegion:
            return mapRegion(node.guid)
        // AMI's store is the exception, because what a reader asks of it is
        // different: which of a variable's entries holds its value now.
        case .nvarEntry, .nvarGuidStore:
            return HelpTermID("nvar")
        }
    }

    /// A map region whose type has a page of its own goes there — the EC
    /// firmware, the version table, the default variables — and the rest to
    /// the page about the map, which says what its regions are.
    private static func mapRegion(_ type: EFIGUID?) -> HelpTermID {
        switch type {
        case FlashDeviceMap.ecFirmware: return HelpTermID("ec-firmware")
        case FlashDeviceMap.biosVersionDataTable: return HelpTermID("bvdt")
        case FlashDeviceMap.variableDefaults: return HelpTermID("vss")
        default: return HelpTermID("flash-device-map")
        }
    }

    /// A region row goes to the page about that particular region where there
    /// is one — which region a reader is standing in is the most useful thing
    /// the panel can explain — and to the general one otherwise.
    private static func region(_ subtype: UInt8?) -> HelpTermID {
        switch subtype {
        case UEFITypes.Sub.descriptorRegion: return HelpTermID("flash-descriptor")
        case UEFITypes.Sub.biosRegion, UEFITypes.Sub.bios2Region:
            return HelpTermID("bios-region")
        case UEFITypes.Sub.meRegion: return HelpTermID("me-region")
        case UEFITypes.Sub.gbeRegion: return HelpTermID("gbe-region")
        case UEFITypes.Sub.pdrRegion: return HelpTermID("pdr-region")
        case UEFITypes.Sub.ecRegion: return HelpTermID("ec-region")
        case UEFITypes.Sub.microcodeRegion: return HelpTermID("microcode")
        default: return HelpTermID("region")
        }
    }
}
