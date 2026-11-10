import Foundation
import XCTest
@testable import CodeAnalysis

/// An EDK2 plate's `Evidence:` line is read and checked against a checkout of
/// the pinned tag; each way it can fail is its own outcome.
final class EDK2EvidenceTests: XCTestCase {
    private var checkout: URL!

    private let hobLib = """
        /** @file
          HOB Library.
        **/

        #include <PiPei.h>

        /**
          GetFirstGuidHob (Guid) returns the first instance of the matched GUID HOB.

          @param  Guid          The GUID to match with in the HOB list.

          @return The first instance of the matched GUID HOB among the whole HOB list.

        **/
        VOID *
        EFIAPI
        GetFirstGuidHob (
          IN CONST EFI_GUID  *Guid
          )
        {
          VOID  *HobList;

          HobList = GetHobList ();
          return GetNextGuidHob (Guid, HobList);
        }

        VOID *
        EFIAPI
        GetNextGuidHob (
          IN CONST EFI_GUID  *Guid,
          IN CONST VOID      *HobStart
          )
        {
          if (GetFirstGuidHob (Guid) == NULL) {
            return NULL;
          }
          // GetFirstGuidHob (Guid) {
          return (VOID *)HobStart;
        }
        """

    private let copyMem = """
        SECTION .text

        ;------------------------------------------------------------------------------
        ;  VOID *
        ;  InternalMemCopyMem (
        ;    IN VOID   *Destination,
        ;    IN VOID   *Source,
        ;    IN UINTN  Count
        ;    );
        ;------------------------------------------------------------------------------
        global ASM_PFX(InternalMemCopyMem)
        ASM_PFX(InternalMemCopyMem):
            push    esi
        """

    override func setUpWithError() throws {
        checkout = FileManager.default.temporaryDirectory
            .appendingPathComponent("EDK2Evidence-\(UUID().uuidString)", isDirectory: true)
        let library = checkout.appendingPathComponent("MdePkg/Library/PeiHobLib", isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        try Data(hobLib.utf8).write(to: library.appendingPathComponent("HobLib.c"))
        let asm = checkout.appendingPathComponent("MdePkg/Library/BaseMemoryLibRepStr/Ia32", isDirectory: true)
        try FileManager.default.createDirectory(at: asm, withIntermediateDirectories: true)
        try Data(copyMem.utf8).write(to: asm.appendingPathComponent("CopyMem.nasm"))
        let listing = ["MdePkg/Library/PeiHobLib/HobLib.c", "MdePkg/Library/BaseMemoryLibRepStr/Ia32/CopyMem.nasm",
                       "CryptoPkg/Library/BaseCryptLib/Hash/CryptSha256.c"]
        try Data(listing.joined(separator: "\n").utf8)
            .write(to: checkout.appendingPathComponent(EDK2Evidence.listingName))
    }

    override func tearDownWithError() throws {
        if let checkout { try? FileManager.default.removeItem(at: checkout) }
    }

    private func outcome(_ plate: String) -> EDK2Evidence.Finding {
        let findings = EDK2Evidence.check(plate: plate, checkout: checkout)
        XCTAssertEqual(findings.count, 1, "\(findings)")
        return findings[0]
    }

    func testTheLineOfTheFunctionsNameInItsDefinitionIsTrue() {
        let finding = outcome("The first GUID HOB.\n\nEvidence: GetFirstGuidHob, MdePkg/Library/PeiHobLib/HobLib.c:17.")
        XCTAssertEqual(finding.outcome, .ok, "\(finding)")
        XCTAssertEqual(finding.citation, .init(function: "GetFirstGuidHob", path: "MdePkg/Library/PeiHobLib/HobLib.c",
                                               line: 17))
    }

    func testAnotherLineSaysWhereTheFileDefinesIt() {
        let finding = outcome("Evidence: GetFirstGuidHob, MdePkg/Library/PeiHobLib/HobLib.c:211.")
        XCTAssertEqual(finding.outcome, .notDefinition)
        XCTAssertEqual(finding.definedAt, 17)
        XCTAssertEqual(finding.definitions, 1)
    }

    func testACallOrADocCommentIsNotADefinition() {
        // Line 8 is the doc comment's; 34 the call in an if; 37 a comment; 29 another function.
        for line in [8, 34, 37, 29] {
            let finding = outcome("Evidence: GetFirstGuidHob, MdePkg/Library/PeiHobLib/HobLib.c:\(line)")
            XCTAssertEqual(finding.outcome, .notDefinition, "line \(line)")
        }
        XCTAssertEqual(EDK2Evidence.definitions(of: "GetNextGuidHob", in: hobLib, path: "HobLib.c"), [29])
    }

    func testAnAssemblyFunctionIsItsLabel() {
        let label = outcome("Evidence: InternalMemCopyMem, MdePkg/Library/BaseMemoryLibRepStr/Ia32/CopyMem.nasm:12")
        XCTAssertEqual(label.outcome, .ok, "\(label)")
        let comment = outcome("Evidence: InternalMemCopyMem, MdePkg/Library/BaseMemoryLibRepStr/Ia32/CopyMem.nasm:5")
        XCTAssertEqual(comment.outcome, .notDefinition)
    }

    func testEachWayItFailsIsItsOwnOutcome() {
        XCTAssertEqual(outcome("A plate with no evidence.").outcome, .noEvidence)
        XCTAssertEqual(outcome("Evidence: EDK2 BaseMemoryLib CopyMem: returns Destination").outcome, .unparseable)
        XCTAssertEqual(outcome("Evidence: GetFirstGuidHob, MdePkg/Library/DxeHobLib/HobLib.c:181").outcome,
                       .fileNotAtTag)
        XCTAssertEqual(outcome("Evidence: Sha256Init, CryptoPkg/Library/BaseCryptLib/Hash/CryptSha256.c:40").outcome,
                       .notInCheckout)
        XCTAssertEqual(outcome("Evidence: GetFirstGuidHob, ../etc/passwd:1").outcome, .unparseable)
        XCTAssertEqual(outcome("Evidence: MdePkg/Library/PeiHobLib/HobLib.c:17.").outcome, .unparseable)
        XCTAssertEqual(outcome("Evidence: GetFirstGuidHob in MdePkg/Library/PeiHobLib/HobLib.c:17.").outcome,
                       .unparseable)
        XCTAssertEqual(outcome("Evidence: GetFirstGuidHob, MdePkg/Library/PeiHobLib/HobLib.c:17-19").outcome,
                       .unparseable)
    }

    func testARemarkMayFollowTheLine() {
        let finding = outcome("Evidence: GetFirstGuidHob, MdePkg/Library/PeiHobLib/HobLib.c:17, with GetNextGuidHob inlined.")
        XCTAssertEqual(finding.outcome, .ok, "\(finding)")
        XCTAssertEqual(finding.citation?.line, 17)
    }

    func testEveryEvidenceLineIsChecked() {
        let findings = EDK2Evidence.check(plate: """
            Two sources.
            Evidence: GetFirstGuidHob, MdePkg/Library/PeiHobLib/HobLib.c:17
            Evidence: GetNextGuidHob, MdePkg/Library/PeiHobLib/HobLib.c:31
            """, checkout: checkout)
        XCTAssertEqual(findings.map(\.outcome), [.ok, .notDefinition])
        XCTAssertEqual(findings.last?.definedAt, 29)
    }

    /// The tree the reviewers read: GetFirstGuidHob is at 181 at the tag, and
    /// the 211 the registry holds is master's.
    func testThePinnedTreeHoldsGetFirstGuidHobAt181() throws {
        let tree = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Projects/edk2-stable202608", isDirectory: true)
        guard FileManager.default.fileExists(atPath: tree.appendingPathComponent("MdePkg").path) else {
            throw XCTSkip("~/Projects/edk2-stable202608 is not there")
        }
        let right = EDK2Evidence.check(plate: "Evidence: GetFirstGuidHob, MdePkg/Library/PeiHobLib/HobLib.c:181.",
                                       checkout: tree)
        XCTAssertEqual(right.map(\.outcome), [.ok])
        let wrong = EDK2Evidence.check(plate: "Evidence: GetFirstGuidHob, MdePkg/Library/PeiHobLib/HobLib.c:211.",
                                       checkout: tree)
        XCTAssertEqual(wrong.first?.outcome, .notDefinition)
        XCTAssertEqual(wrong.first?.definedAt, 181)
    }
}
