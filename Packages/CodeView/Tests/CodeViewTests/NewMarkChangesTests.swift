@testable import CodeAnalysis
@testable import CodeView
import XCTest

/// What the New plate lists: every change the C comparison cannot show, and
/// nothing it does.
final class NewMarkChangesTests: XCTestCase {
    private func function(_ fields: [String: Any] = [:]) throws -> CodeArtifact.Function {
        var row: [String: Any] = [
            "entry": "0x220", "name": "F", "signature": "void F(void)",
            "c": "void F(void)\n{\n  A();\n}\n",
            "instructions": [["address": "0x220", "bytes": "C3", "mnemonic": "RET", "text": "RET"]]
        ]
        for (key, value) in fields { row[key] = value }
        return try artifact(functions: [row]).functions[0]
    }

    private func artifact(functions: [[String: Any]], equates: [[String: Any]] = [],
                          types: [[String: Any]] = []) throws -> CodeArtifact {
        try JSONDecoder().decode(CodeArtifact.self, from: JSONSerialization.data(withJSONObject: [
            "script_version": 10, "program": ["image_base": "0x0"], "functions": functions,
            "equates": equates, "types": types
        ]))
    }

    func testARenameTheHeaderShowsIsNotListed() throws {
        let old = try function()
        let new = try function(["name": "Init", "signature": "void Init(void)",
                                "c": "void Init(void)\n{\n  A();\n}\n"])
        XCTAssertEqual(NewMarkChange.between(old: old, new: new), [])
    }

    func testACodeChangeAloneIsNotListed() throws {
        let old = try function()
        let new = try function(["c": "void F(void)\n{\n  B();\n}\n"])
        XCTAssertEqual(NewMarkChange.between(old: old, new: new), [])
    }

    func testAStepCommentTheCDoesNotPrintIsListed() throws {
        let old = try function(["review_gaps": ["comments"]])
        let new = try function(["review_gaps": []])
        XCTAssertEqual(NewMarkChange.between(old: old, new: new), [.stepComments(added: true)])
        XCTAssertEqual(NewMarkChange.between(old: new, new: old), [.stepComments(added: false)])
    }

    func testACommentTheCPrintsIsTheComparisons() throws {
        let old = try function(["review_gaps": ["comments"]])
        let new = try function(["review_gaps": [], "c": "void F(void)\n{\n  /* Ask the PPI */\n  A();\n}\n"])
        XCTAssertEqual(NewMarkChange.between(old: old, new: new), [])
    }

    func testAPlateTheCDoesNotPrintIsListed() throws {
        let old = try function(["review_gaps": ["plate"]])
        let new = try function(["review_gaps": []])
        XCTAssertEqual(NewMarkChange.between(old: old, new: new), [.plateComment(added: true)])
    }

    func testASignatureTheCDoesNotShowIsListed() throws {
        let old = try function()
        let new = try function(["signature": "void __fastcall F(void)"])
        XCTAssertEqual(NewMarkChange.between(old: old, new: new),
                       [.signature(from: "void F(void)", to: "void __fastcall F(void)")])
    }

    func testCustomStorageIsListed() throws {
        let old = try function()
        let new = try function(["custom_storage": true])
        XCTAssertEqual(NewMarkChange.between(old: old, new: new), [.customStorage(true)])
    }

    func testTheRegistryLinkIsListed() throws {
        let own = try function()
        let link = try function(["registry": "17"])
        XCTAssertEqual(NewMarkChange.between(old: own, new: link).first, .bound(entry: "17", name: link.name))
        XCTAssertEqual(NewMarkChange.between(old: link, new: own).first, .unbound(entry: "17", name: link.name))
        let other = try function(["registry": "18"])
        XCTAssertEqual(NewMarkChange.between(old: link, new: other).first,
                       .rebound(from: "17", to: "18", name: other.name))
    }

    func testAnotherVersionOfTheEntryIsListed() throws {
        var old = try function(["registry": "17"]), new = old
        old.libraryEntry = .init(id: "CopyMem", version: 1, codes: [])
        new.libraryEntry = .init(id: "CopyMem", version: 2, codes: [])
        XCTAssertEqual(NewMarkChange.between(old: old, new: new),
                       [.entryVersion(entry: "CopyMem", name: new.name, from: 1, to: 2)])
    }

    func testTheNamesAndLevelsReasonsAreListed() throws {
        let old = try function(["name_source": "ANALYSIS", "name_reason": "a", "review_level": "partial"])
        let new = try function(["name_source": "USER_DEFINED", "name_reason": "b",
                                "signature_reason": "c", "review_level": "full"])
        XCTAssertEqual(NewMarkChange.between(old: old, new: new), [
            .nameSource(from: "ANALYSIS", to: "USER_DEFINED"), .nameReason("b"), .signatureReason("c"),
            .reviewLevel(from: .partial, to: .full)
        ])
    }

    func testAConstantsMeaningIsListedAndAPrintedNameIsNot() throws {
        func equate(_ name: String, _ comment: String) -> [String: Any] {
            ["name": name, "value": "0x80", "comment": comment, "references": [["0x220", 0]]]
        }
        let old = try artifact(functions: [[
            "entry": "0x220", "name": "F", "c": "void F(void)\n{\n  OUT(POST);\n}\n",
            "instructions": [["address": "0x220", "bytes": "C3", "text": "RET"]]
        ]], equates: [equate("POST", "port 0x80")])
        let new = try artifact(functions: [[
            "entry": "0x220", "name": "F", "c": "void F(void)\n{\n  OUT(POST);\n}\n",
            "instructions": [["address": "0x220", "bytes": "C3", "text": "RET"]]
        ]], equates: [equate("POST", "the POST card's port"), equate("HIDDEN", "")])
        XCTAssertEqual(NewMarkChange.between(old: old.functions[0], new: new.functions[0],
                                             oldEquates: old.equates, newEquates: new.equates),
                       [.equateAdded("HIDDEN"), .equateDescribed("POST")])
    }

    func testAListingChangeUnderTheSameCIsListed() throws {
        let old = try function()
        let new = try function(["instructions": [["address": "0x220", "bytes": "C3", "text": "RET", "flow": "TERMINATOR"]]])
        XCTAssertEqual(NewMarkChange.between(old: old, new: new), [.listing(1)])
    }

    func testAGlobalsTypeIsListed() throws {
        let old = try function(["globals": [["offset": "0x10", "name": "gBS", "type": "void *"]]])
        let new = try function(["globals": [["offset": "0x10", "name": "gBS", "type": "EFI_BOOT_SERVICES *"]]])
        XCTAssertEqual(NewMarkChange.between(old: old, new: new),
                       [.globalType(name: "gBS", from: "void *", to: "EFI_BOOT_SERVICES *")])
    }

    func testATypeRedefinedIsListedButDoesNotMarkNew() throws {
        let c = "void F(CTX *Ctx)\n{\n  A();\n}\n"
        let old = try function(["c": c]), new = try function(["c": c])
        func type(_ body: String) -> CodeArtifact.TypeDefinition {
            try! artifact(functions: [], types: [["name": "CTX", "kind": "struct", "c": body]]).types[0]
        }
        let changes = NewMarkChange.between(old: old, new: new,
                                            oldTypes: [type("struct CTX { int a; };")],
                                            newTypes: [type("struct CTX { int b; };")])
        XCTAssertEqual(changes, [.typeDefinition("CTX")])
        XCTAssertFalse(changes.contains(where: \.marksNew))
    }

    func testNeitherRevisionHasCode() throws {
        let old = try function(["c": NSNull()]), new = try function(["c": NSNull()])
        XCTAssertEqual(NewMarkChange.between(old: old, new: new), [.noCodeEither])
    }
}
