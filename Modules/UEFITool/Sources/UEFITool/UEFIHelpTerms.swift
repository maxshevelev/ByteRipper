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
    /// With `image`, a node at the top of a Top Swap copy goes to the page
    /// about Top Swap: what a reader asks of it is why the volumes are there
    /// twice.
    /// With `reader`, HP's `HP_MUD` entry goes to the page about HP's DMI:
    /// it is told from the other VSS entries only by its bytes; so is Apple's
    /// SysF store that holds the serial.
    public static func term(for node: UEFINode, in image: UEFIImage, reader: ImageReader? = nil) -> HelpTermID? {
        if case .copy = UEFITopSwap.role(of: node, in: image) { return HelpTermID("top-swap") }
        if let reader, UEFIHPDMIDetail.area(for: node, image: image, reader: reader) != nil {
            return HelpTermID("hp-dmi")
        }
        if let reader, UEFIAppleDMIDetail.area(for: node, reader: reader) != nil {
            return HelpTermID("apple-dmi")
        }
        return term(for: node)
    }

    public static func term(for node: UEFINode) -> HelpTermID? {
        switch node.kind {
        case .capsule: return HelpTermID("capsule")
        case .intelImage, .uefiImage: return HelpTermID("dump")
        case .flashDescriptor: return HelpTermID("flash-descriptor")
        case .region: return region(node.subtype)
        case .volume: return HelpTermID("volume")
        // A pad file is a file only in the sense that every slot in a volume
        // has a header. Naming it as one would send the reader to the page
        // about files, which is not what they are looking at. A module is a
        // file too, but what a reader asks of it is what kind of module it is
        // and how it is dispatched.
        case .file:
            switch node.subtype {
            case 0xF0: return HelpTermID("pad-file")
            case 0x04: return HelpTermID("pei")
            case 0x05: return HelpTermID("dxe")
            case 0x06, 0x08: return HelpTermID("peim")
            case 0x07: return HelpTermID("dxe-driver")
            default: return HelpTermID("ffs-file")
            }
        case .section:
            if let subtype = node.subtype,
               DependencyExpression.Kind(sectionType: subtype) != nil {
                return HelpTermID("depex")
            }
            return HelpTermID("section")
        case .microcode, .amdMicrocode: return HelpTermID("microcode")
        // The Startup AP data lives in a pad file and is why that pad file
        // must stay where it is; the page about pad files says so.
        case .startupApData: return HelpTermID("pad-file")
        // Padding the parser named for the EC image it opens on is read as
        // what it looks like.
        case .padding where ECImage.isECFirmwarePadding(node):
            return HelpTermID("ec-firmware")
        case .ecImage:
            return HelpTermID("ec-firmware")
        case .fitComponent:
            switch node.subtype.flatMap(FITComponent.Kind.init(rawValue:)) {
            case .startupACM: return HelpTermID("acm")
            case .keyManifest: return HelpTermID("key-manifest")
            case .bootPolicy: return HelpTermID("boot-policy")
            case .table, nil: return HelpTermID("fit")
            }
        case .padding: return HelpTermID("padding")
        case .picture: return HelpTermID("picture")
        case .hpSignatureBlock: return HelpTermID("hp-signature-block")
        case .gpnvStore, .gpnvRecord: return HelpTermID("gpnv")
        case .lenovoDMIStore: return HelpTermID("dmi")
        case .acerDMIStore: return HelpTermID("acer-dmi")
        case .panasonicDMIStore, .panasonicDMIRecord: return HelpTermID("panasonic-dmi")
        // A field of Acer's area or of HP's `HP_MUD`: what the bench reads
        // these areas for is the page about DMI.
        case .dmiField: return HelpTermID("dmi")
        case .lenvBlock, .lenvEntry: return HelpTermID("lenv")
        case .ldbgLog, .ldbgEntry: return HelpTermID("ldbg")
        case .amdEFS, .amdDirectory, .amdFirmwareEntry: return HelpTermID("amd-psp")
        case .biosGuardUpdate, .biosGuardEntry: return HelpTermID("bios-guard-update")
        case .sound: return HelpTermID("sound")
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
        // Dell's store names its variables by number, which is what a reader
        // needs explained.
        case .dvarStore, .dvarEntry:
            return HelpTermID("dvar")
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
