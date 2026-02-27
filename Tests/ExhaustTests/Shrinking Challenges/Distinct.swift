//
//  Distinct.swift
//  Exhaust
//
//  Created by Chris Kolbu on 11/2/2026.
//

import Foundation
import Testing
@testable import Exhaust

@Suite("Shrinking Challenge: Distinct")
struct DistinctShrinkingChallenge {
    /**
     https://github.com/jlink/shrinking-challenge/blob/main/challenges/distinct.md
     This tests the example provided for the property "a list of integers containing at least three distinct elements".

     This is interesting because:

     1. Most property-based testing libraries will not successfully normalize (i.e. always return the same answer) this property, because it requires reordering examples to do so.
     2. Hypothesis and test.check both provide a built in generator for "a list of distinct elements", so the "example of size at least N" provides a sort of lower bound for how well they can shrink those built in generators.

     The expected smallest falsified sample is [0, 1, -1] or [0, 1, 2].
     */
    @Test("Distinct, Full")
    func distinctFull() throws {
        // …etc
        let gen = Gen.arrayOf(Int.arbitrary, within: 3 ... 30)

        var count = 0
        let property: ([Int]) -> Bool = { arr in
            count += 1
            return Set(arr).count < 3
        }

        let iterator = ValueAndChoiceTreeInterpreter(gen, materializePicks: true, seed: 1337)
        let (_, tree) = try #require(Array(iterator.prefix(40)).last) // 13 values
        let (_, output) = try #require(try Interpreters.reduce(gen: gen, tree: tree, config: .fast, property: property))
        #expect(count == 94)
        #expect(output == [-1, 0, 1])
    }
}
