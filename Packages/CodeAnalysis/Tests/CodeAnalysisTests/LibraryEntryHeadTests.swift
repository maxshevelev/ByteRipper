import Foundation
import XCTest
@testable import CodeAnalysis

/// A review that changes only an entry's head — the divide's convention, as
/// TcgPei offered it in proposal a2af6661 — offers the entry's own C under the
/// new head: the module's decompiler cannot tell two of the entry's
/// temporaries apart, and its C would put `uVar1`/`uVar2`, its own labels and
/// `NULL` for `(UINT64 *)0x0` in the registry.
final class LibraryEntryHeadTests: XCTestCase {
    private let source = LibrarySource(module: SHA256Digest(data: Data("5661b013".utf8)), address: "0x9DFC200",
                                       rev: 50, by: "agent")

    /// The entry's C, as module 5661b013 printed InternalMathDivRemU64x64.
    private let heldC = #"""

        /* WARNING: Removing unreachable block (ram,0x09dfc257) */
        /* WARNING: Unknown calling convention -- yet parameter storage is locked */
        /* Answers the quotient of Dividend by Divisor and, through the pointer, the remainder.
           
           A divisor that fits in 32 bits takes the short path through the 32-bit division. Otherwise both
           operands are shifted down until the divisor's high dword is zero, the 32-bit division runs, and
           the quotient is corrected by one when the reconstructed product overshoots the dividend. The C
           prints the register pairs as member accesses on Divisor: they are halves of the 64-bit arguments,
           not a structure.
           
           Evidence: InternalMathDivRemU64x64, MdePkg/Library/BaseLib/Ia32/DivU64x64Remainder.nasm:31, tail
           jump at :40. */

        UINT64 InternalMathDivRemU64x64(UINT64 Dividend,UINT64 Divisor,UINT64 *Remainder)

        {
          uint QuotientLow;
          uint DividendHigh;
          uint ProductCarry;
          int ProductHigh;
          bool Borrow;
          ulonglong NextDivisor;
          UINT64 OriginalDivisor;
          longlong ProductLow;
          ulonglong ShiftedDividend;
          undefined4 ShiftedDividendHigh;
          ulonglong ShiftedDivisor;
          
          OriginalDivisor = Divisor;
          /* A divisor that fits in 32 bits takes the short path: the remainder's high
             dword is cleared and the 32-bit variant does the work. */
          ShiftedDividend = Dividend;
          ShiftedDivisor = Divisor;
          if (Divisor._4_4_ == (UINT64 *)0x0) {
            if (Remainder != (UINT64 *)0x0) {
              *(undefined4 *)((int)Remainder + 4) = 0;
              Divisor._4_4_ = Remainder;
            }
            ShiftedDividend = OriginalDivisor & 0xffffffff;
            ShiftedDivisor =
                 (ulonglong)Dividend._4_4_ % (OriginalDivisor & 0xffffffff) << 0x20 | Dividend & 0xffffffff;
            if (Divisor._4_4_ != (UINT64 *)0x0) {
              *(int *)Divisor._4_4_ = (int)(ShiftedDivisor % ShiftedDividend);
            }
            return CONCAT44(Dividend._4_4_ / (uint)Divisor,(int)(ShiftedDivisor / ShiftedDividend));
          }
          do {
            /* Both operands shift down one bit at a time until the divisor's high dword is
               zero. */
            DividendHigh = (uint)(ShiftedDividend >> 0x21);
            ShiftedDividendHigh =
                 (undefined4)(CONCAT14((ShiftedDividend & 0x100000000) != 0,(int)ShiftedDividend) >> 1);
            NextDivisor = ShiftedDivisor >> 1;
            ShiftedDividend = CONCAT44(DividendHigh,ShiftedDividendHigh);
            ShiftedDivisor = ShiftedDivisor >> 1;
          } while ((int)(NextDivisor >> 0x20) != 0);
          /* The 32-bit division; the multiply that follows rebuilds the product so the
             quotient can be checked against the dividend. */
          ShiftedDividend = CONCAT44(DividendHigh,ShiftedDividendHigh) / (NextDivisor & 0xffffffff);
          DividendHigh = (uint)ShiftedDividend;
          ProductLow = (ShiftedDividend & 0xffffffff) * (Divisor & 0xffffffff);
          ProductCarry = (uint)((ulonglong)ProductLow >> 0x20);
          QuotientLow = (uint)ProductLow;
          ProductHigh = ProductCarry + (int)Divisor._4_4_ * DividendHigh;
          if ((CARRY4(ProductCarry,(int)Divisor._4_4_ * DividendHigh)) ||
             (Dividend < CONCAT44(ProductHigh,QuotientLow))) {
            DividendHigh = DividendHigh - 1;
            if (Remainder == (UINT64 *)0x0) goto LAB_09dfc271;
            Borrow = QuotientLow < (uint)Divisor;
            QuotientLow = QuotientLow - (uint)Divisor;
            ProductHigh = (ProductHigh - (int)Divisor._4_4_) - (uint)Borrow;
          }
          if (Remainder != (UINT64 *)0x0) {
            *Remainder = Dividend - CONCAT44(ProductHigh,QuotientLow);
          }
        LAB_09dfc271:
          return (UINT64)DividendHigh;
        }


        """#

    /// The same function as TcgPei prints it, signed `__cdecl`.
    private let offeredC = #"""

        /* WARNING: Removing unreachable block (ram,0x09a1a937) */
        /* Answers the quotient of Dividend by Divisor and, through the pointer, the remainder.
           
           A divisor that fits in 32 bits takes the short path through the 32-bit division. Otherwise both
           operands are shifted down until the divisor's high dword is zero, the 32-bit division runs, and
           the quotient is corrected by one when the reconstructed product overshoots the dividend. The C
           prints the register pairs as member accesses on Divisor: they are halves of the 64-bit arguments,
           not a structure.
           
           Evidence: InternalMathDivRemU64x64, MdePkg/Library/BaseLib/Ia32/DivU64x64Remainder.nasm:31, tail
           jump at :40. */

        UINT64 __cdecl InternalMathDivRemU64x64(UINT64 Dividend,UINT64 Divisor,UINT64 *Remainder)

        {
          ulonglong uVar1;
          ulonglong uVar2;
          uint QuotientLow;
          uint DividendHigh;
          uint ProductCarry;
          int ProductHigh;
          bool Borrow;
          ulonglong NextDivisor;
          UINT64 OriginalDivisor;
          longlong ProductLow;
          undefined4 ShiftedDividendHigh;
          
          OriginalDivisor = Divisor;
          /* A divisor that fits in 32 bits takes the short path: the remainder's high
             dword is cleared and the 32-bit variant does the work. */
          uVar1 = Dividend;
          uVar2 = Divisor;
          if (Divisor._4_4_ == NULL) {
            if (Remainder != NULL) {
              *(undefined4 *)((int)Remainder + 4) = 0;
              Divisor._4_4_ = Remainder;
            }
            uVar1 = OriginalDivisor & 0xffffffff;
            uVar2 = (ulonglong)Dividend._4_4_ % (OriginalDivisor & 0xffffffff) << 0x20 |
                    Dividend & 0xffffffff;
            if (Divisor._4_4_ != NULL) {
              *(int *)Divisor._4_4_ = (int)(uVar2 % uVar1);
            }
            return CONCAT44(Dividend._4_4_ / (uint)Divisor,(int)(uVar2 / uVar1));
          }
          do {
            /* Both operands shift down one bit at a time until the divisor's high dword is
               zero. */
            DividendHigh = (uint)(uVar1 >> 0x21);
            ShiftedDividendHigh = (undefined4)(CONCAT14((uVar1 & 0x100000000) != 0,(int)uVar1) >> 1);
            NextDivisor = uVar2 >> 1;
            uVar1 = CONCAT44(DividendHigh,ShiftedDividendHigh);
            uVar2 = uVar2 >> 1;
          } while ((int)(NextDivisor >> 0x20) != 0);
          /* The 32-bit division; the multiply that follows rebuilds the product so the
             quotient can be checked against the dividend. */
          uVar1 = CONCAT44(DividendHigh,ShiftedDividendHigh) / (NextDivisor & 0xffffffff);
          DividendHigh = (uint)uVar1;
          ProductLow = (uVar1 & 0xffffffff) * (Divisor & 0xffffffff);
          ProductCarry = (uint)((ulonglong)ProductLow >> 0x20);
          QuotientLow = (uint)ProductLow;
          ProductHigh = ProductCarry + (int)Divisor._4_4_ * DividendHigh;
          if ((CARRY4(ProductCarry,(int)Divisor._4_4_ * DividendHigh)) ||
             (Dividend < CONCAT44(ProductHigh,QuotientLow))) {
            DividendHigh = DividendHigh - 1;
            if (Remainder == NULL) goto LAB_09a1a951;
            Borrow = QuotientLow < (uint)Divisor;
            QuotientLow = QuotientLow - (uint)Divisor;
            ProductHigh = (ProductHigh - (int)Divisor._4_4_) - (uint)Borrow;
          }
          if (Remainder != NULL) {
            *Remainder = Dividend - CONCAT44(ProductHigh,QuotientLow);
          }
        LAB_09a1a951:
          return (UINT64)DividendHigh;
        }


        """#

    private func at(_ needle: String, in text: String, after: String? = nil) -> Int {
        let string = text as NSString
        let from = after.map { string.range(of: $0).location } ?? 0
        let found = string.range(of: needle, range: NSRange(location: from, length: string.length - from))
        XCTAssertNotEqual(found.location, NSNotFound, needle)
        return found.location
    }

    private func review(c: String, convention: String, spans: [[Any]], comment: String = "the 32-bit path") -> [String: Any] {
        [
            "schema": 1, "kind": "edk2", "name": "InternalMathDivRemU64x64",
            "body": ["size": 49, "full": "e785b0688524a34a", "specific": "84b055009bb8dc5e"],
            "calling_convention": convention, "return_type": "UINT64",
            "signature": "UINT64 InternalMathDivRemU64x64(UINT64 Dividend, UINT64 Divisor, UINT64 * Remainder)",
            "params": [["ordinal": 0, "name": "Dividend", "storage": "Stack[0x4]:8", "type": "UINT64"],
                       ["ordinal": 1, "name": "Divisor", "storage": "Stack[0xc]:8", "type": "UINT64"],
                       ["ordinal": 2, "name": "Remainder", "storage": "Stack[0x14]:4", "type": "UINT64 *"]],
            "locals": [["first_use": "0x2E", "name": "DividendHigh", "storage": "EDX:4", "type": "uint"]],
            "plate": "Answers the quotient of Dividend by Divisor and, through the pointer, the remainder.",
            "comments": [["offset": "0x4", "kind": "pre", "text": comment]],
            "constants": [["offset": "0x0", "operand": 1, "value": "0x10"]],
            "function": ["c": c, "c_spans": spans, "c_sites": [], "entry": "0x9DFC200",
                         "name": "InternalMathDivRemU64x64", "size": 121,
                         "signature": "UINT64 InternalMathDivRemU64x64(UINT64 Dividend, UINT64 Divisor, UINT64 * Remainder)"]
        ]
    }

    private var held: [String: Any] {
        review(c: heldC, convention: "unknown", spans: [
            [at("/* WARNING: Unknown", in: heldC), 74, "comment"],
            [at("InternalMathDivRemU64x64(", in: heldC), 24, "function"],
            [at("ShiftedDividend = Dividend", in: heldC), 15, "local"],
            [at("LAB_09dfc271:", in: heldC), 12, "label"]
        ])
    }

    private var offered: [String: Any] {
        var object = review(c: offeredC, convention: "__cdecl", spans: [
            [at("__cdecl", in: offeredC), 7, "keyword"],
            [at("InternalMathDivRemU64x64(", in: offeredC), 24, "function"],
            [at("uVar1 = Dividend", in: offeredC), 5, "local"]
        ])
        object["constants"] = []
        return object
    }

    private func data(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    func testAConventionOnlyReviewOffersTheEntrysCUnderTheNewHead() throws {
        let kept = try XCTUnwrap(LibraryProposal.keepingEntryText(try data(offered), in: try data(held), heldSource: source))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: kept) as? [String: Any])
        let function = try XCTUnwrap(object["function"] as? [String: Any])
        let c = try XCTUnwrap(function["c"] as? String)

        // The head is the proposal's; the convention's warning is gone.
        XCTAssertEqual(object["calling_convention"] as? String, "__cdecl")
        XCTAssertTrue(c.contains("\nUINT64 __cdecl InternalMathDivRemU64x64(UINT64 Dividend,UINT64 Divisor,UINT64 *Remainder)\n"), c)
        XCTAssertFalse(c.contains("Unknown calling convention"), c)
        // The body is the entry's, word for word: its temporaries, its labels,
        // its unreachable block and its zero pointers.
        let body = { (text: String) in String(text[text.range(of: "\n{\n")!.lowerBound...]) }
        XCTAssertEqual(body(c), body(heldC))
        for kept in ["ShiftedDividend = Dividend;", "ShiftedDivisor = Divisor;", "goto LAB_09dfc271;",
                     "(ram,0x09dfc257)", "(UINT64 *)0x0"] {
            XCTAssertTrue(c.contains(kept), kept)
        }
        for lost in ["uVar1", "uVar2", "LAB_09a1a951", "0x09a1a937", "NULL"] {
            XCTAssertFalse(c.contains(lost), lost)
        }
        XCTAssertEqual(c, heldC
            .replacingOccurrences(of: "/* WARNING: Unknown calling convention -- yet parameter storage is locked */\n", with: "")
            .replacingOccurrences(of: "\nUINT64 InternalMathDivRemU64x64(", with: "\nUINT64 __cdecl InternalMathDivRemU64x64("))

        // The review's text and the body's facts stay the entry's, and the C
        // still says whose reading it is.
        let heldObject = held
        for key in ["plate", "comments", "locals", "constants", "body", "name", "kind"] {
            XCTAssertEqual(object[key] as? NSObject, heldObject[key] as? NSObject, key)
        }
        let origin = try XCTUnwrap(function["source"] as? [String: Any])
        XCTAssertEqual(origin["module"] as? String, source.module.hex)
        XCTAssertEqual(origin["address"] as? String, "0x9DFC200")

        // Every place the C names still names its word: the prototype's from
        // the proposal, the body's moved with the text, the warning's gone.
        let text = c as NSString
        let spans = try XCTUnwrap(function["c_spans"] as? [[Any]])
        let words = spans.map { text.substring(with: NSRange(location: $0[0] as! Int, length: $0[1] as! Int)) }
        XCTAssertEqual(words, ["__cdecl", "InternalMathDivRemU64x64", "ShiftedDividend", "LAB_09dfc271"])
    }

    /// A review that edits the body — here a step comment — offers its own C:
    /// the entry's would not show the edit.
    func testABodyEditOffersTheModulesC() throws {
        var edited = offered
        edited["comments"] = [["offset": "0x4", "kind": "pre", "text": "the 32-bit path, checked"]]
        XCTAssertNil(LibraryProposal.keepingEntryText(try data(edited), in: try data(held), heldSource: source))
    }

    /// The same head with another C is no head change: what prints differently
    /// goes the way a reprint does.
    func testTheSameHeadIsNotRebuilt() throws {
        var same = offered
        same["calling_convention"] = "unknown"
        XCTAssertNil(LibraryProposal.keepingEntryText(try data(same), in: try data(held), heldSource: source))
    }
}
