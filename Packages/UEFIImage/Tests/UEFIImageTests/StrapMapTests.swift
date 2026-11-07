import XCTest
@testable import UEFIImage

/// A strap word's group: the part of its fields' names they share, which is
/// all the tool says about what a word is.
final class StrapMapGroupTests: XCTestCase {
    func testAWordIsNamedByWhatItsFieldsShare() {
        let map = DescriptorStrapMap.pch69
        XCTAssertEqual(map.group(ofWord: 1), "GPCOM4_gpio_sstrap")
        XCTAssertEqual(map.group(ofWord: 13), "SPI")
        XCTAssertEqual(map.group(ofWord: 28), "CSME_CSE")
    }

    /// Reserved fields are named after their place, and do not cut the group
    /// short.
    func testReservedFieldsAreLeftOut() {
        // fproxy3_LT_Fit_Fallback, fproxy3_spare_softstrap, rsvd_000_8_31
        XCTAssertEqual(DescriptorStrapMap.pch69.group(ofWord: 0), "fproxy3")
    }

    /// One named field gives its block, not its own name again.
    func testAWordOfOneFieldGivesItsBlock() {
        // SPI_GLOBAL_PROTECTED_RNG_DEF alone
        XCTAssertEqual(DescriptorStrapMap.pch69.group(ofWord: 16), "SPI")
    }

    func testNamesWithNothingInCommonGiveNoGroup() {
        let map = DescriptorStrapMap(name: "test", words: 2, fields: [
            .init(name: "PCH_Strap_SPI_a", word: 0, bits: 0...0, defaultValue: 0),
            .init(name: "PCH_Strap_DMI_b", word: 0, bits: 1...1, defaultValue: 0),
            .init(name: "PCH_Strap_rsvd_004_0_31", word: 1, bits: 0...31, defaultValue: 0),
        ])
        XCTAssertNil(map.group(ofWord: 0))
        XCTAssertNil(map.group(ofWord: 1), "a word of reserved bits has no block")
        XCTAssertNil(map.group(ofWord: 5), "nor a word the table does not have")
    }

    /// Every word of every table at hand: a group, where there is one, is a
    /// prefix of a field of that word — never a name made up here.
    func testEveryGroupIsThePrefixOfAField() {
        for map in DescriptorStrapMap.all {
            for word in 0..<map.words {
                guard let group = map.group(ofWord: word) else { continue }
                XCTAssertTrue(map.fields(inWord: word).contains {
                    DescriptorStrapMap.localName($0.name).hasPrefix(group + "_")
                }, "\(map.name) word \(word): \(group)")
            }
        }
    }

    /// The MFIT CPU strap message's tables: the tool's labels and option
    /// words travel with the fields, and no default is claimed — the documents
    /// state values per reference platform, not a value the tool builds with.
    func testTheMIPMessageTablesCarryLabelsAndNoDefault() throws {
        let table = try XCTUnwrap(DescriptorStrapMap.forMIPProcessorSection(words: 17))
        let hyperthreading = try XCTUnwrap(table.fields.first {
            $0.name == "CPU_Strap_SMT_Disable"
        })
        XCTAssertEqual(hyperthreading.label, "Disable Hyperthreading")
        XCTAssertEqual(hyperthreading.options, [0: "No", 1: "Yes"])
        XCTAssertNil(hyperthreading.defaultValue)
        XCTAssertTrue(table.fields.allSatisfy { $0.defaultValue == nil })
        XCTAssertFalse(DescriptorStrapMap.Reading(field: hyperthreading, value: 1).isSet)
        XCTAssertNil(DescriptorStrapMap.forMIPProcessorSection(words: 6))
        XCTAssertNotNil(DescriptorStrapMap.forMIPProcessorSection(words: 20))
    }
}
