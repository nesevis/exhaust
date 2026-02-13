//
//  Coupling.swift
//  Exhaust
//
//  Created by Chris Kolbu on 11/2/2026.
//

@testable import Exhaust
import Foundation
import Testing

@Suite("Coupling Shrinking Challenge")
struct CouplingShrinkingChallenge {
    /*
     https://github.com/jlink/shrinking-challenge/blob/main/challenges/coupling.md
     In this example the elements of a list of integers are coupled to their position in an unusual way.

     The expected smallest falsified sample is [1, 0].
     */
    @Test("Coupling, Full", .disabled("Not implemented"))
    func couplingFull() {
        // A generator that will create an array of length 10 with elements corresponding to possible indices
        let gen = Gen.arrayOf(Gen.choose(in: Int(0)...9), exactly: 10)
        
        // The array cannot contain any 2-cycles, ie where arr[arr[n]] == n
        let prop: ([Int]) -> Bool = { arr in
            arr.enumerated().allSatisfy { index, lhs in
                let rhs = arr[index]
                return arr[rhs] != lhs
            }
        }
        
        // Will require a value reduction pass
    }
}
