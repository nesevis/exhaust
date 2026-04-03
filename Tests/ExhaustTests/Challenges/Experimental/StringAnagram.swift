//
//  StringAnagram.swift
//  Exhaust
//
//  Created by Chris Kolbu on 17/2/2026.
//

import Foundation
import Testing
@testable import Exhaust

@Suite("Experimental Challenge: String Anagram")
struct StringAnagramChallenge {
    /*
     This tests that two distinct byte arrays (representing strings) of the same
     length are NOT anagrams of each other (i.e., don't share the same sorted form).

     The challenge uses UInt8 arrays in the ASCII printable range (32...126) as
     a proxy for strings. Two arrays fail the property when they are:
     1. Different from each other
     2. The same length
     3. Contain the same multiset of values (anagrams)

     This is a cross-container coupling challenge:
     - Both arrays must maintain the same character multiset while shrinking
     - Shrinking one array's character values changes the multiset, breaking
       the anagram relationship unless the other array changes in tandem
     - `deleteFreeStandingValues` can only delete from one array at a time,
       making lengths unequal (which causes the property to pass)
     - `reduceValuesInTandem` operates on siblings within the same container,
       not across the two zip'd containers
     - The reducer must coordinate deletions and simplifications across two
       independent container boundaries

     Expected smallest counterexample: ([(space), !], [!, (space)])
     Two arrays of the two smallest values in the range, in swapped order.
     */
    
    @Test("String Anagram #expect", .disabled("Example"))
    func stringAnagramExpect() throws {
        let charGen = #gen(.asciiString())
            .filter { $0.count >= 2 }
        let gen = #gen(charGen, charGen)
        
        let failingValueFromElsewhere = ("dcba", "abcd")
        
        #exhaust(gen, .reflecting(failingValueFromElsewhere)) { a, b in
            guard a != b, a.count == b.count else { return }
            #expect(a.sorted() != b.sorted())
        }
    }

    @Test("String anagram")
    func stringAnagram() throws {
        let charGen = #gen(.asciiString())
            .filter { $0.count >= 2 }
        let gen = #gen(charGen, charGen)

        let property: @Sendable (String, String) -> Bool = { a, b in
            guard a != b, a.count == b.count else { return true }
            return a.sorted() != b.sorted()
        }

        // "dcba" and "abcd" as byte arrays — a known anagram pair
        let value = ("dcba", "abcd")
        #expect(property(value.0, value.1) == false)

        let result = #exhaust(
            gen,
            .suppressIssueReporting,
            .reflecting(value),
            .logging(.debug),

            property: property
        )
        let output = try #require(result)

        // Both arrays should be length 2, using the two smallest printable ASCII chars
        #expect(output.0 == " !")
        #expect(output.1 == "! ")
    }
}
