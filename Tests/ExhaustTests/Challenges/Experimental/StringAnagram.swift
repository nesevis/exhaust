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

    @Test("String anagram")
    func stringAnagram() throws {
        let charGen = #gen(.asciiString())
            .filter { $0.count >= 2 }
        let gen = #gen(charGen, charGen)

        let property: @Sendable (String, String) -> Bool = { a, b in
            guard a != b, a.count == b.count else { return true }
            print("\(a) \(b)")
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
            .reducer(.choiceGraph),
            property: property
        )
        let output = try #require(result)

        // Both arrays should be length 2, using the two smallest printable ASCII chars
        #expect(output.0 == " !")
        #expect(output.1 == "! ")
    }
    
    @Test("Long string reduction")
    func longStringReduction() throws {
        let needle = "syzygy"
        let result = #exhaust(
            .string(),
            .suppressIssueReporting,
            .logging(.debug),
            .reflecting(Self.haystack)
        ) {
            $0.contains(needle) == false
        }
        #expect(result == needle)
    }
    
    private static let haystack = """
        Elena had always believed that the universe spoke in geometry. Not in words, not in feelings, but in the precise language of angles and arcs. It was why she'd become a clockmaker — or, more accurately, why clockmaking had claimed her.
        Her workshop sat at the end of a narrow lane in a town that rarely appeared on maps. The shelves were cluttered with brass gears, coiled springs, and the skeletal remains of timepieces that had outlived their owners. She repaired them all, but the clock she truly cared about was her own.
        She called it the Orrery, though it was far more than that. Three concentric rings of hammered silver orbited a central golden disc, each carrying a polished stone — onyx, pearl, and garnet. The mechanism tracked no known celestial body. It tracked something else entirely, something she'd spent eleven years trying to understand.
        Her grandmother had left it to her with a single instruction written on a scrap of linen: Wait for the syzygy.
        Elena had looked the word up as a teenager. A syzygy — the alignment of three celestial bodies along a single gravitational axis. Sun, Earth, Moon drawn into a line. She'd assumed it was metaphorical, a poetic flourish from a woman who kept dried lavender in her pockets and sang to house spiders.
        But on the first night of her eleventh year with the Orrery, the three stones began to drift from their usual paths. The onyx slowed. The pearl accelerated. The garnet held steady, a fulcrum around which the others negotiated. By midnight, they formed a perfect line through the golden centre.
        The workshop filled with a sound like a tuning fork pressed to water. The air thinned. And in the space above the clock, Elena saw it — not light exactly, but the absence of shadow. A window into a place where geometry was not a description of reality but reality itself. Pure structure without substance.
        She reached toward it, and the vision folded shut like a closing eye. The stones resumed their wandering orbits. The ordinary sounds of the lane — a cat, a distant engine, wind against the shutters — returned as though they'd merely been holding their breath.
        Elena sat for a long time in the dark. Then she picked up her grandmother's note, turned it over, and read what she'd somehow never noticed on the back:
        Now build the next one.
        """
}
