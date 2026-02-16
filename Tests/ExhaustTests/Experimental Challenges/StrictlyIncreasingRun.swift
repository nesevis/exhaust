//
//  StrictlyIncreasingRun.swift
//  Exhaust
//
//  Created by Chris Kolbu on 17/2/2026.
//

@testable import Exhaust
import Foundation
import Testing

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
        let gen = Gen.arrayOf(Gen.choose(in: UInt64(0)...100), within: 3...50)

        let property: ([UInt64]) -> Bool = { arr in
            guard arr.count >= 3 else { return true }
            // [1, 0, 2] -> [1, 0], [0, 2]
            for (this, next) in zip(arr, arr.dropFirst()) {
                if this > next {
                    return false
                }
            }
            return true
        }

        let iterator = ValueAndChoiceTreeInterpreter(gen, seed: 1337)

        // Find a failing example — most random arrays of 3+ elements will have
        // a strictly increasing triple somewhere
        var failingTree: ChoiceTree?
        var failingValue: [UInt64]?
        for (value, tree) in iterator.prefix(20) {
            if !property(value) {
                failingValue = value
                failingTree = tree
                break
            }
        }

        let tree = try #require(failingTree)
        print("Initial failing value: \(failingValue!)")

        let (_, output) = try #require(try Interpreters.reduce(
            gen: gen, tree: tree, config: .slow, property: property
        ))

        print("Shrunk to: \(output)")

        // Should shrink to exactly 3 elements
        #expect(output.count == 3)
        // Should be the minimal strictly increasing triple
        #expect(output == [0, 1, 2])
    }
}
