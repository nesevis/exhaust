//
//  StrictlyIncreasingRun.swift
//  Exhaust
//
//  Created by Chris Kolbu on 17/2/2026.
//

import Foundation
import Testing
@testable import Exhaust
@_spi(ExhaustInternal) import ExhaustCore

@Suite("Experimental Challenge: Strictly Increasing Run")
struct StrictlyIncreasingRunChallenge {
    /*
     This tests that an array of integers contains no contiguous run of 3
     strictly increasing values (i.e., no i where arr[i] < arr[i+1] < arr[i+2]).

     The challenge creates tension between deletion and value simplification:
     - `deleteFreeStandingValues` wants to remove elements, but deleting below
       length 3 makes the property trivially true
     - `simplifyValuesToSemanticSimplest` pushes all values toward 0, but
       [0, 0, 0] is NOT strictly increasing — so naive simplification passes
     - The reducer must maintain strictly increasing ORDER across three adjacent
       values, meaning each value is constrained by its neighbors
     - `reduceValues` can independently binary-search each value toward 0, but
       the middle value must stay > first, and the last must stay > middle

     Expected smallest counterexample: [0, 1, 2]
     The three smallest non-negative integers that form a strictly increasing run.
     */

    @Test("Strictly increasing run")
    func strictlyIncreasingRun() throws {
        let gen = #gen(.uint64(in: 0 ... 10000)).array(length: 1 ... 50)

        let property: ([UInt64]) -> Bool = { arr in
            guard arr.count >= 3 else { return true }
            return arr
                .dropFirst()
                .reduce(into: (count: 1, last: arr[0], valid: true)) { acc, n in
                    guard acc.valid else { return }
                    acc.count = n > acc.last ? acc.count + 1 : 1
                    acc.last = n
                    acc.valid = acc.count < 3
                }.valid
        }

        let counterExample: [UInt64] = [0, 1, 2]
        #expect(property(counterExample) == false)

        let startingValue: [UInt64] = [6000, 344, 3750]
        let tree = try #require(try Interpreters.reflect(gen, with: startingValue))
        let initialSeq = ChoiceSequence.flatten(tree)
        let initialValueSpans = ChoiceSequence.extractAllValueSpans(from: initialSeq)

        let (seq, output) = try #require(try Interpreters.reduce(
            gen: gen, tree: tree, config: .slow, property: property,
        ))

        // Should be the minimal strictly increasing triple
        #expect(output == counterExample)
    }
}
