import HelpBook
import UEFIImage
import XCTest
@testable import UEFITool

/// Which glossary entry a node's `?` opens.
///
/// Two things are worth pinning: that a reader standing in a region is told
/// about *that* region rather than about regions in general, and that every
/// term this file names is one the book actually holds — a mapping into nothing
/// is a `?` that opens an empty popover on a bench.
final class UEFIHelpTermsTests: XCTestCase {
    private func node(_ kind: UEFINodeKind, subtype: UInt8? = nil) -> UEFINode {
        UEFINode(kind: kind, subtype: subtype, name: "",
                 header: 0..<0x10, body: 0x10..<0x20)
    }

    func testAKindGoesToItsOwnEntry() {
        XCTAssertEqual(UEFIHelpTerms.term(for: node(.volume)), HelpTermID("volume"))
        XCTAssertEqual(UEFIHelpTerms.term(for: node(.section)), HelpTermID("section"))
        XCTAssertEqual(UEFIHelpTerms.term(for: node(.flashDescriptor)),
                       HelpTermID("flash-descriptor"))
        XCTAssertEqual(UEFIHelpTerms.term(for: node(.freeSpace)), HelpTermID("free-space"))
        XCTAssertEqual(UEFIHelpTerms.term(for: node(.nonUEFIData)),
                       HelpTermID("non-uefi-data"))
    }

    /// The most useful thing the panel can explain about a region row is which
    /// region the reader is standing in.
    func testARegionGoesToThatRegionsOwnEntry() {
        XCTAssertEqual(UEFIHelpTerms.term(for: node(.region, subtype: UEFITypes.Sub.meRegion)),
                       HelpTermID("me-region"))
        XCTAssertEqual(UEFIHelpTerms.term(for: node(.region, subtype: UEFITypes.Sub.gbeRegion)),
                       HelpTermID("gbe-region"))
        XCTAssertEqual(UEFIHelpTerms.term(for: node(.region, subtype: UEFITypes.Sub.biosRegion)),
                       HelpTermID("bios-region"))
        // One nobody has written a page about falls back to the general entry
        // rather than to nothing.
        XCTAssertEqual(UEFIHelpTerms.term(for: node(.region, subtype: UEFITypes.Sub.ieRegion)),
                       HelpTermID("region"))
    }

    /// A pad file is a file only in the sense that every slot in a volume has a
    /// header; sending the reader to the page about files would answer a
    /// question they did not ask.
    func testAPadFileIsNotAFile() {
        XCTAssertEqual(UEFIHelpTerms.term(for: node(.file, subtype: 0xF0)),
                       HelpTermID("pad-file"))
        XCTAssertEqual(UEFIHelpTerms.term(for: node(.file, subtype: 0x07)),
                       HelpTermID("ffs-file"))
    }

    /// Every NVRAM store and entry answers the same two questions, so they
    /// share one entry rather than each getting a page about a vendor's format.
    func testTheNVRAMStoresShareOneEntry() {
        for kind: UEFINodeKind in [.vssStore, .vss2Store, .ftwStore, .evsaStore,
                                   .vssEntry, .evsaEntry, .flashMapEntry] {
            XCTAssertEqual(UEFIHelpTerms.term(for: node(kind)), HelpTermID("vss"),
                           "\(kind) should read as an NVRAM store")
        }
    }

    /// The test that matters: every node kind the parser can produce maps to a
    /// term the book holds. A `?` that opens nothing is worse than no `?`.
    func testEveryKindMapsToATermTheBookHolds() {
        for kind in UEFINodeKind.allCases {
            guard let term = UEFIHelpTerms.term(for: node(kind)) else { continue }
            XCTAssertNotNil(Help.shared.term(term),
                            "\(kind) points at “\(term.rawValue)”, which is not in the glossary")
        }
    }
}
