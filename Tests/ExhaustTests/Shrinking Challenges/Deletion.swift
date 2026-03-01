//
//  Deletion.swift
//  Exhaust
//
//  Created by Chris Kolbu on 11/2/2026.
//

import Foundation
import Testing
@testable import Exhaust
@_spi(ExhaustInternal) import ExhaustCore

@Suite("Shrinking Challenge: Deletion")
struct DeletionShrinkingChallenge {
    /**
     https://github.com/jlink/shrinking-challenge/blob/main/challenges/deletion.md
     This tests the property "if we remove an element from a list, the element is no longer in the list".
     The remove function we use however only actually removes the first instance of the element, so this fails whenever the list contains a duplicate and we try to remove one of those elements.

     This example is interesting for a couple of reasons:

     It's a nice easy to explain example of property-based testing.

     Shrinking duplicates simultaneously is something that most property-based testing libraries can't do.

     The expected smallest falsified sample is ([0, 0], 0).
     */
    @Test("Deletion, Full")
    func deletionFull() throws {
        let numberGen = Gen.choose(in: 0 ... 20)
        let gen = Gen.zip(Gen.arrayOf(numberGen, within: 2 ... 20), numberGen).filter { $0.contains($1) }

        var count = 0
        let property: ([Int], Int) -> Bool = { xs, x in
            count += 1
            var xs = xs
            guard let index = xs.firstIndex(of: x) else {
                return true
            }
            xs.remove(at: index)
            return xs.contains(x) == false
        }

        let iterator = ValueAndChoiceTreeInterpreter(gen, materializePicks: true, seed: 1337)
        let (_, tree) = try #require(Array(iterator.prefix(36)).last)
        let (_, output) = try #require(try Interpreters.reduce(gen: gen, tree: tree, config: .fast, property: property))

        #expect(count == 3)
        #expect(output.0 == [0, 0])
        #expect(output.1 == 0)
    }
}
