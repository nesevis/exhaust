//
//  NestedLists.swift
//  Exhaust
//
//  Created by Chris Kolbu on 11/2/2026.
//

@testable import Exhaust
import Foundation
import Testing

@Suite("Shrinking Challenge: Nested Lists")
struct NestedListsShrinkingChallenge {
    /*
     https://github.com/jlink/shrinking-challenge/blob/main/challenges/nestedlists.md
     This tests the performance of shrinking a list of lists, testing the false property that the sum of lengths of the element lists is at most 10.

     The reason this is interesting is that it has lots of local minima under pure deletion based approaches. e.g. [[0], ..., [0]] and [[0, ..., 0]] are both minima for this under anything that can only make individual elements smaller.

     Some libraries, e.g. Hypothesis and jqwik, can shrink this reliably to a single list of 11 elements: [[0, 0, 0, 0, 0, 0, 0, 0, 0, 0]].
     */
    @Test("Nested Lists")
    func nestedListsFull() async throws {
        let gen = Gen.arrayOf(Gen.arrayOf(UInt.arbitrary))
        
        var count = 0
        let property: ([[UInt]]) -> Bool = { arr in
            count += 1
            return arr.map(\.count).reduce(0, +) <= 10
        }
        let iterator = ValueAndChoiceTreeInterpreter(gen, seed: 1337)
        // Outputs an array of 14 arrays containing 2–20 values each
        let (_, tree) = Array(iterator.prefix(2)).last!
        let (_, output) = try #require(try Interpreters.reduce(gen: gen, tree: tree, config: .fast, property: property))
        // How many times the `property` is called
        #expect(count == 48)
        // Shrinks to [[0,…x11]]
        #expect(output == [Array(repeating: UInt(0), count: 11)])
    }
}
